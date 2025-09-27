-- NTT v0.1 schema
CREATE EXTENSION IF NOT EXISTS blake3;

CREATE TABLE medium (
    medium_hash  text PRIMARY KEY,
    medium_human text,
    added_at     timestamptz DEFAULT now(),
    health       text,
    image_path   text,
    enum_done    timestamptz,
    copy_done    timestamptz
);

CREATE TABLE inode (
    medium_hash text REFERENCES medium(medium_hash) ON DELETE CASCADE,
    dev         bigint,
    ino         bigint,
    nlink       int,
    size        bigint,
    mtime       bigint,          -- epoch seconds
    hash        bytea,           -- blake3-256
    copied      boolean DEFAULT false,
    copied_to   text,
    errors      text[] DEFAULT '{}',
    PRIMARY KEY (medium_hash, dev, ino)
);

CREATE TABLE path (
    medium_hash text,
    dev         bigint,
    ino         bigint,
    path        text,
    broken      boolean DEFAULT false,
    PRIMARY KEY (medium_hash, dev, ino, path),
    FOREIGN KEY (medium_hash, dev, ino) REFERENCES inode(medium_hash, dev, ino) ON DELETE CASCADE
);
