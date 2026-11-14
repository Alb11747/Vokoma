import Fastify, { LogController } from "fastify";
import swagger from "@fastify/swagger";
import {
  serializerCompiler,
  validatorCompiler,
  jsonSchemaTransform,
  type ZodTypeProvider,
} from "fastify-type-provider-zod";
import { z } from "zod";
import { mkdir, realpath } from "node:fs/promises";
import path from "node:path";
import type { Config } from "./config.js";
import { rootSchema } from "./config.js";
import { openDatabase } from "./db.js";
import { Auth } from "./auth.js";
import { Files } from "./library/files.js";
import { probe } from "./media/probe.js";
import { NodeContentSender, type ContentSender } from "./media/content.js";
import { HttpError } from "./errors.js";
import {
  errorSchema,
  tokenSchema,
  loginSchema,
  metadataSchema,
  listingSchema,
} from "./schemas.js";
export async function buildApp(
  config: Config,
  options: {
    logger?: boolean;
    contractOnly?: boolean;
    contentSender?: ContentSender;
  } = {},
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
    routerOptions: { maxParamLength: 4096 },
    bodyLimit: 16 * 1024,
  }).withTypeProvider<ZodTypeProvider>();
  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);
  await app.register(swagger, {
    openapi: {
      info: { title: "Vokoma M0 API", version: "1.0.0" },
      components: {
        securitySchemes: { bearerAuth: { type: "http", scheme: "bearer" } },
      },
      security: [{ bearerAuth: [] }],
    },
    transform: jsonSchemaTransform,
  });
  if (!options.contractOnly) {
    // Resolve existing ancestors before creating anything: configuration must never
    // redirect database writes into a media root, including via a symlink.
    const destination = async (location: string): Promise<string> => {
      try {
        return await realpath(location);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        return path.join(
          await destination(path.dirname(location)),
          path.basename(location),
        );
      }
    };
    const data = await destination(path.resolve(config.dataDirectory));
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
    files = new Files(config, db),
    sender = options.contentSender ?? new NodeContentSender();
  app.setErrorHandler((error, request, reply) => {
    const err = error as Error & {
      code?: string;
      statusCode?: number;
      validation?: unknown;
    };
    const status = err.validation
      ? 400
      : err instanceof HttpError
        ? err.statusCode
        : err.code === "ENOENT" || err.code === "ENOTDIR"
          ? 404
          : err.code === "ELOOP" || err.code === "EACCES"
            ? 403
            : err.statusCode && err.statusCode < 500
              ? err.statusCode
              : 500;
    if (status >= 500)
      app.log.error({ code: err.code ?? "internal_error" }, "Request failed");
    reply.removeHeader("Content-Length");
    reply
      .code(status)
      .type("application/json")
      .send({
        error: {
          code:
            err instanceof HttpError
              ? err.code
              : status === 400
                ? "invalid_request"
                : status === 404
                  ? "not_found"
                  : status === 403
                    ? "forbidden"
                    : "internal_error",
          message:
            err instanceof HttpError
              ? err.message
              : status === 400
                ? "Invalid request"
                : status === 404
                  ? "Not found"
                  : status === 403
                    ? "Access refused"
                    : "Request failed",
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
  const secured = async (request: import("fastify").FastifyRequest) => {
    await auth.authorize(request.headers.authorization);
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
    async () => ({ name: "Vokoma", version: "0.0.0", apiVersion: 1 }),
  );
  app.get(
    "/health",
    { schema: { hide: true }, preHandler: secured },
    async () => ({ status: "ok" }),
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
      auth.revoke(await auth.authorize(req.headers.authorization));
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
      await sender.send(req, reply, handle);
      return reply;
    },
  });
  await app.ready();
  return app;
}
