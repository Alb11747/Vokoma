import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDatabase, migrations } from "../src/db.js";

function fixture(t: import("node:test").TestContext) {
  const dir = mkdtempSync(join(tmpdir(), "vokoma-db-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return { dir, path: join(dir, "database.sqlite") };
}
function version(db: DatabaseSync) {
  return db.prepare("PRAGMA user_version").get()!.user_version;
}
function seed(path: string) {
  const db = openDatabase(path);
  db.exec("INSERT INTO login_limit VALUES ('fixture', 3, 123)");
  db.close();
}

test("fresh database runs migrations once and needs no backup", (t) => {
  const { path, dir } = fixture(t);
  let db = openDatabase(path);
  assert.equal(version(db), 1);
  assert.equal(
    db
      .prepare(
        "SELECT previous_refresh_hash, previous_refresh_until FROM device",
      )
      .all().length,
    0,
  );
  db.close();
  db = openDatabase(path);
  assert.equal(version(db), 1);
  db.close();
  assert.deepEqual(readdirSync(dir), ["database.sqlite"]);
});

test("current unversioned database is stamped without schema or data changes", (t) => {
  const { path } = fixture(t);
  seed(path);
  let db = new DatabaseSync(path);
  db.exec("PRAGMA user_version=0");
  const schema = db.prepare("SELECT * FROM sqlite_schema").all();
  db.close();
  db = openDatabase(path);
  assert.equal(version(db), 1);
  assert.deepEqual(db.prepare("SELECT * FROM sqlite_schema").all(), schema);
  assert.equal(
    db.prepare("SELECT attempts FROM login_limit").get()!.attempts,
    3,
  );
  db.close();
  const backup = new DatabaseSync(`${path}.bak`);
  assert.equal(version(backup), 0);
  assert.equal(
    backup.prepare("SELECT attempts FROM login_limit").get()!.attempts,
    3,
  );
  backup.close();
});

test("old unversioned schema gains refresh retry columns and preserves rows", (t) => {
  const { path, dir } = fixture(t);
  seed(path);
  let db = new DatabaseSync(path);
  db.exec(`PRAGMA user_version=0;
    ALTER TABLE device DROP COLUMN previous_refresh_hash;
    ALTER TABLE device DROP COLUMN previous_refresh_until;
    INSERT INTO device (id,name,platform,refresh_hash,refresh_expires) VALUES ('id','fixture','test','hash',123);`);
  db.close();
  db = openDatabase(path);
  assert.equal(version(db), 1);
  assert.deepEqual(
    {
      ...db
        .prepare(
          "SELECT previous_refresh_hash, previous_refresh_until FROM device WHERE id='id'",
        )
        .get(),
    },
    { previous_refresh_hash: null, previous_refresh_until: null },
  );
  db.close();
  // A later migration replaces the backup rather than accumulating copies.
  db = openDatabase(path, [
    ...migrations,
    (db) => db.exec("CREATE TABLE next (id TEXT)"),
  ]);
  assert.equal(version(db), 2);
  db.close();
  assert.deepEqual(readdirSync(dir).sort(), [
    "database.sqlite",
    "database.sqlite.bak",
  ]);
  const backup = new DatabaseSync(`${path}.bak`);
  assert.equal(version(backup), 1);
  backup.close();
});

test("newer database is refused without changing it or creating a backup", (t) => {
  const { path, dir } = fixture(t);
  const db = new DatabaseSync(path);
  db.exec("PRAGMA user_version=99");
  db.close();
  const before = readFileSync(path);
  assert.throws(
    () => openDatabase(path),
    /version 99 is newer than supported version 1/,
  );
  assert.deepEqual(readFileSync(path), before);
  assert.deepEqual(readdirSync(dir), ["database.sqlite"]);
});

test("failing migration rolls back schema, data and version", (t) => {
  const { path } = fixture(t);
  seed(path);
  const before = readFileSync(path);
  assert.throws(
    () =>
      openDatabase(path, [
        ...migrations,
        (db) => {
          db.exec(
            "ALTER TABLE device ADD COLUMN example TEXT; DELETE FROM login_limit",
          );
          throw new Error("fixture failure");
        },
      ]),
    /migration 2 failed/,
  );
  assert.deepEqual(readFileSync(path), before);
  // VACUUM INTO preserves the logical snapshot, not SQLite page/header bytes.
  const backup = new DatabaseSync(`${path}.bak`);
  assert.equal(version(backup), 1);
  assert.equal(
    backup.prepare("SELECT attempts FROM login_limit").get()!.attempts,
    3,
  );
  assert.equal(
    backup
      .prepare(
        "SELECT name FROM pragma_table_info('device') WHERE name='example'",
      )
      .get(),
    undefined,
  );
  backup.close();
  const db = openDatabase(path);
  assert.equal(version(db), 1);
  assert.equal(
    db.prepare("SELECT attempts FROM login_limit").get()!.attempts,
    3,
  );
  db.close();
});

test("unknown unversioned schema is refused instead of stamped", (t) => {
  const { path } = fixture(t);
  const db = new DatabaseSync(path);
  db.exec("CREATE TABLE unrelated (id TEXT)");
  db.close();
  const before = readFileSync(path);
  assert.throws(() => openDatabase(path), /Unrecognised unversioned/);
  assert.deepEqual(readFileSync(path), before);
});

test("backup includes committed data still in the WAL", (t) => {
  const { path } = fixture(t);
  const writer = openDatabase(path);
  try {
    writer.exec(
      "PRAGMA wal_autocheckpoint=0; PRAGMA user_version=0; INSERT INTO login_limit VALUES ('wal',4,123)",
    );
    const db = openDatabase(path);
    db.close();
    const backup = new DatabaseSync(`${path}.bak`);
    try {
      assert.equal(version(backup), 0);
      assert.equal(
        backup.prepare("SELECT attempts FROM login_limit WHERE ip='wal'").get()!
          .attempts,
        4,
      );
    } finally {
      backup.close();
    }
  } finally {
    writer.close();
  }
});
