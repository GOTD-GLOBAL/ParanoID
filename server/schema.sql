CREATE TABLE IF NOT EXISTS room_state (
    id SMALLINT PRIMARY KEY CHECK (id = 1),
    sequence BIGINT NOT NULL CHECK (sequence >= 0),
    used_bytes BIGINT NOT NULL CHECK (used_bytes >= 0)
);
INSERT INTO room_state VALUES (1, 0, 0) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS envelopes (
    sequence BIGINT PRIMARY KEY,
    sender SMALLINT NOT NULL CHECK (sender IN (0,1)),
    recipient SMALLINT NOT NULL CHECK (recipient IN (0,1) AND recipient <> sender),
    message_id TEXT NOT NULL,
    ciphertext BYTEA NOT NULL CHECK (octet_length(ciphertext) BETWEEN 1 AND 16384),
    UNIQUE (sender, message_id)
);
CREATE INDEX IF NOT EXISTS inbox_sequence ON envelopes(recipient, sequence);
