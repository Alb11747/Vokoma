import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  mkdirSync,
} from "node:fs";
import { spawn } from "node:child_process";
import { once } from "node:events";
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
  let db = new DatabaseSync(path);
  // Frozen CREATE text from main before versioned migrations were introduced.
  db.exec(
    readFileSync(new URL("./fixtures/schema-v1.sql", import.meta.url), "utf8"),
  );
  db.exec("INSERT INTO login_limit VALUES ('fixture', 3, 123)");
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

test("a later migration replaces the previous backup", (t) => {
  const { path, dir } = fixture(t);
  seed(path);
  // A later migration replaces the backup rather than accumulating copies.
  const db = openDatabase(path, [
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

test("a failed backup stops startup without changing the database", (t) => {
  const { path, dir } = fixture(t);
  const db = new DatabaseSync(path);
  db.exec(
    readFileSync(new URL("./fixtures/schema-v1.sql", import.meta.url), "utf8"),
  );
  db.exec("INSERT INTO login_limit VALUES ('fixture', 3, 123)");
  db.close();
  const before = readFileSync(path);
  // A directory cannot be replaced by the completed backup, even when tests run as root.
  mkdirSync(`${path}.bak`);
  assert.throws(() => openDatabase(path), { code: "EISDIR" });
  assert.deepEqual(readFileSync(path), before);
  assert.deepEqual(readdirSync(dir).sort(), [
    "database.sqlite",
    "database.sqlite.bak",
  ]);
});

test("concurrent openers recheck the version after acquiring the write lock", async (t) => {
  const { path } = fixture(t);
  const locker = new DatabaseSync(path);
  locker.exec("BEGIN IMMEDIATE");
  t.after(() => locker.close());
  const children = [0, 1].map(() => {
    const child = spawn(
      process.execPath,
      [
        "--import",
        "tsx",
        "--input-type=module",
        "-e",
        `
      import {DatabaseSync} from 'node:sqlite';
      import {openDatabase, migrations} from ${JSON.stringify(new URL("../src/db.ts", import.meta.url).href)};
      const exec = DatabaseSync.prototype.exec;
      let announced = false;
      DatabaseSync.prototype.exec = function(sql) {
        if (sql === 'BEGIN IMMEDIATE' && !announced) {
          announced = true;
          process.send('waiting');
        }
        return exec.call(this, sql);
      };
      const db = openDatabase(${JSON.stringify(path)}, [...migrations,
        db => db.exec('ALTER TABLE device ADD COLUMN concurrency_fixture TEXT')]);
      db.close();
      process.disconnect();
    `,
      ],
      { stdio: ["ignore", "pipe", "pipe", "ipc"] },
    );
    let diagnostic = "";
    child.stderr.on("data", (chunk) => {
      diagnostic += chunk;
    });
    t.after(() => {
      if (child.exitCode === null) child.kill();
    });
    const completed = once(child, "exit").then(([code]) =>
      assert.equal(code, 0, diagnostic),
    );
    const waiting = Promise.race([
      once(child, "message").then(([message]) =>
        assert.equal(message, "waiting"),
      ),
      completed.then(() => {
        throw new Error("opener exited before waiting for the lock");
      }),
    ]);
    return { completed, waiting };
  });
  await Promise.all(children.map((child) => child.waiting));
  locker.exec("COMMIT");
  await Promise.all(children.map((child) => child.completed));
  const db = new DatabaseSync(path);
  try {
    assert.equal(version(db), 2);
    assert.equal(
      db.prepare("SELECT concurrency_fixture FROM device").all().length,
      0,
    );
  } finally {
    db.close();
  }
});
