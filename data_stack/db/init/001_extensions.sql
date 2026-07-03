-- data_stack/db/init/001_extensions.sql
--
-- Phase 1.5 packet-native PostgreSQL foundation.
--
-- Required now:
--   pgcrypto
--     Required for gen_random_uuid() and database-side digest/crypto helpers.
--
-- Installed but inert in Phase 1.5:
--   vector
--     Kept only as available foundation for a future explicitly scoped vector
--     retrieval implementation. Phase 1.5 does not create embedding tables,
--     vector indexes, vector retrieval behavior, hybrid search, reranking, or
--     any active vector query path.
--
-- Candidate extensions intentionally not enabled here:
--   pg_trgm
--   unaccent
--   btree_gin

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;

COMMENT ON EXTENSION pgcrypto IS
    'Required final Phase 1.5 foundation: UUID and crypto/hash helpers.';

COMMENT ON EXTENSION vector IS
    'Installed inert foundation for future vector work only; Phase 1.5 does not activate vector retrieval, embeddings, hybrid search, or vector tables.';