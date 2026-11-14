import path from "node:path";
import argon2 from "argon2";
import { loadConfig } from "./config.js";
import { buildApp } from "./app.js";
import { openDatabase } from "./db.js";
const [command = "api", argument] = process.argv.slice(2);
const configFile = process.env.VOKOMA_CONFIG ?? "config.json";
if (command === "hash-password") {
  let password = "";
  for await (const chunk of process.stdin) password += chunk.toString();
  console.log(
    await argon2.hash(password.replace(/\r?\n$/, ""), {
      type: argon2.argon2id,
    }),
  );
} else if (command === "api") {
  const config = await loadConfig(configFile);
  const app = await buildApp(config, { logger: true });
  await app.listen(config.listen);
  for (const signal of ["SIGTERM", "SIGINT"])
    process.once(signal, () => {
      void app.close();
    });
} else if (command === "devices" || command === "revoke") {
  // Device management for the owner; safe to run while the server is up
  // (SQLite WAL), and a revocation takes effect on the device's next request.
  const config = await loadConfig(configFile);
  const db = openDatabase(path.join(config.dataDirectory, "vokoma.sqlite"));
  try {
    if (command === "devices") {
      const devices = db
        .prepare(
          "SELECT id, name, platform, revoked, refresh_expires FROM device ORDER BY rowid",
        )
        .all() as {
        id: string;
        name: string;
        platform: string;
        revoked: number;
        refresh_expires: number;
      }[];
      for (const d of devices) {
        const state = d.revoked
          ? "revoked"
          : d.refresh_expires <= Date.now()
            ? "expired"
            : `active until ${new Date(d.refresh_expires).toISOString()}`;
        console.log(`${d.id}\t${d.platform}\t${d.name}\t${state}`);
      }
    } else {
      if (!argument) throw new Error("Usage: revoke <device id>");
      const { changes } = db
        .prepare("UPDATE device SET revoked=1 WHERE id=?")
        .run(argument);
      if (!changes) throw new Error(`No device with id ${argument}`);
      console.log(`Revoked ${argument}`);
    }
  } finally {
    db.close();
  }
} else {
  throw new Error("Expected api, hash-password, devices or revoke <device id>");
}
