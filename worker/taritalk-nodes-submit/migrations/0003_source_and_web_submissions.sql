-- Submissions from the website as well as from the installer.
--
-- Two new private columns: source ('tool' or 'web') says which entry point
-- wrote the row, and request_id is the website's per-attempt key, unique, so a
-- retried web submission can never become a second row (NULL for the
-- installer, and NULLs never collide). The website does not know the installer
-- or Minotari version, so both version columns lose NOT NULL; the installer
-- keeps sending them.
--
-- SQLite cannot drop NOT NULL in place, so the table is rebuilt: every row is
-- copied, column for column, into the new table, which then takes the old
-- name. Nothing is dropped from any row. Existing rows are classified by their
-- review state, as confirmed for the live database at the time of writing:
-- the pending rows are the installer's own test submissions ('tool'), and
-- every other row is a historical registration ('web'). New rows carry their
-- real source from the Worker.
--
-- The live table has one column and one index beyond migrations 0001 and
-- 0002, both added by hand: node_id TEXT, the published node's identifier set
-- on review, and the unique partial index submissions_node_id_unique on it.
-- Both are kept: node_id is copied with every other column and the index is
-- recreated below, so this migration expects them to exist. Before applying,
-- confirm the live table has exactly the columns listed in the INSERT below
-- (PRAGMA table_info(submissions)) and that the index definition in
-- sqlite_master matches the one recreated here; a database that lacks them
-- (a new one) gets them first with
--   ALTER TABLE submissions ADD COLUMN node_id TEXT;
--   CREATE UNIQUE INDEX submissions_node_id_unique ON submissions (node_id) WHERE node_id IS NOT NULL;
CREATE TABLE submissions_v3 (
  submission_id TEXT PRIMARY KEY,
  submitted_at TEXT NOT NULL,
  source_ip TEXT,
  public_ip TEXT NOT NULL,
  p2p_port INTEGER NOT NULL,
  network TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  minotari_version TEXT,
  installer_version TEXT,
  wallet_query_url TEXT,
  grpc_address TEXT,
  review_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (review_status IN ('pending', 'approved', 'rejected')),
  reviewed_at TEXT,
  review_note TEXT,
  grpc_url TEXT,
  operator_name TEXT,
  node_id TEXT,
  source TEXT NOT NULL CHECK (source IN ('tool', 'web')),
  request_id TEXT
);
INSERT INTO submissions_v3 (submission_id, submitted_at, source_ip, public_ip, p2p_port,
  network, schema_version, minotari_version, installer_version, wallet_query_url,
  grpc_address, review_status, reviewed_at, review_note, grpc_url, operator_name, node_id, source)
  SELECT submission_id, submitted_at, source_ip, public_ip, p2p_port,
    network, schema_version, minotari_version, installer_version, wallet_query_url,
    grpc_address, review_status, reviewed_at, review_note, grpc_url, operator_name, node_id,
    CASE review_status WHEN 'pending' THEN 'tool' ELSE 'web' END
  FROM submissions;
DROP TABLE submissions;
ALTER TABLE submissions_v3 RENAME TO submissions;
CREATE INDEX IF NOT EXISTS submissions_review_status ON submissions (review_status, submitted_at);
CREATE UNIQUE INDEX IF NOT EXISTS submissions_node_id_unique ON submissions (node_id) WHERE node_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS submissions_request_id ON submissions (request_id);
