import { spawn } from "node:child_process";
import type { FileHandle } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import type { Database } from "../db.js";
import type { FileRow } from "../library/files.js";
import { metadataSchema } from "../schemas.js";
import { HttpError } from "../errors.js";
const stream = z.object({
  index: z.number(),
  codec_type: z.string(),
  codec_name: z.string().default("unknown"),
  width: z.number().optional(),
  height: z.number().optional(),
  pix_fmt: z.string().optional(),
  avg_frame_rate: z.string().optional(),
  channels: z.number().optional(),
  sample_rate: z.string().optional(),
  tags: z
    .object({ language: z.string().optional(), title: z.string().optional() })
    .optional(),
  disposition: z
    .object({ default: z.number().optional(), forced: z.number().optional() })
    .optional(),
});
const probeSchema = z.object({
  format: z.object({
    format_name: z.string().default("unknown"),
    duration: z.string().optional(),
  }),
  streams: z.array(stream).default([]),
  chapters: z
    .array(
      z.object({
        start_time: z.string(),
        end_time: z.string(),
        tags: z.object({ title: z.string().optional() }).optional(),
      }),
    )
    .default([]),
});
export async function probe(db: Database, row: FileRow, handle: FileHandle) {
  const stat = await handle.stat({ bigint: true });
  if (
    row.probe &&
    row.size === Number(stat.size) &&
    row.mtime === stat.mtimeNs.toString()
  )
    return metadataSchema.parse(JSON.parse(row.probe));
  const output = await new Promise<string>((resolve, reject) => {
    // Inherit only this read-only descriptor. ffprobe never resolves the library path again.
    const child = spawn(
      "ffprobe",
      [
        "-v",
        "error",
        "-format_whitelist",
        "matroska,webm,mov,avi,mpegts",
        "-protocol_whitelist",
        "file,pipe",
        "-show_format",
        "-show_streams",
        "-show_chapters",
        "-of",
        "json",
        "/proc/self/fd/3",
      ],
      { stdio: ["ignore", "pipe", "pipe", handle.fd] },
    );
    let text = "";
    let bytes = 0;
    const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
    child.stdout!.setEncoding("utf8");
    child.stdout!.on("data", (chunk: string) => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > 8 * 1024 * 1024) child.kill("SIGKILL");
      else text += chunk;
    });
    child.stderr!.resume(); // Raw ffprobe diagnostics may contain private media paths.
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(text);
      else
        reject(new HttpError(422, "probe_failed", "Media could not be probed"));
    });
  });
  const p = probeSchema.parse(JSON.parse(output));
  const video = p.streams.find((s) => s.codec_type === "video");
  const track = (s: z.infer<typeof stream>) => ({
    index: s.index,
    codec: s.codec_name,
    language: s.tags?.language ?? null,
    title: s.tags?.title ?? null,
    default: s.disposition?.default === 1,
    forced: s.disposition?.forced === 1,
  });
  const result = metadataSchema.parse({
    fileId: row.id,
    name: path.posix.basename(row.path),
    sizeBytes: Number(stat.size),
    durationMs:
      p.format.duration && Number.isFinite(Number(p.format.duration))
        ? Math.round(Number(p.format.duration) * 1000)
        : null,
    container: p.format.format_name,
    video: video
      ? {
          index: video.index,
          codec: video.codec_name,
          width: video.width ?? null,
          height: video.height ?? null,
          pixelFormat: video.pix_fmt ?? null,
          frameRate: video.avg_frame_rate ?? null,
        }
      : null,
    audioTracks: p.streams
      .filter((s) => s.codec_type === "audio")
      .map((s) => ({
        ...track(s),
        channels: s.channels ?? null,
        sampleRate: s.sample_rate ? Number(s.sample_rate) : null,
      })),
    subtitleTracks: p.streams
      .filter((s) => s.codec_type === "subtitle")
      .map(track),
    chapters: p.chapters.map((c) => ({
      startMs: Math.round(Number(c.start_time) * 1000),
      endMs: Math.round(Number(c.end_time) * 1000),
      title: c.tags?.title ?? null,
    })),
  });
  db.prepare("UPDATE media_file SET size=?,mtime=?,probe=? WHERE id=?").run(
    Number(stat.size),
    stat.mtimeNs.toString(),
    JSON.stringify(result),
    row.id,
  );
  return result;
}
