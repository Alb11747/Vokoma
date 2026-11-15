import { DatabaseSync } from "node:sqlite";
import { existsSync, renameSync, chmodSync, unlinkSync } from "node:fs";
import { randomUUID } from "node:crypto";

const schema = `
  CREATE TABLE IF NOT EXISTS device (id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, refresh_hash TEXT UNIQUE NOT NULL, refresh_expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, previous_refresh_hash TEXT, previous_refresh_until INTEGER);
  CREATE TABLE IF NOT EXISTS media_file (id TEXT PRIMARY KEY, root_id TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, mtime TEXT NOT NULL, probe TEXT, UNIQUE(root_id,path));
  CREATE TABLE IF NOT EXISTS login_limit (ip TEXT PRIMARY KEY, attempts INTEGER NOT NULL, reset INTEGER NOT NULL);`;
// Array position + 1 is the version. Never edit an applied migration; append one.
export const migrations: readonly ((db: DatabaseSync) => void)[] = [
  (db) => db.exec(schema),
];

export function openDatabase(path: string, steps = migrations) {
  const existing = path !== ":memory:" && existsSync(path);
  const db = new DatabaseSync(path);
  try {
    db.exec("PRAGMA busy_timeout=5000");
    const version = (
      db.prepare("PRAGMA user_version").get() as { user_version: number }
    ).user_version;
    if (version > steps.length)
      throw new Error(
        `Database schema version ${version} is newer than supported version ${steps.length}`,
      );
    if (version < steps.length) {
      if (existing) {
        // VACUUM INTO makes a consistent file copy, including committed WAL data.
        // Replace the previous backup only after the new copy is complete.
        const temporary = `${path}.backup-${randomUUID()}`;
        try {
          db.exec(`VACUUM INTO '${temporary.replaceAll("'", "''")}'`);
          chmodSync(temporary, 0o600);
          renameSync(temporary, `${path}.bak`);
        } finally {
          if (existsSync(temporary)) unlinkSync(temporary);
        }
      }
      for (let index = version; index < steps.length; index++) {
        db.exec("BEGIN IMMEDIATE");
        try {
          // Another opener may have migrated while this connection waited.
          const lockedVersion = (
            db.prepare("PRAGMA user_version").get() as { user_version: number }
          ).user_version;
          if (lockedVersion > steps.length)
            throw new Error(
              `Database schema version ${lockedVersion} is newer than supported version ${steps.length}`,
            );
          if (lockedVersion <= index) {
            steps[index]!(db);
            db.exec(`PRAGMA user_version=${index + 1}`);
          }
          db.exec("COMMIT");
        } catch (cause) {
          db.exec("ROLLBACK");
          throw new Error(`Database migration ${index + 1} failed`, { cause });
        }
      }
    }
    db.exec("PRAGMA journal_mode=WAL");
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}
export type Database = ReturnType<typeof openDatabase>;
