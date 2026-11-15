import { randomBytes } from "node:crypto";
import { mkdir, readdir, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

/** Uploads kept in `<dataDirectory>/diagnostics`; older ones are removed. */
export const keptBenchmarkUploads = 20;

const prefix = "benchmark-";

/** A short filename part: ASCII letters, digits, `.`, `_` and `-` only. */
function sanitize(text: string): string {
  return (
    text
      .replace(/[^A-Za-z0-9._-]+/g, "-")
      .replace(/^[.-]+|-+$/g, "")
      .slice(0, 40) || "unknown"
  );
}

/**
 * Writes an uploaded engine benchmark results file as a new file under
 * `<dataDirectory>/diagnostics` and removes all but the newest uploads.
 * Names start with a UTC timestamp so they sort by upload time; the random
 * part keeps two uploads in the same millisecond apart. Returns the name.
 */
export async function saveBenchmarkUpload(
  dataDirectory: string,
  upload: { device: string; appVersion: string; content: string },
  now = new Date(),
): Promise<string> {
  const directory = path.join(dataDirectory, "diagnostics");
  await mkdir(directory, { recursive: true });
  const stamp = now.toISOString().replace(/[-:]/g, "");
  const name = `${prefix}${stamp}-${sanitize(upload.device)}-${sanitize(upload.appVersion)}-${randomBytes(3).toString("hex")}.jsonl`;
  // "wx": never overwrite an existing file.
  await writeFile(path.join(directory, name), upload.content, { flag: "wx" });
  // Only files this function created match the prefix and extension.
  const uploads = (await readdir(directory))
    .filter((entry) => entry.startsWith(prefix) && entry.endsWith(".jsonl"))
    .sort();
  for (const old of uploads.slice(0, -keptBenchmarkUploads)) {
    try {
      await unlink(path.join(directory, old));
    } catch (error) {
      // A concurrent upload may have removed it already.
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  return name;
}
