import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { buildApp } from "./app.js";
const app = await buildApp(
  {
    listen: { host: "127.0.0.1", port: 3000 },
    dataDirectory: ".",
    account: { username: "placeholder", passwordHash: "$argon2id$placeholder" },
    tokenSecret: "placeholder-secret-for-contract-generation",
    roots: [],
  },
  { contractOnly: true },
);
try {
  const doc = app.swagger() as import("openapi-types").OpenAPIV3.Document;
  // The byte response bypasses JSON serialization; describe it explicitly for code generation.
  for (const method of ["get", "head"] as const) {
    const route = doc.paths?.["/api/files/{fileId}/content"]?.[method];
    if (route) {
      route.parameters = [
        ...(route.parameters ?? []),
        {
          in: "header",
          name: "Range",
          schema: { type: "string" },
          description: "One byte range. HEAD ignores Range.",
        },
      ];
      route.responses = {
        ...route.responses,
        200: {
          description: "Full file",
          content: {
            "application/octet-stream": {
              schema: { type: "string", format: "binary" },
            },
          },
        },
        206: {
          description: "Partial file",
          content: {
            "application/octet-stream": {
              schema: { type: "string", format: "binary" },
            },
          },
        },
      };
    }
  }
  const logout = doc.paths?.["/api/auth/logout"]?.post;
  if (logout)
    logout.responses["204"] = {
      description: "Device revoked; no response body",
    };
  const text = JSON.stringify(doc, null, 2) + "\n";
  const file = fileURLToPath(
    new URL("../../contracts/openapi.json", import.meta.url),
  );
  if (process.argv.includes("--check")) {
    if ((await readFile(file, "utf8")) !== text)
      throw new Error("contracts/openapi.json is stale. Run pnpm openapi.");
  } else await writeFile(file, text);
} finally {
  await app.close();
}
