// POST /web-submit: the website's registration form. Same table, same ID,
// same pending state as the installer's /submit, with the differences the
// browser path needs: a Turnstile token checked with Cloudflare, CORS for the
// site's own origins, no versions, no stored source IP, and a per-attempt
// request_id that makes a retry return the first row instead of adding one.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { handleRequest, WEB_ORIGINS } from "../src/index.js";
import { openTestDatabase } from "./d1-sqlite.mjs";
import { createFakeRateLimiter } from "./fake-rate-limit.mjs";

const BASE = "https://taritalk-nodes-submit.taritalk-status.workers.dev";
const SITE = "https://nodes.taritalk.xyz";
const SECRET = "1x0000000000000000000000000000000AA";
const REQUEST_ID = "9b2f6e3c-1d4a-4c8e-9f0b-2a6d7e8c9f01";
const VALID = {
  request_id: REQUEST_ID,
  turnstile_token: "0.test-token",
  public_ip: "1.2.3.4",
  p2p_port: 18189,
};
const TOOL_VALID = {
  schema_version: 2,
  network: "mainnet",
  public_ip: "1.2.3.4",
  p2p_port: 18189,
  minotari_version: "6.0.0",
  installer_version: "0.1.0",
};

function request(path, { method = "POST", body, origin = SITE, ip = "203.0.113.9", headers = {} } = {}) {
  const h = { ...headers };
  if (body !== undefined) h["content-type"] = h["content-type"] ?? "application/json";
  if (origin !== null) h.origin = origin;
  if (ip !== null) h["cf-connecting-ip"] = ip;
  return new Request(BASE + path, {
    method,
    headers: h,
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
}

// fakeVerify: a stand-in for fetch() that answers Cloudflare's siteverify and
// records what it was asked. `answer` is the JSON body, or "down" / "garbage".
function fakeVerify(answer = { success: true }) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url: String(url), method: init?.method, body: init?.body });
    if (answer === "down") throw new TypeError("fetch failed");
    if (answer === "garbage") return new Response("<html>", { status: 502 });
    return new Response(JSON.stringify(answer), { status: 200, headers: { "content-type": "application/json" } });
  };
  return { fetch, calls };
}

function setup({ secret = SECRET, answer, limit = 1000 } = {}) {
  const db = openTestDatabase();
  const limiter = createFakeRateLimiter({ limit });
  const verify = fakeVerify(answer);
  const env = { DB: db, SUBMIT_RATE_LIMIT: limiter };
  if (secret !== null) env.TURNSTILE_SECRET = secret;
  const send = (req) => handleRequest(req, env, { fetch: verify.fetch });
  return { db, limiter, verify, env, send };
}

async function rows(db) {
  return (await db.prepare("SELECT * FROM submissions ORDER BY submitted_at").all()).results.map((r) => ({ ...r }));
}

test("a valid web submission is stored once as pending, with its source and no IP or versions", async () => {
  const { db, send, verify, limiter } = setup();
  const response = await send(request("/web-submit", { body: { ...VALID,
    wallet_query_url: "https://wallet.example.com", grpc_url: "https://grpc-test.nodes.taritalk.xyz",
    operator_name: "Test Node 测试" } }));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), SITE);
  assert.equal(response.headers.get("vary"), "origin");
  const answer = await response.json();
  assert.deepEqual(Object.keys(answer).sort(), ["ok", "status", "submission_id"]);
  assert.equal(answer.ok, true);
  assert.equal(answer.status, "pending");
  assert.match(answer.submission_id, /^[0-9a-f-]{36}$/);
  const stored = await rows(db);
  assert.equal(stored.length, 1);
  const row = stored[0];
  assert.equal(row.submission_id, answer.submission_id);
  assert.equal(row.source, "web");
  assert.equal(row.request_id, REQUEST_ID);
  assert.equal(row.source_ip, null);
  assert.equal(row.minotari_version, null);
  assert.equal(row.installer_version, null);
  assert.equal(row.network, "mainnet");
  assert.equal(row.schema_version, 2);
  assert.equal(row.public_ip, "1.2.3.4");
  assert.equal(row.p2p_port, 18189);
  assert.equal(row.wallet_query_url, "https://wallet.example.com");
  assert.equal(row.grpc_url, "https://grpc-test.nodes.taritalk.xyz");
  assert.equal(row.grpc_address, null);
  assert.equal(row.operator_name, "Test Node 测试");
  assert.equal(row.review_status, "pending");
  assert.equal(row.reviewed_at, null);
  assert.equal(row.review_note, null);
  // The token was checked with Cloudflare, with the secret, the token and the
  // observed IP (used for the check only), and nothing about it was stored.
  assert.equal(verify.calls.length, 1);
  assert.equal(verify.calls[0].url, "https://challenges.cloudflare.com/turnstile/v0/siteverify");
  assert.equal(verify.calls[0].method, "POST");
  const form = new URLSearchParams(verify.calls[0].body);
  assert.equal(form.get("secret"), SECRET);
  assert.equal(form.get("response"), "0.test-token");
  assert.equal(form.get("remoteip"), "203.0.113.9");
  assert.ok(!JSON.stringify(row).includes("test-token"));
  assert.deepEqual(limiter.calls, ["203.0.113.9"]);
});

