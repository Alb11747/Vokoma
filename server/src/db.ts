import { DatabaseSync } from "node:sqlite";
export function openDatabase(path: string) {
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
    CREATE TABLE IF NOT EXISTS device (id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, refresh_hash TEXT UNIQUE NOT NULL, refresh_expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS media_file (id TEXT PRIMARY KEY, root_id TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, mtime TEXT NOT NULL, probe TEXT, UNIQUE(root_id,path));
    CREATE TABLE IF NOT EXISTS login_limit (ip TEXT PRIMARY KEY, attempts INTEGER NOT NULL, reset INTEGER NOT NULL);`);
  return db;
}
export type Database = ReturnType<typeof openDatabase>;
