import { constants } from "node:fs";
import { open, realpath, readdir } from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import type { FastifyBaseLogger } from "fastify";
import type { Config } from "../config.js";
import type { Database } from "../db.js";
import { HttpError } from "../errors.js";
import type { Metadata } from "../schemas.js";
const media = /\.(mkv|mp4|ts|webm|mov|avi|m4v)$/i;
const collator = new Intl.Collator("en", {
  numeric: true,
  sensitivity: "base",
});
export type FileRow = {
  id: string;
  root_id: string;
  path: string;
  size: number;
  mtime: string;
  probe: string | null;
};
type Entry =
  | { name: string; type: "folder" }
  | {
      name: string;
      type: "file";
      fileId: string;
      sizeBytes: number;
      durationMs?: number;
    };
export class Files {
  private find;
  private findPath;
  private save;
  constructor(
    private config: Config,
    private db: Database,
    private log: FastifyBaseLogger,
  ) {
    this.find = db.prepare("SELECT * FROM media_file WHERE id=?");
    this.findPath = db.prepare(
      "SELECT * FROM media_file WHERE root_id=? AND path=?",
    );
    this.save = db.prepare(
      "INSERT INTO media_file(id,root_id,path,size,mtime) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET size=excluded.size,mtime=excluded.mtime,probe=NULL",
    );
  }
  /**
   * Opens a path inside a root. Symlinks are followed; containment is enforced on
   * the real path of the opened descriptor, so links that stay inside the root work
   * and anything that resolves outside it is refused, including rename races.
   * `kind` "any" accepts a folder or a regular file.
   */
  async safeOpen(
    rootId: string,
    relative: string,
    kind: "folder" | "file" | "any",
  ): Promise<FileHandle> {
    const root = this.config.roots.find((r) => r.id === rootId);
    if (!root) throw new HttpError(404, "not_found", "Root not found");
    if (
      relative.includes("\0") ||
      relative.includes("\\") ||
      path.isAbsolute(relative) ||
      relative.split("/").includes("..")
    )
      throw new HttpError(403, "unsafe_path", "Path refused");
    // Outside the try: a missing or unreadable root is a configuration error (500).
    const base = await realpath(root.path);
    let handle: FileHandle | undefined;
    try {
      // O_NONBLOCK keeps a FIFO from blocking the open; it is rejected below.
      handle = await open(
        path.resolve(base, relative),
        constants.O_RDONLY |
          constants.O_NONBLOCK |
          (kind === "folder" ? constants.O_DIRECTORY : 0),
      );
      // Linux /proc is required, including inside the container.
      const actual = await realpath(`/proc/self/fd/${handle.fd}`);
      if (actual !== base && !actual.startsWith(base + path.sep))
        throw new HttpError(403, "unsafe_path", "Path escaped root");
      const stat = await handle.stat();
      const ok =
        kind === "folder"
          ? stat.isDirectory()
          : kind === "file"
            ? stat.isFile()
            : stat.isDirectory() || stat.isFile();
      if (!ok) throw new HttpError(404, "not_found", "Entry not found");
      return handle;
    } catch (error) {
      await handle?.close();
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "ENOENT" || code === "ENOTDIR")
        throw new HttpError(404, "not_found", "Entry not found");
      if (code === "EACCES" || code === "EPERM" || code === "ELOOP")
        throw new HttpError(403, "forbidden", "Access refused");
      throw error;
    }
  }
  async list(rootId: string, relative: string) {
    // safeOpen sees the raw path so ".." is refused before any normalisation.
    const dir = await this.safeOpen(rootId, relative, "folder");
    const folder = path.posix
      .normalize(relative)
      .replace(/\/$/, "")
      .replace(/^\.$/, "");
    const entries: Entry[] = [];
    const files: { name: string; path: string; size: number; mtime: string }[] =
      [];
    try {
      const listing = await readdir(`/proc/self/fd/${dir.fd}`, {
        encoding: "buffer",
        withFileTypes: true,
      });
      for (const dirent of listing) {
        const raw = dirent.name;
        const name = raw.toString("utf8");
        // Names that are not valid UTF-8 cannot be sent to or requested by clients.
        if (!Buffer.from(name, "utf8").equals(raw)) {
          this.log.warn({ rootId, folder }, "Skipping a non-UTF-8 file name");
          continue;
        }
        if (name.startsWith(".")) continue;
        // Regular non-media files need no open; folders and symlinks must be
        // opened to learn what they are and whether they stay inside the root.
        if (dirent.isFile() && !media.test(name)) continue;
        const rel = path.posix.join(folder, name);
        let handle: FileHandle | undefined;
        try {
          handle = await this.safeOpen(rootId, rel, "any");
          const stat = await handle.stat({ bigint: true });
          if (stat.isDirectory()) entries.push({ name, type: "folder" });
          else if (media.test(name) && stat.size > 0n)
            files.push({
              name,
              path: rel,
              size: Number(stat.size),
              mtime: stat.mtimeNs.toString(),
            });
        } catch (error) {
          // One unreadable, vanished or escaping entry must not break the folder.
          this.log.warn({ err: error, rootId, path: rel }, "Skipping entry");
        } finally {
          await handle?.close();
        }
      }
    } finally {
      await dir.close();
    }
    // Synchronous from here: one transaction, and only new or changed rows are written.
    this.db.exec("BEGIN");
    try {
      for (const file of files) {
        const old = this.findPath.get(rootId, file.path) as FileRow | undefined;
        const unchanged =
          old && old.size === file.size && old.mtime === file.mtime;
        const id = old?.id ?? randomUUID();
        if (!unchanged)
          this.save.run(id, rootId, file.path, file.size, file.mtime);
        const cached =
          unchanged && old.probe ? (JSON.parse(old.probe) as Metadata) : null;
        entries.push({
          name: file.name,
          type: "file",
          fileId: id,
          sizeBytes: file.size,
          ...(cached?.durationMs != null && { durationMs: cached.durationMs }),
        });
      }
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    entries.sort(
      (a, b) =>
        (a.type === b.type ? 0 : a.type === "folder" ? -1 : 1) ||
        collator.compare(a.name, b.name) ||
        a.name.localeCompare(b.name),
    );
    return { path: folder, entries };
  }
  async get(id: string) {
    const row = this.find.get(id) as FileRow | undefined;
    if (!row) throw new HttpError(404, "not_found", "File not found");
    return { row, handle: await this.safeOpen(row.root_id, row.path, "file") };
  }
}