test("optional fields are NULL when absent, and the name is never replaced by a placeholder", async () => {
  const { db, send } = setup();
  const response = await send(request("/web-submit", { body: VALID, ip: null }));
  assert.equal(response.status, 200);
  const [row] = await rows(db);
  assert.equal(row.wallet_query_url, null);
  assert.equal(row.grpc_url, null);
  assert.equal(row.operator_name, null);
  assert.equal(row.source_ip, null);
  assert.ok(!JSON.stringify(row).includes("Anonymous"));
});

test("the same request_id sent again returns the first submission ID and adds no row", async () => {
  const { db, send } = setup();
  const first = await (await send(request("/web-submit", { body: VALID }))).json();
  // A retry after a lost response: a fresh token, the same request_id.
  const second = await send(request("/web-submit", { body: { ...VALID, turnstile_token: "0.second-token" } }));
  assert.equal(second.status, 200);
  const again = await second.json();
  assert.deepEqual(again, { ok: true, submission_id: first.submission_id, status: "pending" });
  assert.equal((await rows(db)).length, 1);
  // A different request_id is a different submission.
  const other = await (await send(request("/web-submit", { body: { ...VALID,
    request_id: "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f" } }))).json();
  assert.notEqual(other.submission_id, first.submission_id);
  assert.equal((await rows(db)).length, 2);
});

test("with the real limit of one per minute, the retry of a stored attempt is answered, not limited", async () => {
  const { db, send, limiter, verify } = setup({ limit: 1 });
  // The first attempt is stored, but its answer never reaches the page.
  const first = await send(request("/web-submit", { body: VALID }));
  assert.equal(first.status, 200);
  const { submission_id } = await first.json();
  assert.equal(limiter.calls.length, 1);
  // The page retries at once: same request_id, a fresh Turnstile token.
  const retry = await send(request("/web-submit", { body: { ...VALID, turnstile_token: "0.second-token" } }));
  assert.equal(retry.status, 200);
  assert.deepEqual(await retry.json(), { ok: true, submission_id, status: "pending" });
  assert.equal((await rows(db)).length, 1);
  // The token was still checked; the rate limit was not asked.
  assert.equal(verify.calls.length, 2);
  assert.equal(limiter.calls.length, 1);
  // A new attempt from the same source inside the period is limited as before.
  const fresh = await send(request("/web-submit", { body: { ...VALID,
    request_id: "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f", turnstile_token: "0.third-token" } }));
  assert.equal(fresh.status, 429);
  assert.deepEqual(await fresh.json(), { ok: false, error: "rate_limited" });
  assert.equal((await rows(db)).length, 1);
  assert.equal(limiter.calls.length, 2);
});

test("a token Cloudflare rejects is 403, stores nothing and does not use up the rate limit", async () => {
  const { db, send, limiter } = setup({ answer: { success: false, "error-codes": ["invalid-input-response"] } });
  const response = await send(request("/web-submit", { body: VALID }));
  assert.equal(response.status, 403);
  assert.equal(response.headers.get("access-control-allow-origin"), SITE);
  assert.deepEqual(await response.json(), { ok: false, error: "turnstile_failed" });
  assert.equal((await rows(db)).length, 0);
  assert.deepEqual(limiter.calls, []);
});

test("when Cloudflare cannot be asked the answer is 502 and nothing is stored", async () => {
  for (const answer of ["down", "garbage"]) {
    const { db, send } = setup({ answer });
    const response = await send(request("/web-submit", { body: VALID }));
    assert.equal(response.status, 502, answer);
    assert.deepEqual(await response.json(), { ok: false, error: "turnstile_unavailable" });
    assert.equal((await rows(db)).length, 0);
  }
});

test("a Worker without its Turnstile secret refuses web submissions generically", async () => {
  const { db, send, verify } = setup({ secret: null });
  const response = await send(request("/web-submit", { body: VALID }));
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { ok: false, error: "server_error" });
  assert.equal(verify.calls.length, 0);
  assert.equal((await rows(db)).length, 0);
});

