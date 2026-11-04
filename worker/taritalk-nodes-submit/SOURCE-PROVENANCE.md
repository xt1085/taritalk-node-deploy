# Worker source provenance / 源码对应说明

This directory contains the verified source of the deployed `taritalk-nodes-submit` Worker, including both `POST /submit` and `POST /web-submit`.

## Verified production snapshot

- Worker version ID: `f36b3650-c50d-46ee-9bd2-b5f291c2204e` (version 5).
- Deployment ID: `f7867ad6-b599-475a-b4be-c9a4eb464989`.
- Version created: `2026-10-13T01:24:54.816445Z`.
- Deployment created: `2026-10-13T01:25:56.384297Z`.
- Last identity verification for this source audit: `2026-11-03T17:41:41.707607Z` (2026-11-04 01:41:41 CST); the version had 100% traffic.
- Downloaded deployed JavaScript: 14,726 bytes.
- Deployed JavaScript SHA-256: `7d3c21dda2a3ea13f122e6a333b82b2a5f61cf5f08086b684cd007f9dd1c05bd`.

The downloaded script content was associated with the active version by matching its response ETag to the version's script-resource ETag, checking that latest-uploaded and active versions agreed, and checking deployment identity before and after acquisition. The content endpoint alone is script-scoped, not version-specific.

The source `src/index.js` was reproduced with the already-installed esbuild 0.25.4 using the actual file entry point, ESM bundling, target `es2022`, browser platform, name preservation and a linked source-map comment. The generated JavaScript was byte-for-byte identical to the downloaded deployed module. This verification used in-memory output and did not upload or execute the Worker.

This is a new source archive, not the original Git history of the October deployment. Publishing this repository does not deploy a Worker, run migrations, transfer runtime bindings or export database rows. Documentation, tests and migrations are accompanying source files, not files fetched from the deployed JavaScript endpoint.

## Runtime privacy and configuration

- Tool submissions (`/submit`) store the validated `CF-Connecting-IP` value in `source_ip`, without hashing, when available.
- Browser submissions (`/web-submit`) store `source_ip = NULL`; the IP is still used transiently for rate limiting and Turnstile verification.
- The Turnstile token is not inserted into D1. `TURNSTILE_SECRET` is a runtime secret binding; no real secret value is included here. Test credentials and request records in the test suite are synthetic fixtures, not exported production rows.
- The CORS policy permits the production origin, the project's Pages origin and matching single-level Pages branch/deployment origins. Consult the source for the exact allowlist.
- Application behavior does not establish the Cloudflare platform's or Turnstile's independent logging/retention policies.

## Migration boundary

Migration `0003_source_and_web_submissions.sql` preserves the existing production table, including its manually added `node_id` column and unique index. The SQLite test helper explicitly recreates those additions after migration 0002. Do not assume that running the SQL files against an otherwise empty new D1 database has been certified as a complete fresh-deployment procedure. No production migrations were run during this publication.

## 中文摘要

本目录是经核对能生成现网脚本的源码归档，保留原实现，不借此次发布修改业务行为。节点部署工具的其余源码保持原样。

本次重建的是 GitHub 公开源码仓库，不包含旧 Git 历史、运行时密钥或生产 D1 行数据，也不会触发线上部署。Release 下载包需另行发布；仅上传源码不代表 `releases/latest/download/` 已有可下载资产。
