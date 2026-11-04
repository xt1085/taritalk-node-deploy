-- Node submissions from the installer, one row each, private to TariTalk.
-- review_status is changed only by hand, with authenticated Cloudflare
-- tooling; the Worker inserts rows and never reads or updates them.
CREATE TABLE IF NOT EXISTS submissions (
  submission_id TEXT PRIMARY KEY,
  submitted_at TEXT NOT NULL,
  source_ip TEXT,
  public_ip TEXT NOT NULL,
  p2p_port INTEGER NOT NULL,
  network TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  minotari_version TEXT NOT NULL,
  installer_version TEXT NOT NULL,
  wallet_query_url TEXT,
  grpc_address TEXT,
  review_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (review_status IN ('pending', 'approved', 'rejected')),
  reviewed_at TEXT,
  review_note TEXT
);
CREATE INDEX IF NOT EXISTS submissions_review_status ON submissions (review_status, submitted_at);