test("only the site's own origins may use the web route; the answer carries that origin back", async () => {
  const { send } = setup();
  for (const origin of [...WEB_ORIGINS, "https://preview48.taritalk-nodes.pages.dev", "https://557ca3a3.taritalk-nodes.pages.dev"]) {
    const response = await send(request("/web-submit", { body: { ...VALID, request_id: crypto.randomUUID() }, origin }));
    assert.equal(response.status, 200, origin);
    assert.equal(response.headers.get("access-control-allow-origin"), origin);
  }
  for (const origin of [null, "https://evil.example.com", "http://nodes.taritalk.xyz", "https://nodes.taritalk.xyz.evil.com",
    "https://taritalk-nodes.pages.dev.evil.com", "https://a.b.taritalk-nodes.pages.dev", "null"]) {
    const response = await send(request("/web-submit", { body: VALID, origin }));
    assert.equal(response.status, 403, String(origin));
    assert.equal(response.headers.get("access-control-allow-origin"), null, String(origin));
    assert.deepEqual(await response.json(), { ok: false, error: "origin_not_allowed" });
  }
});

test("the browser's preflight is answered for an allowed origin and refused for any other", async () => {
  const { send, db } = setup();
  let response = await send(request("/web-submit", { method: "OPTIONS", headers: {
    "access-control-request-method": "POST", "access-control-request-headers": "content-type" } }));
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("access-control-allow-origin"), SITE);
  assert.equal(response.headers.get("access-control-allow-methods"), "POST, OPTIONS");
  assert.equal(response.headers.get("access-control-allow-headers"), "content-type");
  assert.equal(response.headers.get("access-control-max-age"), "86400");
  assert.equal(await response.text(), "");
  response = await send(request("/web-submit", { method: "OPTIONS", origin: "https://evil.example.com" }));
  assert.equal(response.status, 403);
  assert.equal(response.headers.get("access-control-allow-origin"), null);
  assert.equal((await rows(db)).length, 0);
});

test("GET and other methods on the web route expose nothing", async () => {
  const { send, db } = setup();
  for (const method of ["GET", "HEAD", "PUT", "DELETE"]) {
    const response = await send(request("/web-submit", { method }));
    assert.equal(response.status, 405, method);
    assert.equal(response.headers.get("allow"), "POST, OPTIONS");
  }
  assert.equal((await rows(db)).length, 0);
});

test("malformed, missing and unexpected web fields are rejected by name, before Cloudflare is asked", async () => {
  const { send, db, verify } = setup();
  const cases = [
    [{ ...VALID, request_id: "not-a-uuid" }, "request_id"],
    [{ ...VALID, request_id: "9B2F6E3C-1D4A-4C8E-9F0B-2A6D7E8C9F01" }, "request_id"],
    [{ ...VALID, request_id: "9b2f6e3c-1d4a-1c8e-9f0b-2a6d7e8c9f01" }, "request_id"],
    [{ ...VALID, request_id: 5 }, "request_id"],
    [{ ...VALID, turnstile_token: "" }, "turnstile_token"],
    [{ ...VALID, turnstile_token: "x".repeat(2049) }, "turnstile_token"],
    [{ ...VALID, turnstile_token: null }, "turnstile_token"],
    [{ ...VALID, public_ip: "10.0.0.1" }, "public_ip"],
    [{ ...VALID, public_ip: "203.0.113.5" }, "public_ip"],
    [{ ...VALID, p2p_port: "18189" }, "p2p_port"],
    [{ ...VALID, p2p_port: 0 }, "p2p_port"],
    [{ ...VALID, wallet_query_url: "http://wallet.example.com" }, "wallet_query_url"],
    [{ ...VALID, wallet_query_url: "https://wallet.example.com/" }, "wallet_query_url"],
    [{ ...VALID, grpc_url: "https://grpc.example.com:443" }, "grpc_url"],
    [{ ...VALID, operator_name: " Test" }, "operator_name"],
    [{ ...VALID, operator_name: "x".repeat(65) }, "operator_name"],
    // The installer's fields are not the website's to send.
    [{ ...VALID, schema_version: 2 }, "schema_version"],
    [{ ...VALID, network: "mainnet" }, "network"],
    [{ ...VALID, minotari_version: "6.0.0" }, "minotari_version"],
    [{ ...VALID, installer_version: "0.1.0" }, "installer_version"],
    [{ ...VALID, source: "tool" }, "source"],
    [{ ...VALID, source_ip: "1.1.1.1" }, "source_ip"],
    [{ ...VALID, email: "a@b.co" }, "email"],
  ];
  for (const [body, field] of cases) {
    const response = await send(request("/web-submit", { body }));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(await response.json(), { ok: false, error: "invalid_field", field });
  }
  for (const key of Object.keys(VALID)) {
    const body = { ...VALID };
    delete body[key];
    const response = await send(request("/web-submit", { body }));
    assert.equal(response.status, 400, `missing ${key}`);
    assert.deepEqual(await response.json(), { ok: false, error: "invalid_field", field: key });
  }
  let response = await send(request("/web-submit", { body: "{nope" }));
  assert.equal(response.status, 400);
  response = await send(request("/web-submit", { body: JSON.stringify(VALID), headers: { "content-type": "text/plain" } }));
  assert.equal(response.status, 415);
  response = await send(request("/web-submit", { body: { ...VALID, turnstile_token: "x".repeat(2048), operator_name: "y".repeat(64),
    wallet_query_url: "https://" + "w".repeat(60) + ".example.com", grpc_url: "https://" + "g".repeat(60) + ".example.com" },
    headers: { "content-length": "5000" } }));
  assert.equal(response.status, 413);
  assert.equal(verify.calls.length, 0);
  assert.equal((await rows(db)).length, 0);
});

