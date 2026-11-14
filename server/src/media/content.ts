import type { FastifyReply, FastifyRequest } from "fastify";
import type { FileHandle } from "node:fs/promises";
import { HttpError } from "../errors.js";
export interface ContentSender {
  send(
    request: FastifyRequest,
    reply: FastifyReply,
    handle: FileHandle,
  ): Promise<void>;
}
export class NodeContentSender implements ContentSender {
  async send(request: FastifyRequest, reply: FastifyReply, handle: FileHandle) {
    let transferred = false;
    try {
      const { size } = await handle.stat();
      reply.header("Accept-Ranges", "bytes").type("application/octet-stream");
      let start = 0,
        end = size - 1,
        status = 200;
      // RFC 9110: Range applies to GET; HEAD describes the full representation.
      if (request.method === "GET" && request.headers.range) {
        const match = /^bytes=(\d*)-(\d*)$/.exec(request.headers.range);
        if (!match || (!match[1] && !match[2]))
          throw new HttpError(
            416,
            "invalid_range",
            "Single byte range required",
          );
        if (!match[1]) {
          const suffix = Number(match[2]);
          start = Math.max(0, size - suffix);
          if (suffix === 0) start = size;
        } else {
          start = Number(match[1]);
          end = match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
        }
        if (
          !Number.isSafeInteger(start) ||
          !Number.isSafeInteger(end) ||
          start >= size ||
          start > end
        )
          throw new HttpError(416, "invalid_range", "Range not satisfiable");
        status = 206;
        reply.header("Content-Range", `bytes ${start}-${end}/${size}`);
      }
      reply
        .code(status)
        .header("Content-Length", String(Math.max(0, end - start + 1)));
      if (request.method === "HEAD" || size === 0) {
        reply.send();
        return;
      }
      const stream = handle.createReadStream({ start, end, autoClose: true });
      transferred = true;
      reply.send(stream);
    } catch (error) {
      if (error instanceof HttpError && error.statusCode === 416)
        reply.header("Content-Range", `bytes */${(await handle.stat()).size}`);
      throw error;
    } finally {
      if (!transferred) await handle.close();
    }
  }
}
