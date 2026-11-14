import { readFile } from "node:fs/promises";
import { z } from "zod";

export const rootSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  kind: z.enum(["anime", "stream", "movie", "tv"]),
  path: z.string().min(1),
});
export const configSchema = z.object({
  listen: z
    .object({
      host: z.string().default("127.0.0.1"),
      port: z.number().int().min(1).max(65535).default(3000),
    })
    .default({ host: "127.0.0.1", port: 3000 }),
  // Passed to Fastify's trustProxy: the reverse proxy's address(es), so the login
  // limiter sees each client's address from X-Forwarded-For instead of the proxy's.
  trustProxy: z
    .union([z.boolean(), z.string(), z.array(z.string())])
    .default(false),
  dataDirectory: z.string().min(1),
  account: z.object({
    username: z.string().min(1),
    passwordHash: z.string().startsWith("$argon2id$"),
  }),
  tokenSecret: z.string().min(32),
  roots: z
    .array(rootSchema)
    .refine(
      (roots) => new Set(roots.map((r) => r.id)).size === roots.length,
      "Root IDs must be unique",
    ),
});
export type Config = z.infer<typeof configSchema>;
export async function loadConfig(file: string): Promise<Config> {
  const raw = JSON.parse(await readFile(file, "utf8"));
  // Only the overrides the container needs; everything else lives in the file.
  return configSchema.parse({
    ...raw,
    listen: {
      ...raw.listen,
      ...(process.env.VOKOMA_HOST && { host: process.env.VOKOMA_HOST }),
    },
    dataDirectory: process.env.VOKOMA_DATA_DIRECTORY ?? raw.dataDirectory,
    tokenSecret: raw.tokenSecretFile
      ? (await readFile(raw.tokenSecretFile, "utf8")).trim()
      : raw.tokenSecret,
  });
}