test("a second web submission from the same source IP inside the period is 429 without a row", async () => {
  const { send, db } = setup({ limit: 1 });
  assert.equal((await send(request("/web-submit", { body: VALID }))).status, 200);
  const response = await send(request("/web-submit", { body: { ...VALID, request_id: crypto.randomUUID() } }));
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("retry-after"), "60");
  assert.equal(response.headers.get("access-control-allow-origin"), SITE);
  assert.deepEqual(await response.json(), { ok: false, error: "rate_limited" });
  assert.equal((await rows(db)).length, 1);
});

test("a storage failure on the web route is a generic error with the CORS header", async () => {
  const db = {
    prepare() {
      const dead = async () => { throw new Error("D1_ERROR: no such table"); };
      return { bind() { return this; }, run: dead, first: dead };
    },
  };
  const verify = fakeVerify();
  const response = await handleRequest(request("/web-submit", { body: VALID }),
    { DB: db, SUBMIT_RATE_LIMIT: createFakeRateLimiter(), TURNSTILE_SECRET: SECRET }, { fetch: verify.fetch });
  assert.equal(response.status, 500);
  assert.equal(response.headers.get("access-control-allow-origin"), SITE);
  assert.equal(await response.text(), JSON.stringify({ ok: false, error: "storage_error" }));
});

test("the installer's route is untouched: no Turnstile, no CORS, source 'tool', no request_id", async () => {
  const { db, send, verify } = setup();
  const response = await send(request("/submit", { body: TOOL_VALID, origin: null }));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("access-control-allow-origin"), null);
  const answer = await response.json();
  assert.deepEqual(Object.keys(answer).sort(), ["ok", "status", "submission_id"]);
  const [row] = await rows(db);
  assert.equal(row.source, "tool");
  assert.equal(row.request_id, null);
  assert.equal(row.source_ip, "203.0.113.9");
  assert.equal(row.minotari_version, "6.0.0");
  assert.equal(row.installer_version, "0.1.0");
  assert.equal(verify.calls.length, 0);
  // The installer's body never reaches the web route and the web body never
  // reaches the installer's.
  let crossed = await send(request("/web-submit", { body: TOOL_VALID }));
  assert.equal(crossed.status, 400);
  crossed = await send(request("/submit", { body: VALID, origin: null }));
  assert.equal(crossed.status, 400);
  assert.equal((await rows(db)).length, 1);
  // Preflight is not a thing the installer's route offers.
  assert.equal((await send(request("/submit", { method: "OPTIONS" }))).status, 405);
});

test("the default export checks tokens through the global fetch", async () => {
  const db = openTestDatabase();
  const env = { DB: db, SUBMIT_RATE_LIMIT: createFakeRateLimiter({ limit: 1000 }), TURNSTILE_SECRET: SECRET };
  const original = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push(String(url));
    return new Response(JSON.stringify({ success: true }), { status: 200 });
  };
  try {
    const response = await worker.fetch(request("/web-submit", { body: VALID }), env);
    assert.equal(response.status, 200);
  } finally {
    globalThis.fetch = original;
  }
  assert.deepEqual(seen, ["https://challenges.cloudflare.com/turnstile/v0/siteverify"]);
  assert.equal((await rows(db)).length, 1);
});
