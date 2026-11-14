import { constants } from "node:fs";
import { open, realpath, lstat, readdir } from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
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
export class Files {
  constructor(
    private config: Config,
    private db: Database,
  ) {}
  async safeOpen(
    rootId: string,
    relative: string,
    directory = false,
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
    const base = await realpath(root.path);
    const target = path.resolve(base, relative);
    let current = base;
    // Refuse symlinks, even those currently pointing inside the root.
    for (const part of relative.split("/").filter((p) => p && p !== ".")) {
      current = path.join(current, part);
      if ((await lstat(current)).isSymbolicLink())
        throw new HttpError(403, "unsafe_path", "Symlink refused");
    }
    const handle = await open(
      target,
      constants.O_RDONLY |
        constants.O_NOFOLLOW |
        constants.O_NONBLOCK |
        (directory ? constants.O_DIRECTORY : 0),
    );
    try {
      // Check the opened inode, not only its pre-open path, to close rename/symlink races.
      // Linux is the server platform; /proc must be mounted (also for containers).
      const actual = await realpath(`/proc/self/fd/${handle.fd}`);
      if (actual !== base && !actual.startsWith(base + path.sep))
        throw new HttpError(403, "unsafe_path", "Path escaped root");
      const stat = await handle.stat();
      if (directory ? !stat.isDirectory() : !stat.isFile())
        throw new HttpError(404, "not_found", "Entry not found");
      return handle;
    } catch (error) {
      await handle.close();
      throw error;
    }
  }
  async list(rootId: string, relative: string) {
    const dir = await this.safeOpen(rootId, relative, true);
    try {
      const entries: (
        | { name: string; type: "folder" }
        | {
            name: string;
            type: "file";
            fileId: string;
            sizeBytes: number;
            durationMs?: number;
          }
      )[] = [];
      for (const entry of await readdir(`/proc/self/fd/${dir.fd}`, {
        withFileTypes: true,
      })) {
        if (entry.isSymbolicLink()) continue;
        if (entry.isDirectory())
          entries.push({ name: entry.name, type: "folder" });
        else if (entry.isFile() && media.test(entry.name)) {
          const rel = path.posix.join(relative, entry.name);
          const handle = await this.safeOpen(rootId, rel);
          try {
            const stat = await handle.stat({ bigint: true });
            if (stat.size === 0n) continue;
            const old = this.db
              .prepare("SELECT * FROM media_file WHERE root_id=? AND path=?")
              .get(rootId, rel) as FileRow | undefined;
            const id = old?.id ?? randomUUID();
            const mtime = stat.mtimeNs.toString();
            this.db
              .prepare(
                "INSERT INTO media_file(id,root_id,path,size,mtime) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET size=excluded.size,mtime=excluded.mtime,probe=CASE WHEN size=excluded.size AND mtime=excluded.mtime THEN probe ELSE NULL END",
              )
              .run(id, rootId, rel, Number(stat.size), mtime);
            const cached =
              old &&
              old.size === Number(stat.size) &&
              old.mtime === mtime &&
              old.probe
                ? (JSON.parse(old.probe) as Metadata)
                : null;
            entries.push({
              name: entry.name,
              type: "file",
              fileId: id,
              sizeBytes: Number(stat.size),
              ...(cached?.durationMs != null && {
                durationMs: cached.durationMs,
              }),
            });
          } finally {
            await handle.close();
          }
        }
      }
      entries.sort(
        (a, b) =>
          (a.type === b.type ? 0 : a.type === "folder" ? -1 : 1) ||
          collator.compare(a.name, b.name) ||
          a.name.localeCompare(b.name),
      );
      return {
        path:
          path.posix.normalize(relative) === "."
            ? ""
            : path.posix.normalize(relative),
        entries,
      };
    } finally {
      await dir.close();
    }
  }
  async get(id: string) {
    const row = this.db
      .prepare("SELECT * FROM media_file WHERE id=?")
      .get(id) as FileRow | undefined;
    if (!row) throw new HttpError(404, "not_found", "File not found");
    const handle = await this.safeOpen(row.root_id, row.path);
    return { row, handle };
  }
}
