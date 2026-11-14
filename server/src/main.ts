import { loadConfig } from "./config.js";
import { buildApp } from "./app.js";
import argon2 from "argon2";
import Fastify from "fastify";
const command = process.argv[2] ?? "api";
if (command === "hash-password") {
  let password = "";
  for await (const chunk of process.stdin) password += chunk.toString();
  console.log(
    await argon2.hash(password.replace(/\r?\n$/, ""), {
      type: argon2.argon2id,
    }),
  );
} else if (command === "api") {
  const config = await loadConfig(process.env.VOKOMA_CONFIG ?? "config.json");
  const app = await buildApp(config, { logger: true });
  await app.listen(config.listen);
  for (const signal of ["SIGTERM", "SIGINT"])
    process.once(signal, () => {
      void app.close();
    });
} else if (command === "recorder" || command === "worker") {
  const app = Fastify({ logger: true });
  app.get("/health", async () => ({ status: "ok" }));
  await app.listen({
    host: process.env.VOKOMA_HOST ?? "127.0.0.1",
    port: Number(process.env.VOKOMA_PORT ?? 3000),
  });
  app.log.info({ role: command }, "Nothing to do yet");
  for (const signal of ["SIGTERM", "SIGINT"])
    process.once(signal, () => {
      void app.close();
    });
} else {
  throw new Error("Expected api, recorder, worker or hash-password");
}
