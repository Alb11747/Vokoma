import Fastify, { LogController } from "fastify";
import swagger from "@fastify/swagger";
import {
  serializerCompiler,
  validatorCompiler,
  jsonSchemaTransform,
  type ZodTypeProvider,
} from "fastify-type-provider-zod";
import { z } from "zod";
import { readFileSync } from "node:fs";
import { mkdir, realpath } from "node:fs/promises";
import path from "node:path";
import type { Config } from "./config.js";
import { rootSchema } from "./config.js";
import { openDatabase } from "./db.js";
import { Auth } from "./auth.js";
import { Files } from "./library/files.js";
import { probe } from "./media/probe.js";
import { sendContent } from "./media/content.js";
import { HttpError } from "./errors.js";
import { saveBenchmarkUpload } from "./diagnostics.js";
import {
  errorSchema,
  tokenSchema,
  loginSchema,
  metadataSchema,
  listingSchema,
  benchmarkUploadSchema,
} from "./schemas.js";
// package.json sits one level above both src/ and dist/.
const { version } = JSON.parse(
  readFileSync(new URL("../package.json", import.meta.url), "utf8"),
) as { version: string };
declare module "fastify" {
  interface FastifyRequest {
    deviceId: string;
  }
}
const statusCodes: Record<number, string> = {
  400: "invalid_request",
  401: "unauthorized",
  403: "forbidden",
  404: "not_found",
  413: "payload_too_large",
  415: "unsupported_media_type",
  416: "invalid_range",
  429: "rate_limited",
};
/** Real path of a location that may not exist yet: resolves the nearest existing ancestor. */
async function resolveDestination(target: string): Promise<string> {
  try {
    return await realpath(target);
  } catch (error) {
    const parent = path.dirname(target);
    if ((error as NodeJS.ErrnoException).code !== "ENOENT" || parent === target)
      throw error;
    return path.join(await resolveDestination(parent), path.basename(target));
  }
}
export async function buildApp(
  config: Config,
  options: { logger?: boolean; contractOnly?: boolean } = {},
) {
  const app = Fastify({
    logger: options.logger
      ? {
          redact: [
            "req.headers.authorization",
            "req.body",
            "res.headers.authorization",
          ],
        }
      : false,
    logController: new LogController({ disableRequestLogging: true }),
    trustProxy: config.trustProxy,
    bodyLimit: 16 * 1024,
  }).withTypeProvider<ZodTypeProvider>();
  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);
  await app.register(swagger, {
    openapi: {
      info: { title: "Vokoma M0 API", version },
      components: {
        securitySchemes: { bearerAuth: { type: "http", scheme: "bearer" } },
      },
      security: [{ bearerAuth: [] }],
    },
    transform: jsonSchemaTransform,
  });
  if (!options.contractOnly) {
    // Media roots are read-only to this server. Refuse a data directory that
    // resolves inside one (directly or through a symlink) before creating
    // anything, since SQLite would write its files there.
    const data = await resolveDestination(path.resolve(config.dataDirectory));
    for (const root of config.roots) {
      const media = await realpath(root.path);
      if (data === media || data.startsWith(media + path.sep))
        throw new Error("Data directory must be outside media roots");
    }
    await mkdir(config.dataDirectory, { recursive: true });
  }
  const db = openDatabase(
    options.contractOnly
      ? ":memory:"
      : path.join(config.dataDirectory, "vokoma.sqlite"),
  );
  app.addHook("onClose", async () => {
    db.close();
  });
  const auth = new Auth(db, config),
    files = new Files(config, db, app.log);
  app.setErrorHandler((error, request, reply) => {
    const err = error as Error & { statusCode?: number; validation?: unknown };
    // Only HttpError and Fastify's own 4xx errors reach the client as such; any
    // other failure is a server fault, logged in full.
    const status = err.validation
      ? 400
      : err instanceof HttpError
        ? err.statusCode
        : err.statusCode && err.statusCode >= 400 && err.statusCode < 500
          ? err.statusCode
          : 500;
    if (status >= 500) request.log.error({ err }, "Request failed");
    reply.removeHeader("Content-Length");
    reply
      .code(status)
      .type("application/json")
      .send({
        error:
          err instanceof HttpError
            ? { code: err.code, message: err.message }
            : status >= 500
              ? { code: "internal_error", message: "Request failed" }
              : {
                  code: statusCodes[status] ?? "invalid_request",
                  message: err.validation ? "Invalid request" : err.message,
                },
      });
  });
  app.setNotFoundHandler((_req, reply) =>
    reply
      .code(404)
      .send({ error: { code: "not_found", message: "Not found" } }),
  );
  const errors = {
    400: errorSchema,
    401: errorSchema,
    403: errorSchema,
    404: errorSchema,
    422: errorSchema,
    429: errorSchema,
    500: errorSchema,
  };
  app.decorateRequest("deviceId", "");
  const secured = async (request: import("fastify").FastifyRequest) => {
    request.deviceId = await auth.authorize(request.headers.authorization);
  };
  app.get(
    "/api/server",
    {
      schema: {
        security: [],
        response: {
          200: z.object({
            name: z.string(),
            version: z.string(),
            apiVersion: z.number(),
          }),
        },
      },
    },
    async () => ({ name: "Vokoma", version, apiVersion: 1 }),
  );
  app.post(
    "/api/auth/login",
    {
      schema: {
        security: [],
        body: loginSchema,
        response: { 200: tokenSchema, ...errors },
      },
    },
    async (req) => auth.login(req.body, req.ip),
  );
  app.post(
    "/api/auth/refresh",
    {
      schema: {
        security: [],
        body: z.object({ refreshToken: z.string().min(1).max(512) }),
        response: { 200: tokenSchema, ...errors },
      },
    },
    async (req) => auth.refresh(req.body.refreshToken),
  );
  app.post(
    "/api/auth/logout",
    { preHandler: secured, schema: { response: { 204: z.null(), ...errors } } },
    async (req, reply) => {
      auth.revoke(req.deviceId);
      reply.code(204).send(null);
    },
  );
  app.get(
    "/api/roots",
    {
      preHandler: secured,
      schema: {
        response: {
          200: z.object({ roots: z.array(rootSchema.omit({ path: true })) }),
          ...errors,
        },
      },
    },
    async () => ({
      roots: config.roots.map(({ id, name, kind }) => ({ id, name, kind })),
    }),
  );
  app.get(
    "/api/roots/:rootId/entries",
    {
      preHandler: secured,
      schema: {
        params: z.object({ rootId: z.string() }),
        querystring: z.object({ path: z.string().default("") }),
        response: { 200: listingSchema, ...errors },
      },
    },
    async (req) => files.list(req.params.rootId, req.query.path),
  );
  app.get(
    "/api/files/:fileId",
    {
      preHandler: secured,
      schema: {
        params: z.object({ fileId: z.string() }),
        response: { 200: metadataSchema, ...errors },
      },
    },
    async (req) => {
      const { row, handle } = await files.get(req.params.fileId);
      try {
        return await probe(db, row, handle);
      } finally {
        await handle.close();
      }
    },
  );
  app.route({
    method: ["GET", "HEAD"],
    url: "/api/files/:fileId/content",
    preHandler: secured,
    schema: {
      params: z.object({ fileId: z.string() }),
      response: { ...errors, 416: errorSchema },
    },
    handler: async (req, reply) => {
      const { handle } = await files.get(req.params.fileId);
      await sendContent(req, reply, handle);
      return reply;
    },
  });
  app.post(
    "/api/diagnostics/benchmark",
    {
      // Authorize before the body is read, so only a signed-in device can
      // make the server buffer a large upload.
      onRequest: secured,
      // A results file from a long run; the default limit is for small JSON.
      bodyLimit: 16 * 1024 * 1024,
      schema: {
        body: benchmarkUploadSchema,
        response: {
          201: z.object({ name: z.string() }),
          ...errors,
          413: errorSchema,
        },
      },
    },
    async (req, reply) => {
      const name = await saveBenchmarkUpload(config.dataDirectory, req.body);
      req.log.info(
        { name, length: req.body.content.length },
        "Benchmark results uploaded",
      );
      reply.code(201);
      return { name };
    },
  );
  await app.ready();
  return app;
}
