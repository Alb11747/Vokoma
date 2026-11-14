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
  const raw = z
    .object({
      listen: z.record(z.string(), z.unknown()).optional(),
      account: z.record(z.string(), z.unknown()).optional(),
      tokenSecretFile: z.string().optional(),
    })
    .passthrough()
    .parse(JSON.parse(await readFile(file, "utf8")));
  const secretFile =
    process.env.VOKOMA_TOKEN_SECRET_FILE ?? raw.tokenSecretFile;
  return configSchema.parse({
    ...raw,
    listen: {
      ...raw.listen,
      ...(process.env.VOKOMA_HOST && { host: process.env.VOKOMA_HOST }),
      ...(process.env.VOKOMA_PORT && { port: Number(process.env.VOKOMA_PORT) }),
    },
    dataDirectory: process.env.VOKOMA_DATA_DIRECTORY ?? raw.dataDirectory,
    account: {
      ...raw.account,
      ...(process.env.VOKOMA_USERNAME && {
        username: process.env.VOKOMA_USERNAME,
      }),
      ...(process.env.VOKOMA_PASSWORD_HASH && {
        passwordHash: process.env.VOKOMA_PASSWORD_HASH,
      }),
    },
    tokenSecret:
      process.env.VOKOMA_TOKEN_SECRET ??
      (secretFile
        ? (await readFile(secretFile, "utf8")).trim()
        : raw.tokenSecret),
    roots: process.env.VOKOMA_ROOTS
      ? JSON.parse(process.env.VOKOMA_ROOTS)
      : raw.roots,
  });
}
