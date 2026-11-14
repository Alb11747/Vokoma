import type { FastifyReply, FastifyRequest } from "fastify";
import type { FileHandle } from "node:fs/promises";
import { HttpError } from "../errors.js";
/**
 * Serves a file's bytes from Node. Takes ownership of `handle`.
 * Range follows RFC 9110: one byte range is honoured; a header that does not parse,
 * uses another unit or asks for several ranges is ignored and the whole file is sent.
 */
export async function sendContent(
  request: FastifyRequest,
  reply: FastifyReply,
  handle: FileHandle,
) {
  let transferred = false;
  try {
    const { size } = await handle.stat();
    reply.header("Accept-Ranges", "bytes").type("application/octet-stream");
    let start = 0,
      end = size - 1,
      status = 200;
    // RFC 9110: Range applies to GET; HEAD describes the full representation.
    const match =
      request.method === "GET" && request.headers.range
        ? /^bytes=(\d*)-(\d*)$/i.exec(request.headers.range.trim())
        : null;
    const first = match?.[1],
      last = match?.[2];
    // "bytes=-" and "bytes=5-2" are not valid range-specs, so they are ignored too.
    if (
      match &&
      (first || last) &&
      !(first && last && Number(last) < Number(first))
    ) {
      if (!first) {
        const suffix = Number(last);
        start = suffix === 0 ? size : Math.max(0, size - suffix);
      } else {
        start = Number(first);
        end = last ? Math.min(Number(last), size - 1) : size - 1;
      }
      if (!Number.isSafeInteger(start) || start >= size) {
        reply.header("Content-Range", `bytes */${size}`);
        throw new HttpError(416, "invalid_range", "Range not satisfiable");
      }
      status = 206;
      reply.header("Content-Range", `bytes ${start}-${end}/${size}`);
    }
    const length = Math.max(0, end - start + 1);
    reply.code(status).header("Content-Length", String(length));
    if (request.method === "HEAD" || length === 0) {
      reply.send();
      return;
    }
    const stream = handle.createReadStream({ start, end, autoClose: true });
    // If the file shrinks after stat, the stream ends early. Ending the response
    // normally would leave the client waiting for the promised bytes on a
    // kept-alive socket, so drop the connection instead.
    let sent = 0;
    stream.on("data", (chunk) => (sent += chunk.length));
    stream.on("end", () => {
      if (sent < length) reply.raw.destroy();
    });
    transferred = true;
    reply.send(stream);
  } finally {
    if (!transferred) await handle.close();
  }
}
