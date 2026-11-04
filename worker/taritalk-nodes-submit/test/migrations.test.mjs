// The migrations: a clean database and one brought forward from any earlier
// schema end in the same table; every row that was there before is still
// there, column for column, afterwards, the hand-added node_id and its unique
// partial index included; migration 0003 classifies the rows it finds by
// their review state; and the Worker writes into either database.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { openTestDatabase, migrationFiles, BY_HAND_AFTER_0002 } from "./d1-sqlite.mjs";
import { createFakeRateLimiter } from "./fake-rate-limit.mjs";

const BASE = "https://taritalk-nodes-submit.taritalk-status.workers.dev";
const FILES = ["0001_create_submissions.sql", "0002_grpc_url_operator_name.sql",
  "0003_source_and_web_submissions.sql"];
const VALID = {
  schema_version: 2,
  network: "mainnet",
  public_ip: "1.2.3.4",
  p2p_port: 18189,
  minotari_version: "6.0.0",
  installer_version: "0.1.0",
};
const INSERT_V1 = `INSERT INTO submissions (submission_id, submitted_at, source_ip, public_ip, p2p_port,
  network, schema_version, minotari_version, installer_version, wallet_query_url, grpc_address, review_status)
  VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)`;
const INSERT_V2 = `INSERT INTO submissions (submission_id, submitted_at, source_ip, public_ip, p2p_port,
  network, schema_version, minotari_version, installer_version, wallet_query_url, grpc_url, operator_name,
  review_status, reviewed_at, review_note, node_id) VALUES (?, ?, ?, ?, ?, ?, 2, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;
// The live index, as migration 0003 must recreate it.
const NODE_ID_INDEX = "CREATE UNIQUE INDEX submissions_node_id_unique ON submissions (node_id) WHERE node_id IS NOT NULL";

async function indexes(db) {
  return (await db.prepare("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'submissions' ORDER BY name").all())
    .results.map((r) => ({ ...r }));
}

function env(db) {
  return { DB: db, SUBMIT_RATE_LIMIT: createFakeRateLimiter({ limit: 1000 }) };
}

async function rows(db) {
  return (await db.prepare("SELECT * FROM submissions ORDER BY submitted_at").all()).results.map((r) => ({ ...r }));
}

// assertKept: every column every old row had is unchanged in the new row.
function assertKept(before, after) {
  assert.equal(after.length, before.length);
  for (const [i, old] of before.entries()) {
    const row = after[i];
    for (const key of Object.keys(old)) assert.equal(row[key], old[key], `${old.submission_id}.${key}`);
  }
}

// schemaOne: a database as the deployed schema 1 left it, with three rows:
// a gRPC endpoint on 443, none, and one on another port.
async function schemaOne() {
  const db = openTestDatabase({ upTo: 1 });
  assert.deepEqual(migrationFiles(), FILES);
  assert.ok(!db.columns("submissions").includes("grpc_url"));
  const v1 = [
    ["11111111-1111-4111-8111-111111111111", "2026-10-01T10:00:00.000Z", "203.0.113.9", "1.2.3.4", 18189,
      "mainnet", "6.0.0", "0.1.0", "https://wallet.example.com", "grpc.example.com:443", "approved"],
    ["22222222-2222-4222-8222-222222222222", "2026-10-02T10:00:00.000Z", null, "5.6.7.8", 18189,
      "mainnet", "6.0.0", "0.1.0", null, null, "pending"],
    ["33333333-3333-4333-8333-333333333333", "2026-10-03T10:00:00.000Z", "203.0.113.10", "9.9.9.9", 18190,
      "mainnet", "6.0.1", "0.1.0", null, "grpc.example.net:8443", "rejected"],
  ];
  for (const values of v1) await db.prepare(INSERT_V1).bind(...values).run();
  return { db, before: await rows(db) };
}

// schemaTwo: a database as the live one is before 0003: schema 2 plus the
// hand-added node_id and its unique partial index, holding the live mix of
// reviewed historical registrations (approved, with review details and a
// node_id each) and the installer's own pending test submissions (no
// node_id), in no particular number.
async function schemaTwo(approved = 6, pending = 3) {
  const db = openTestDatabase({ upTo: 2 });
  assert.ok(db.columns("submissions").includes("grpc_url"));
  assert.ok(db.columns("submissions").includes("node_id"));
  assert.ok(!db.columns("submissions").includes("source"));
  assert.ok(BY_HAND_AFTER_0002.includes(NODE_ID_INDEX));
  assert.deepEqual((await indexes(db)).map((i) => i.name),
    ["sqlite_autoindex_submissions_1", "submissions_node_id_unique", "submissions_review_status"]);
  let n = 0;
  const add = (status, extra) => db.prepare(INSERT_V2).bind(
    `${String(++n).padStart(8, "0")}-0000-4000-8000-000000000000`, `2026-10-${String(n).padStart(2, "0")}T10:00:00.000Z`,
    status === "pending" ? "203.0.113.9" : null, `5.6.7.${n}`, 18189, "mainnet", "6.1.0", "0.1.0",
    extra.wallet ?? null, extra.grpc ?? null, extra.name ?? null, status,
    status === "pending" ? null : "2026-10-10T00:00:00.000Z", status === "pending" ? null : `node kr-0${n}`,
    status === "pending" ? null : `kr-${String(n).padStart(2, "0")}`).run();
  for (let i = 0; i < approved; i++) await add("approved", { wallet: "https://wallet.example.com", name: i % 2 ? "Test Node" : null });
  for (let i = 0; i < pending; i++) await add("pending", { grpc: "https://grpc-test.nodes.taritalk.xyz", name: "test2" });
  return { db, before: await rows(db) };
}

test("a schema 1 database brought forward keeps every row and gains the URL form of its gRPC endpoint", async () => {
  const { db, before } = await schemaOne();
  db.migrate();
  const after = await rows(db);
  assertKept(before, after);
  for (const row of after) {
    assert.equal(row.operator_name, null);
    assert.equal(row.node_id, null);
    assert.equal(row.request_id, null);
  }
  assert.equal(after[0].grpc_url, "https://grpc.example.com");
  assert.equal(after[0].grpc_address, "grpc.example.com:443");
  assert.equal(after[1].grpc_url, null);
  assert.equal(after[2].grpc_url, "https://grpc.example.net:8443");
  assert.equal(after[2].grpc_address, "grpc.example.net:8443");
  assert.equal(after[0].review_status, "approved");
  assert.equal(after[2].review_status, "rejected");
  assert.deepEqual(after.map((r) => r.source), ["web", "tool", "web"]);
});

test("migration 0003 keeps every live row, column for column, node_id included, and classifies it by review state", async () => {
  const { db, before } = await schemaTwo(6, 3);
  assert.deepEqual(before.map((r) => r.node_id), ["kr-01", "kr-02", "kr-03", "kr-04", "kr-05", "kr-06", null, null, null]);
  db.migrate();
  const after = await rows(db);
  assertKept(before, after);
  for (const row of after) {
    assert.equal(row.source, row.review_status === "pending" ? "tool" : "web", row.submission_id);
    assert.equal(row.request_id, null);
    // What was NOT NULL before is still filled in; only the constraint went.
    assert.equal(row.minotari_version, "6.1.0");
    assert.equal(row.installer_version, "0.1.0");
  }
  assert.deepEqual(after.map((r) => r.node_id), before.map((r) => r.node_id));
  assert.equal(after.filter((r) => r.source === "web").length, 6);
  assert.equal(after.filter((r) => r.source === "tool").length, 3);
  // The rebuilt table is the only table, under its old name, with the live
  // indexes recreated as they were and the new one added.
  assert.deepEqual(db.tableNames(), ["submissions"]);
  const after0003 = await indexes(db);
  assert.deepEqual(after0003.map((i) => i.name),
    ["sqlite_autoindex_submissions_1", "submissions_node_id_unique", "submissions_request_id", "submissions_review_status"]);
  assert.equal(after0003.find((i) => i.name === "submissions_node_id_unique").sql, NODE_ID_INDEX);
});

test("after migration 0003 the node_id index still refuses a second row with the same node_id", async () => {
  const { db } = await schemaTwo(2, 2);
  db.migrate();
  const insert = (nodeId) => db.prepare(`INSERT INTO submissions (submission_id, submitted_at, public_ip, p2p_port,
    network, schema_version, review_status, source, node_id)
    VALUES (?, ?, '1.2.3.4', 18189, 'mainnet', 2, 'approved', 'web', ?)`)
    .bind(crypto.randomUUID(), new Date().toISOString(), nodeId).run();
  await assert.rejects(insert("kr-01"), /UNIQUE constraint failed: submissions.node_id/);
  await insert("kr-99");
  // Rows without a node_id (every pending one) do not collide with each other.
  await insert(null);
  await insert(null);
  assert.equal((await rows(db)).length, 7);
});

test("the count of rows is whatever the database holds, not a fixed number", async () => {
  for (const [approved, pending] of [[0, 0], [1, 0], [0, 1], [41, 4], [50, 7]]) {
    const { db, before } = await schemaTwo(approved, pending);
    db.migrate();
    const after = await rows(db);
    assertKept(before, after);
    assert.equal(after.filter((r) => r.source === "web").length, approved, `${approved}/${pending}`);
    assert.equal(after.filter((r) => r.source === "tool").length, pending, `${approved}/${pending}`);
  }
});

test("a clean database and a brought-forward one have the same table, and both take rows from either route", async () => {
  const clean = openTestDatabase();
  const { db: migrated } = await schemaOne();
  migrated.migrate();
  assert.deepEqual(migrated.columns("submissions"), clean.columns("submissions"));
  assert.deepEqual(clean.tableNames(), ["submissions"]);
  assert.deepEqual(await indexes(migrated), await indexes(clean));
  for (const db of [clean, migrated]) {
    const count = (await rows(db)).length;
    const response = await worker.fetch(new Request(BASE + "/submit", { method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.9" },
      body: JSON.stringify({ ...VALID, grpc_url: "https://grpc-test.nodes.taritalk.xyz", operator_name: "Test Node" }) }), env(db));
    assert.equal(response.status, 200);
    const { submission_id } = await response.json();
    const all = await rows(db);
    assert.equal(all.length, count + 1);
    const row = all.find((r) => r.submission_id === submission_id);
    assert.equal(row.schema_version, 2);
    assert.equal(row.grpc_url, "https://grpc-test.nodes.taritalk.xyz");
    assert.equal(row.grpc_address, null);
    assert.equal(row.operator_name, "Test Node");
    assert.equal(row.review_status, "pending");
    assert.equal(row.source, "tool");
    assert.equal(row.request_id, null);
    // The version columns still take NULL for a web row and refuse an unknown source.
    await db.prepare(`INSERT INTO submissions (submission_id, submitted_at, public_ip, p2p_port, network, schema_version,
      review_status, source, request_id) VALUES (?, ?, '1.2.3.4', 18189, 'mainnet', 2, 'pending', 'web', ?)`)
      .bind(crypto.randomUUID(), new Date().toISOString(), crypto.randomUUID()).run();
    await assert.rejects(db.prepare(`INSERT INTO submissions (submission_id, submitted_at, public_ip, p2p_port, network,
      schema_version, review_status, source) VALUES (?, ?, '1.2.3.4', 18189, 'mainnet', 2, 'pending', 'other')`)
      .bind(crypto.randomUUID(), new Date().toISOString()).run());
  }
  // Schema 1 rows in the brought-forward database are still there, unchanged.
  const old = (await rows(migrated)).filter((r) => r.schema_version === 1);
  assert.equal(old.length, 3);
  assert.equal(old[0].grpc_address, "grpc.example.com:443");
});

test("a schema 1 body is refused with its field named and no row is written", async () => {
  const db = openTestDatabase();
  const response = await worker.fetch(new Request(BASE + "/submit", { method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ...VALID, schema_version: 1, grpc_address: "grpc.example.com:443" }) }), env(db));
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { ok: false, error: "invalid_field", field: "grpc_address" });
  assert.equal((await rows(db)).length, 0);
});
