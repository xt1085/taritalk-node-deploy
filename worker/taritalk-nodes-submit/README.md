# taritalk-nodes-submit

The service behind `./deploy.sh submit` (Feature 7 of the installer) and
behind the registration form on the website: two routes, `POST /submit` and
`POST /web-submit`, that check a node submission and insert it as a `pending`
row into the Worker's own D1 database `taritalk-nodes-submissions`. Both
routes write the same table, hand out the same kind of submission ID and
leave the row to the same manual review.

- Independent of the status Worker and its `NODES_STATUS` KV.
- No public GET, list, read or administration route: every other request is
  404 (405 for other methods on a route). Errors are generic JSON without
  database details.
- Bodies are limited to 4096 bytes; every field is validated strictly;
  unknown fields are refused.
- `operator_name` is a display name and nothing more: 1 to 64 characters of
  letters, marks, digits, punctuation, symbols and spaces in any script, with
  at least one letter or digit, no leading or trailing space and no control,
  format (zero-width, bidi), other space or private-use character. The
  installer and the website apply the same rule before sending. A submission
  without it is stored with `NULL`, never a placeholder such as `Anonymous`;
  on manual publication that means `Community registered`.
- Review happens by hand with authenticated Cloudflare tooling
  (`wrangler d1 execute`), never through the Worker.
- One abuse brake, shared by both routes: a valid submission attempt is
  accepted once per observed source IP per 60 seconds through the Workers
  Rate Limiting binding `SUBMIT_RATE_LIMIT` (`[[ratelimits]]` in
  `wrangler.toml`, Wrangler 4.36+). A limited attempt gets HTTP 429 with
  `Retry-After: 60` and no row. The limit is keyed by the observed source,
  never by the submitted `public_ip`; invalid requests are refused before it
  and do not count. Cloudflare's limiter is per location and eventually
  consistent, so this is a brake on repetition, not exact accounting. There
  is no daily limit and nothing else (bans, challenges) is added.

## `POST /submit` (installer)

Unchanged from before the website route existed. Schema 2 body:
`schema_version` 2, `network` `mainnet`, a public IPv4, the port, the
Minotari and installer versions, and optionally the Wallet Query and Base
Node gRPC URLs (both `https://domain`, no port or path) and `operator_name`.
Schema 1's `grpc_address` is refused. The row records Cloudflare's observed
source IP (`CF-Connecting-IP`) and `source = 'tool'`.

## `POST /web-submit` (website)

The website's form sends `request_id`, `turnstile_token`, `public_ip`,
`p2p_port` and optionally `wallet_query_url`, `grpc_url` and
`operator_name`. It does not send the network or any version: the row gets
`network = 'mainnet'`, `schema_version = 2`, `NULL` for both versions and
`source = 'web'`.

- CORS: only the website's own origins are answered,
  `https://nodes.taritalk.xyz`, `https://taritalk-nodes.pages.dev` and the
  Pages preview deployments `https://<label>.taritalk-nodes.pages.dev`. Any
  other `Origin`, or none, is 403, and the preflight (`OPTIONS`) is answered
  only for those origins.
- Turnstile: `turnstile_token` is checked with Cloudflare's `siteverify`
  using the secret `TURNSTILE_SECRET` (a Worker secret, never in this
  repository) before the rate limit is spent and before anything is stored.
  A rejected token is 403 `turnstile_failed`; when Cloudflare cannot be asked
  it is 502 `turnstile_unavailable`; a Worker without the secret answers 500
  `server_error`. The installer's route never asks Turnstile.
- The observed source IP is used for the Turnstile check and the rate limit
  only; a web row stores `NULL` as its `source_ip`.
- `request_id` is a random UUID the page makes for one attempt and keeps
  across its retries. It is stored with the row, unique. Once the token has
  passed, a request whose `request_id` is already stored is answered with
  the submission ID that row has, before the rate limit and without spending
  it: the page's immediate retry after a lost answer gets its ID back instead
  of a 429, and a lost answer never becomes a second row. Only a new
  `request_id` (a new attempt, edited details) goes through the rate limit
  and is inserted; two retries in flight at once are caught by the unique
  index and answered the same way.

## Migrations

- `0002` adds `grpc_url` and `operator_name`. Rows stored under schema 1 are
  kept as they are: `grpc_address` stays, and the same endpoint is written
  once to `grpc_url` (`domain:443` becomes `https://domain`).
- The live table has, beyond `0002`, a column and an index that were added
  by hand on review tooling and are not in any migration file: `node_id TEXT`
  (the published node's identifier, set on review) and the unique partial
  index `submissions_node_id_unique ON submissions (node_id) WHERE node_id IS
  NOT NULL`. `0003` expects both. A new database (local development, the
  tests) gets them the same way, right after `0002`:
  `ALTER TABLE submissions ADD COLUMN node_id TEXT;` and the `CREATE UNIQUE
  INDEX` above (`test/d1-sqlite.mjs` does this for the tests).
- `0003` adds `source` (`'tool'` or `'web'`, NOT NULL) and `request_id`
  (unique, NULL for the installer) and drops NOT NULL from the two version
  columns. SQLite cannot drop NOT NULL in place, so the table is rebuilt:
  every row is copied column for column into the new table, `node_id`
  included, which then takes the old name; the two live indexes are
  recreated as they were and the `request_id` index is added. Existing rows
  are classified by review state, as confirmed for the live database:
  `pending` rows are the installer's own test submissions (`'tool'`), every
  other row is a historical registration (`'web'`). The migration does not
  assume any row count. **Before applying it to the live database, confirm
  the table has exactly the columns the migration copies and the index it
  recreates**:

  ```bash
  wrangler d1 execute taritalk-nodes-submissions --remote --command "PRAGMA table_info(submissions)"
  wrangler d1 execute taritalk-nodes-submissions --remote --command "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'submissions'"
  ```

  A column added by hand that the migration does not list would not be
  copied, and an index defined differently would be recreated as written
  here; either must be put into the migration first.

## Tests

Node 22.13+ (for `node:sqlite`); no dependencies:

```bash
node --test
```

The tests run the real migrations, in order, in an in-memory SQLite
database behind a small D1-shaped shim (`test/d1-sqlite.mjs`) and a
deterministic stand-in for the rate-limit binding
(`test/fake-rate-limit.mjs`); `test/migrations.test.mjs` brings schema 1 and
live-shaped schema 2 databases (with `node_id` and its index) forward and
checks every old row survives, `node_id` and the index included;
`test/web-submit.test.mjs` answers Cloudflare's `siteverify` from a stand-in
passed into `handleRequest`. Nothing contacts Cloudflare.

## Deploying (operator, by hand)

```bash
wrangler d1 create taritalk-nodes-submissions    # put its ID into wrangler.toml
wrangler d1 migrations apply taritalk-nodes-submissions --remote   # pending migrations, 0003 included
wrangler secret put TURNSTILE_SECRET            # the Turnstile widget's secret key, typed at the prompt
wrangler deploy
```

The Turnstile widget (site key, public, embedded in the website) must allow
the hostnames `nodes.taritalk.xyz` and `taritalk-nodes.pages.dev`.
