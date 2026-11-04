-- Submission schema 2. The Base Node gRPC endpoint is recorded as its public
-- URL, https://<domain> (the service runs on TCP 443, which the URL
-- implies), in grpc_url; an optional operator display name goes into
-- operator_name (NULL: none, shown as "Community registered" on manual
-- publication; the Worker never writes a placeholder such as 'Anonymous').
-- Rows stored under schema 1 are kept as they are: grpc_address stays,
-- untouched, and the same endpoint is written to grpc_url once.
ALTER TABLE submissions ADD COLUMN grpc_url TEXT;
ALTER TABLE submissions ADD COLUMN operator_name TEXT;
UPDATE submissions
  SET grpc_url = 'https://' || CASE WHEN grpc_address LIKE '%:443'
    THEN substr(grpc_address, 1, length(grpc_address) - 4) ELSE grpc_address END
  WHERE grpc_address IS NOT NULL AND grpc_url IS NULL;
