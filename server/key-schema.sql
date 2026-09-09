-- Explicit OFFLINE transition only; never run from ordinary server startup.
-- BEFORE INSERT fires even for v0 INSERT ... ON CONFLICT DO NOTHING.
-- Ordinary UPDATE/SELECT retain the exact existing table and history.
CREATE FUNCTION refuse_v0_room_initialization() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'key schema requires key-capable startup'; END;
$$;
CREATE TRIGGER key_schema_startup_guard BEFORE INSERT ON room_state
FOR EACH ROW EXECUTE FUNCTION refuse_v0_room_initialization();
CREATE TABLE key_meta (
    id SMALLINT PRIMARY KEY CHECK(id=1),
    version SMALLINT NOT NULL CHECK(version=1),
    realm TEXT NOT NULL,
    pin TEXT NOT NULL
);
CREATE TABLE key_grants (
    slot SMALLINT PRIMARY KEY CHECK(slot IN (0,1)),
    grant_id TEXT NOT NULL UNIQUE,
    credential TEXT NOT NULL,
    fingerprint TEXT NOT NULL UNIQUE,
    account TEXT NOT NULL UNIQUE,
    device TEXT NOT NULL UNIQUE,
    auth TEXT NOT NULL UNIQUE,
    expires BIGINT NOT NULL,
    mode TEXT NOT NULL CHECK(mode IN ('approved','pending','active','revoked'))
);
