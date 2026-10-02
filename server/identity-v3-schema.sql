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
-- A ban revokes the member's transport accounts in the same transaction, so every v2
-- gate that checks ss_accounts.mode also blocks it. There is no unban. The ban procedure
-- must take `ss_meta FOR UPDATE` first (same order as commit). This guards application
-- SQL only; a database owner can still disable triggers or edit ss_accounts directly.
CREATE FUNCTION id_membership_state_guard() RETURNS trigger LANGUAGE plpgsql
 SET search_path = pg_catalog, public AS $$
BEGIN
 IF TG_OP = 'INSERT' AND NEW.state <> 'active' THEN
  RAISE EXCEPTION 'identity-v3 memberships start active';
 END IF;
 IF TG_OP = 'UPDATE' AND OLD.state = 'banned' THEN
  IF NEW.state <> 'banned' THEN
   RAISE EXCEPTION 'identity-v3 has no unban';
  END IF;
  IF NEW.account <> OLD.account THEN
   RAISE EXCEPTION 'banned membership cannot change account';
  END IF;
 END IF;
 IF NEW.state = 'banned' THEN
  UPDATE public.ss_accounts SET mode='revoked'
   WHERE account IN (OLD.account, NEW.account);
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER id_membership_state AFTER INSERT OR UPDATE OF state, account ON id_memberships
 FOR EACH ROW EXECUTE FUNCTION id_membership_state_guard();
-- A revoked transport account of an identity-v3 binding never becomes active again.
CREATE FUNCTION id_account_mode_guard() RETURNS trigger LANGUAGE plpgsql
 SET search_path = pg_catalog, public AS $$
BEGIN
 IF OLD.mode = 'revoked' AND NEW.mode <> 'revoked' THEN
  RAISE EXCEPTION 'revoked transport account cannot be reactivated';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER id_account_mode BEFORE UPDATE OF mode ON ss_accounts
 FOR EACH ROW EXECUTE FUNCTION id_account_mode_guard();
