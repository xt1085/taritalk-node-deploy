// A stand-in for the D1 binding, for tests: the subset the Worker uses
// (prepare().bind().run(), .first()) plus reads for assertions, over an
// isolated SQLite database (node:sqlite) that the real migrations created,
// in order, with the live database's hand-made additions in their place.
// openTestDatabase({ upTo: N }) stops after migration N (by its number), and
// migrate() then applies the rest, as `wrangler d1 migrations apply` would
// on an existing database.
import { DatabaseSync } from "node:sqlite";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const MIGRATIONS_DIR = fileURLToPath(new URL("../migrations/", import.meta.url));

// What the live database has beyond its migrations: after 0002 the published
// node's identifier and its unique partial index were added by hand, and
// migration 0003 expects both. A database built here gets them at the same
// point, so it has the live table's shape when 0003 runs.
export const BY_HAND_AFTER_0002 = `ALTER TABLE submissions ADD COLUMN node_id TEXT;
CREATE UNIQUE INDEX submissions_node_id_unique ON submissions (node_id) WHERE node_id IS NOT NULL;`;

export function migrationFiles() {
  return readdirSync(MIGRATIONS_DIR).filter((name) => /^[0-9]{4}_.*\.sql$/.test(name)).sort();
}

export function openTestDatabase({ upTo = Infinity } = {}) {
  const db = new DatabaseSync(":memory:");
  let applied = 0;
  const apply = (name) => {
    db.exec(readFileSync(MIGRATIONS_DIR + name, "utf8"));
    applied = Number(name.slice(0, 4));
    if (applied === 2) db.exec(BY_HAND_AFTER_0002);
  };
  const migrate = () => {
    for (const name of migrationFiles()) {
      if (Number(name.slice(0, 4)) > applied) apply(name);
    }
  };
  for (const name of migrationFiles()) {
    if (Number(name.slice(0, 4)) > upTo) break;
    apply(name);
  }
  return {
    prepare(sql) {
      const statement = db.prepare(sql);
      let values = [];
      const bound = {
        bind(...args) {
          values = args;
          return bound;
        },
        async run() {
          const result = statement.run(...values);
          return { success: true, meta: { changes: result.changes } };
        },
        async all() {
          return { success: true, results: statement.all(...values) };
        },
        async first() {
          return statement.get(...values) ?? null;
        },
      };
      return bound;
    },
    migrate,
    tableNames() {
      return db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all().map((r) => r.name);
    },
    columns(table) {
      return db.prepare(`PRAGMA table_info(${table})`).all().map((r) => r.name);
    },
    close() {
      db.close();
    },
  };
}
