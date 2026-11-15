import { z } from "zod";
export const errorSchema = z.object({
  error: z.object({ code: z.string(), message: z.string() }),
});
export const tokenSchema = z.object({
  accessToken: z.string(),
  expiresInSeconds: z.number().int(),
  refreshToken: z.string(),
  deviceId: z.string(),
});
export const loginSchema = z.object({
  username: z.string().min(1).max(256),
  password: z.string().min(1).max(4096),
  deviceName: z.string().min(1).max(256),
  platform: z.string().min(1).max(64),
});
export const trackSchema = z.object({
  index: z.number().int(),
  codec: z.string(),
  language: z.string().nullable(),
  title: z.string().nullable(),
  default: z.boolean(),
  forced: z.boolean(),
});
export const metadataSchema = z.object({
  fileId: z.string(),
  name: z.string(),
  sizeBytes: z.number(),
  durationMs: z.number().nullable(),
  container: z.string(),
  video: z
    .object({
      index: z.number().int(),
      codec: z.string(),
      width: z.number().nullable(),
      height: z.number().nullable(),
      pixelFormat: z.string().nullable(),
      frameRate: z.string().nullable(),
    })
    .nullable(),
  audioTracks: z.array(
    trackSchema.extend({
      channels: z.number().nullable(),
      sampleRate: z.number().nullable(),
    }),
  ),
  subtitleTracks: z.array(trackSchema),
  chapters: z.array(
    z.object({
      startMs: z.number(),
      endMs: z.number(),
      title: z.string().nullable(),
    }),
  ),
});
export type Metadata = z.infer<typeof metadataSchema>;
export const listingSchema = z.object({
  path: z.string(),
  entries: z.array(
    z.union([
      z.object({ name: z.string(), type: z.literal("folder") }),
      z.object({
        name: z.string(),
        type: z.literal("file"),
        fileId: z.string(),
        sizeBytes: z.number(),
        durationMs: z.number().optional(),
      }),
    ]),
  ),
});
export const benchmarkUploadSchema = z.object({
  /** Short label of the device that ran the benchmark, used in the file name. */
  device: z.string().min(1).max(128),
  appVersion: z.string().min(1).max(64),
  /** The results file (JSON Lines) as text. */
  content: z.string().regex(/\S/, "Results are empty"),
});
