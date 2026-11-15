import { DatabaseSync } from "node:sqlite";
import { existsSync, renameSync, chmodSync, unlinkSync } from "node:fs";
import { randomUUID } from "node:crypto";

const schema = `
  CREATE TABLE IF NOT EXISTS device (id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, refresh_hash TEXT UNIQUE NOT NULL, refresh_expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, previous_refresh_hash TEXT, previous_refresh_until INTEGER);
  CREATE TABLE IF NOT EXISTS media_file (id TEXT PRIMARY KEY, root_id TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, mtime TEXT NOT NULL, probe TEXT, UNIQUE(root_id,path));
  CREATE TABLE IF NOT EXISTS login_limit (ip TEXT PRIMARY KEY, attempts INTEGER NOT NULL, reset INTEGER NOT NULL);`;
const retryColumns =
  ", previous_refresh_hash TEXT, previous_refresh_until INTEGER";

function schemaDefinition(db: DatabaseSync) {
  return db
    .prepare(
      "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name",
    )
    .all();
}

function matchesSchema(db: DatabaseSync, sql: string) {
  const reference = new DatabaseSync(":memory:");
  try {
    reference.exec(sql);
    return (
      JSON.stringify(schemaDefinition(db)) ===
      JSON.stringify(schemaDefinition(reference))
    );
  } finally {
    reference.close();
  }
}

// Array position + 1 is the version. Never edit an applied migration; append one.
export const migrations: readonly ((db: DatabaseSync) => void)[] = [
  (db) => {
    if (schemaDefinition(db).length === 0) db.exec(schema);
    else {
      // The only pre-versioning schema lacked refresh retry support.
      db.exec("ALTER TABLE device ADD COLUMN previous_refresh_hash TEXT");
      db.exec("ALTER TABLE device ADD COLUMN previous_refresh_until INTEGER");
    }
  },
];

export function openDatabase(path: string, steps = migrations) {
  const existing = path !== ":memory:" && existsSync(path);
  const db = new DatabaseSync(path);
  try {
    db.exec("PRAGMA busy_timeout=5000");
    let version = (
      db.prepare("PRAGMA user_version").get() as { user_version: number }
    ).user_version;
    if (version > steps.length)
      throw new Error(
        `Database schema version ${version} is newer than supported version ${steps.length}`,
      );
    const unversioned = version === 0 && schemaDefinition(db).length > 0;
    const current = unversioned && matchesSchema(db, schema);
    if (
      unversioned &&
      !current &&
      !matchesSchema(db, schema.replace(retryColumns, ""))
    )
      throw new Error(
        "Unrecognised unversioned database schema; refusing to migrate",
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
      if (current) {
        db.exec("BEGIN IMMEDIATE; PRAGMA user_version=1; COMMIT");
        version = 1;
      }
      for (let index = version; index < steps.length; index++) {
        db.exec("BEGIN IMMEDIATE");
        try {
          steps[index]!(db);
          db.exec(`PRAGMA user_version=${index + 1}; COMMIT`);
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
