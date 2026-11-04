import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { MAX_BODY_BYTES, MAX_OPERATOR_NAME_CHARS, isPublicIPv4, isDomain, isOperatorName } from "../src/index.js";
import { openTestDatabase } from "./d1-sqlite.mjs";
import { createFakeRateLimiter } from "./fake-rate-limit.mjs";

const BASE = "https://taritalk-nodes-submit.taritalk-status.workers.dev";
const VALID = {
  schema_version: 2,
  network: "mainnet",
  public_ip: "1.2.3.4",
  p2p_port: 18189,
  minotari_version: "6.0.0",
  installer_version: "0.1.0",
};

function post(path, body, headers = {}) {
  return new Request(BASE + path, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

// env: a fresh database behind a fresh (never limiting, for these tests)
// rate limiter; the limit itself is covered by rate-limit.test.mjs.
function env(db) {
  return { DB: db, SUBMIT_RATE_LIMIT: createFakeRateLimiter({ limit: 1000 }) };
}

async function rows(db) {
  return (await db.prepare("SELECT * FROM submissions ORDER BY submitted_at").all()).results;
}

test("a valid submission is stored once, as pending, with the observed source IP", async () => {
  const db = openTestDatabase();
  const response = await worker.fetch(post("/submit", { ...VALID,
    wallet_query_url: "https://wallet.example.com", grpc_url: "https://grpc-test.nodes.taritalk.xyz",
    operator_name: "Test Node 测试" },
  { "cf-connecting-ip": "203.0.113.9" }), env(db));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const answer = await response.json();
  assert.deepEqual(Object.keys(answer).sort(), ["ok", "status", "submission_id"]);
  assert.equal(answer.ok, true);
  assert.equal(answer.status, "pending");
  assert.match(answer.submission_id, /^[0-9a-f-]{36}$/);
  const stored = await rows(db);
  assert.equal(stored.length, 1);
  const row = stored[0];
  assert.equal(row.submission_id, answer.submission_id);
  assert.equal(row.review_status, "pending");
  assert.equal(row.source_ip, "203.0.113.9");
  assert.equal(row.public_ip, "1.2.3.4");
  assert.equal(row.p2p_port, 18189);
  assert.equal(row.network, "mainnet");
  assert.equal(row.schema_version, 2);
  assert.equal(row.minotari_version, "6.0.0");
  assert.equal(row.installer_version, "0.1.0");
  assert.equal(row.wallet_query_url, "https://wallet.example.com");
  assert.equal(row.grpc_url, "https://grpc-test.nodes.taritalk.xyz");
  assert.equal(row.grpc_address, null);
  assert.equal(row.operator_name, "Test Node 测试");
  assert.equal(row.reviewed_at, null);
  assert.equal(row.review_note, null);
  assert.match(row.submitted_at, /^\d{4}-\d{2}-\d{2}T/);
  // Migration 0003: the installer's rows say so, and carry no web request key.
  assert.equal(row.source, "tool");
  assert.equal(row.request_id, null);
  assert.deepEqual(db.tableNames(), ["submissions"]);
});

test("optional endpoints and the operator name are NULL when absent, never a placeholder", async () => {
  const db = openTestDatabase();
  const response = await worker.fetch(post("/submit", VALID), env(db));
  assert.equal(response.status, 200);
  const [row] = await rows(db);
  assert.equal(row.wallet_query_url, null);
  assert.equal(row.grpc_url, null);
  assert.equal(row.grpc_address, null);
  assert.equal(row.operator_name, null);
  assert.equal(row.source_ip, null);
  assert.ok(!JSON.stringify(row).includes("Anonymous"), JSON.stringify(row));
});

test("each of the four Wallet Query and gRPC combinations is stored as sent", async () => {
  const db = openTestDatabase();
  const wq = "https://wallet.example.com";
  const grpc = "https://grpc-test.nodes.taritalk.xyz";
  for (const [body, expected] of [
    [{}, { wallet_query_url: null, grpc_url: null }],
    [{ wallet_query_url: wq }, { wallet_query_url: wq, grpc_url: null }],
    [{ grpc_url: grpc }, { wallet_query_url: null, grpc_url: grpc }],
    [{ wallet_query_url: wq, grpc_url: grpc }, { wallet_query_url: wq, grpc_url: grpc }],
  ]) {
    const response = await worker.fetch(post("/submit", { ...VALID, ...body }), env(db));
    assert.equal(response.status, 200, JSON.stringify(body));
    const { submission_id } = await response.json();
    const row = (await rows(db)).find((r) => r.submission_id === submission_id);
    assert.equal(row.wallet_query_url, expected.wallet_query_url, JSON.stringify(body));
    assert.equal(row.grpc_url, expected.grpc_url, JSON.stringify(body));
    assert.equal(row.grpc_address, null);
    assert.ok(!(row.grpc_url ?? "").endsWith(":443"), row.grpc_url);
  }
  assert.equal((await rows(db)).length, 4);
});

test("an operator name is stored exactly as sent, in any script", async () => {
  const db = openTestDatabase();
  const names = ["Test Node", "测试", "Émile Zola", "Ярослав", "日本語ノード", "@TariFans", "Ünïcode Ltd.",
    "node-1.example.com", "😀 Tari fan", "a\u0301", "x".repeat(MAX_OPERATOR_NAME_CHARS), "测".repeat(MAX_OPERATOR_NAME_CHARS)];
  for (const name of names) {
    const response = await worker.fetch(post("/submit", { ...VALID, operator_name: name }), env(db));
    assert.equal(response.status, 200, JSON.stringify(name));
    const { submission_id } = await response.json();
    const row = (await rows(db)).find((r) => r.submission_id === submission_id);
    assert.equal(row.operator_name, name);
  }
  assert.equal((await rows(db)).length, names.length);
});

test("two submissions get two different IDs and two rows", async () => {
  const db = openTestDatabase();
  const a = await (await worker.fetch(post("/submit", VALID), env(db))).json();
  const b = await (await worker.fetch(post("/submit", VALID), env(db))).json();
  assert.notEqual(a.submission_id, b.submission_id);
  assert.equal((await rows(db)).length, 2);
});

test("GET, HEAD and other routes expose nothing and store nothing", async () => {
  const db = openTestDatabase();
  await worker.fetch(post("/submit", VALID), env(db));
  for (const [method, path, status] of [
    ["GET", "/submit", 405], ["HEAD", "/submit", 405], ["PUT", "/submit", 405], ["DELETE", "/submit", 405],
    ["GET", "/", 404], ["GET", "/submissions", 404], ["GET", "/list", 404], ["GET", "/admin", 404],
    ["POST", "/", 404], ["POST", "/submissions", 404], ["POST", "/submit/", 404], ["GET", "/submit?id=1", 405],
  ]) {
    const response = await worker.fetch(new Request(BASE + path, { method }), env(db));
    assert.equal(response.status, status, `${method} ${path}`);
    const text = await response.text();
    assert.ok(!text.includes("1.2.3.4") && !text.includes("submission_id"), `${method} ${path} leaked: ${text}`);
  }
  assert.equal((await rows(db)).length, 1);
});

test("invalid JSON, a wrong content type and an oversized body are rejected without a row", async () => {
  const db = openTestDatabase();
  let response = await worker.fetch(post("/submit", "{not json"), env(db));
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { ok: false, error: "invalid_json" });
  response = await worker.fetch(post("/submit", "[1,2]"), env(db));
  assert.equal(response.status, 400);
  response = await worker.fetch(post("/submit", JSON.stringify(VALID), { "content-type": "text/plain" }), env(db));
  assert.equal(response.status, 415);
  const big = JSON.stringify({ ...VALID, installer_version: "x".repeat(MAX_BODY_BYTES) });
  response = await worker.fetch(post("/submit", big), env(db));
  assert.equal(response.status, 413);
  // The same body with a Content-Length that lies is still refused by size.
  response = await worker.fetch(new Request(BASE + "/submit", { method: "POST",
    headers: { "content-type": "application/json", "content-length": String(MAX_BODY_BYTES + 1) },
    body: JSON.stringify(VALID) }), env(db));
  assert.equal(response.status, 413);
  response = await worker.fetch(new Request(BASE + "/submit", { method: "POST",
    headers: { "content-type": "application/json" }, body: new Uint8Array([0xff, 0xfe, 0x7b]) }), env(db));
  assert.equal(response.status, 413);
  assert.equal((await rows(db)).length, 0);
});

test("malformed or unexpected fields are rejected with the field's name and no row", async () => {
  const db = openTestDatabase();
  const cases = [
    [{ ...VALID, public_ip: "10.0.0.1" }, "public_ip"],
    [{ ...VALID, public_ip: "192.168.1.5" }, "public_ip"],
    [{ ...VALID, public_ip: "127.0.0.1" }, "public_ip"],
    [{ ...VALID, public_ip: "203.0.113.5" }, "public_ip"],
    [{ ...VALID, public_ip: "1.2.3.256" }, "public_ip"],
    [{ ...VALID, public_ip: "01.2.3.4" }, "public_ip"],
    [{ ...VALID, public_ip: "1.2.3.4 " }, "public_ip"],
    [{ ...VALID, public_ip: 16909060 }, "public_ip"],
    [{ ...VALID, p2p_port: 0 }, "p2p_port"],
    [{ ...VALID, p2p_port: 65536 }, "p2p_port"],
    [{ ...VALID, p2p_port: "18189" }, "p2p_port"],
    [{ ...VALID, p2p_port: 18189.5 }, "p2p_port"],
    [{ ...VALID, network: "nextnet" }, "network"],
    [{ ...VALID, schema_version: 1 }, "schema_version"],
    [{ ...VALID, schema_version: 3 }, "schema_version"],
    [{ ...VALID, schema_version: "2" }, "schema_version"],
    [{ ...VALID, minotari_version: "v6.0.0" }, "minotari_version"],
    [{ ...VALID, minotari_version: "6.0" }, "minotari_version"],
    [{ ...VALID, minotari_version: "6.0.0; drop table submissions" }, "minotari_version"],
    [{ ...VALID, installer_version: "" }, "installer_version"],
    [{ ...VALID, installer_version: "0.1.0 beta" }, "installer_version"],
    [{ ...VALID, wallet_query_url: "http://wallet.example.com" }, "wallet_query_url"],
    [{ ...VALID, wallet_query_url: "https://wallet.example.com/path" }, "wallet_query_url"],
    [{ ...VALID, wallet_query_url: "https://1.2.3.4" }, "wallet_query_url"],
    [{ ...VALID, wallet_query_url: "https://Wallet.Example.com" }, "wallet_query_url"],
    [{ ...VALID, wallet_query_url: null }, "wallet_query_url"],
    [{ ...VALID, grpc_url: "grpc-test.nodes.taritalk.xyz" }, "grpc_url"],
    [{ ...VALID, grpc_url: "grpc-test.nodes.taritalk.xyz:443" }, "grpc_url"],
    [{ ...VALID, grpc_url: "https://grpc-test.nodes.taritalk.xyz:443" }, "grpc_url"],
    [{ ...VALID, grpc_url: "https://grpc-test.nodes.taritalk.xyz/x" }, "grpc_url"],
    [{ ...VALID, grpc_url: "http://grpc-test.nodes.taritalk.xyz" }, "grpc_url"],
    [{ ...VALID, grpc_url: "https://1.2.3.4" }, "grpc_url"],
    [{ ...VALID, grpc_url: null }, "grpc_url"],
    // Schema 1's domain:port form is no longer a field at all.
    [{ ...VALID, grpc_address: "grpc-test.nodes.taritalk.xyz:443" }, "grpc_address"],
    [{ ...VALID, operator_name: "" }, "operator_name"],
    [{ ...VALID, operator_name: " " }, "operator_name"],
    [{ ...VALID, operator_name: " Test" }, "operator_name"],
    [{ ...VALID, operator_name: "Test " }, "operator_name"],
    [{ ...VALID, operator_name: "---" }, "operator_name"],
    [{ ...VALID, operator_name: "😀" }, "operator_name"],
    [{ ...VALID, operator_name: "a\tb" }, "operator_name"],
    [{ ...VALID, operator_name: "a\nb" }, "operator_name"],
    [{ ...VALID, operator_name: "a\u0000b" }, "operator_name"],
    [{ ...VALID, operator_name: "a\u200eb" }, "operator_name"],
    [{ ...VALID, operator_name: "a\u202eb" }, "operator_name"],
    [{ ...VALID, operator_name: "a\u00a0b" }, "operator_name"],
    [{ ...VALID, operator_name: "a\u3000b" }, "operator_name"],
    [{ ...VALID, operator_name: "\ufeffTest" }, "operator_name"],
    [{ ...VALID, operator_name: "a\ue000b" }, "operator_name"],
    [{ ...VALID, operator_name: "x".repeat(MAX_OPERATOR_NAME_CHARS + 1) }, "operator_name"],
    [{ ...VALID, operator_name: "测".repeat(MAX_OPERATOR_NAME_CHARS + 1) }, "operator_name"],
    [{ ...VALID, operator_name: null }, "operator_name"],
    [{ ...VALID, operator_name: 5 }, "operator_name"],
    [{ ...VALID, operator_name: ["Test"] }, "operator_name"],
    [{ ...VALID, email: "someone@example.com" }, "email"],
    [{ ...VALID, operator: "me" }, "operator"],
    [{ ...VALID, name: "me" }, "name"],
  ];
  for (const [body, field] of cases) {
    const response = await worker.fetch(post("/submit", body), env(db));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(await response.json(), { ok: false, error: "invalid_field", field });
  }
  for (const key of Object.keys(VALID)) {
    const body = { ...VALID };
    delete body[key];
    const response = await worker.fetch(post("/submit", body), env(db));
    assert.equal(response.status, 400, `missing ${key}`);
    assert.deepEqual(await response.json(), { ok: false, error: "invalid_field", field: key });
  }
  assert.equal((await rows(db)).length, 0);
});

test("a storage failure gives a generic error without database details", async () => {
  const db = {
    prepare() {
      return { bind() { return this; }, async run() { throw new Error("D1_ERROR: no such table: submissions at 0x1"); } };
    },
  };
  const response = await worker.fetch(post("/submit", VALID), { DB: db, SUBMIT_RATE_LIMIT: createFakeRateLimiter() });
  assert.equal(response.status, 500);
  const text = await response.text();
  assert.equal(text, JSON.stringify({ ok: false, error: "storage_error" }));
});

test("the address rules match the installer's", () => {
  for (const ip of ["1.2.3.4", "8.8.8.8", "100.63.255.255", "100.128.0.0", "172.15.0.1", "172.32.0.1", "223.255.255.255"]) {
    assert.ok(isPublicIPv4(ip), ip);
  }
  for (const ip of ["0.0.0.0", "10.1.2.3", "100.64.0.1", "100.127.255.255", "169.254.1.1", "172.16.0.1", "172.31.255.255",
    "192.0.0.1", "192.0.2.1", "192.168.0.1", "198.18.0.1", "198.19.255.255", "198.51.100.1", "203.0.113.1",
    "224.0.0.1", "240.0.0.1", "255.255.255.255", "1.2.3", "1.2.3.4.5", "", "a.b.c.d"]) {
    assert.ok(!isPublicIPv4(ip), ip);
  }
  for (const d of ["wallet.example.com", "a.bc", "node-1.nodes.taritalk.xyz"]) assert.ok(isDomain(d), d);
  for (const d of ["example", "-a.com", "a-.com", "a.b", "A.com", "a..com", "1.2.3.4", "a.com.", ".a.com", "a".repeat(64) + ".com"]) {
    assert.ok(!isDomain(d), d);
  }
  for (const n of ["Test Node 测试", "Émile", "مرحبا", "@TariFans", "😀 x", "a\u0301", "x".repeat(64)]) assert.ok(isOperatorName(n), n);
  for (const n of ["", "---", "😀", " x", "x ", "a\u200eb", "a\u00a0b", "a\tb", "a\u2028b", "x".repeat(65), 5, null]) {
    assert.ok(!isOperatorName(n), JSON.stringify(n));
  }
});
