-- Draft v2: apply offline, never from runtime startup.
CREATE TABLE ss_meta (
 id SMALLINT PRIMARY KEY CHECK(id=1), version SMALLINT NOT NULL CHECK(version=2),
 realm TEXT NOT NULL, pin TEXT NOT NULL,
 sequence BIGINT NOT NULL DEFAULT 0 CHECK(sequence>=0),
 registration_window BIGINT NOT NULL DEFAULT 0, registrations BIGINT NOT NULL DEFAULT 0 CHECK(registrations BETWEEN 0 AND 8)
);
CREATE TABLE ss_accounts (
 account TEXT PRIMARY KEY, root TEXT NOT NULL UNIQUE,
 mode TEXT NOT NULL CHECK(mode IN ('pending','active','revoked'))
);
CREATE TABLE ss_devices (
 account TEXT PRIMARY KEY REFERENCES ss_accounts(account),
 device TEXT NOT NULL UNIQUE, auth TEXT NOT NULL UNIQUE,
 fingerprint TEXT NOT NULL UNIQUE, credential TEXT NOT NULL
);
CREATE TABLE ss_conversations (
 first_account TEXT NOT NULL REFERENCES ss_accounts(account),
 second_account TEXT NOT NULL REFERENCES ss_accounts(account),
 CHECK(first_account<second_account), PRIMARY KEY(first_account,second_account)
);
CREATE TABLE ss_messages (
 sequence BIGINT PRIMARY KEY CHECK(sequence>0), sender TEXT NOT NULL REFERENCES ss_accounts(account),
 recipient TEXT NOT NULL REFERENCES ss_accounts(account), message_id TEXT NOT NULL,
 ciphertext BYTEA NOT NULL CHECK(octet_length(ciphertext) BETWEEN 1 AND 16384),
 first_account TEXT NOT NULL, second_account TEXT NOT NULL,
 FOREIGN KEY(first_account,second_account) REFERENCES ss_conversations(first_account,second_account),
 CHECK(sender<>recipient), UNIQUE(sender,message_id)
);
CREATE INDEX ss_inbox ON ss_messages(recipient,sequence);

