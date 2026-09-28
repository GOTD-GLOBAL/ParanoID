-- RFC-0027 identity-login-v3 additions. Applied only by `identity_v3::initialize` to an
-- EMPTY database, after the unchanged self-service v2 base schema. Never a migration.
CREATE TABLE id_meta (
 id SMALLINT PRIMARY KEY CHECK(id=1), version SMALLINT NOT NULL CHECK(version=3),
 genesis TEXT NOT NULL, program TEXT NOT NULL,
 start_window BIGINT NOT NULL DEFAULT 0, starts BIGINT NOT NULL DEFAULT 0 CHECK(starts BETWEEN 0 AND 8),
 success_window BIGINT NOT NULL DEFAULT 0, successes BIGINT NOT NULL DEFAULT 0 CHECK(successes BETWEEN 0 AND 8)
);
CREATE TABLE id_memberships (
 membership TEXT PRIMARY KEY, identity TEXT NOT NULL UNIQUE, owner TEXT NOT NULL UNIQUE,
 name TEXT NOT NULL UNIQUE, state TEXT NOT NULL CHECK(state IN ('active','banned')),
 generation BIGINT NOT NULL CHECK(generation BETWEEN 1 AND 8),
 account TEXT NOT NULL UNIQUE REFERENCES ss_accounts(account),
 operation TEXT NOT NULL UNIQUE, intent TEXT NOT NULL, result TEXT NOT NULL, last_replace BIGINT
);
-- Lifetime transport bindings, including retired tombstones. Never deleted or reused.
CREATE TABLE id_bindings (
 account TEXT PRIMARY KEY REFERENCES ss_accounts(account),
 membership TEXT NOT NULL REFERENCES id_memberships(membership),
 generation BIGINT NOT NULL CHECK(generation BETWEEN 1 AND 8), operation TEXT NOT NULL UNIQUE,
 root TEXT NOT NULL UNIQUE, device TEXT NOT NULL UNIQUE, auth TEXT NOT NULL UNIQUE,
 fingerprint TEXT NOT NULL UNIQUE, olm TEXT NOT NULL UNIQUE, retired BOOLEAN NOT NULL,
 UNIQUE(membership, generation)
);
