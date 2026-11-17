-- Stats 1.1 keeps the latest aggregate snapshot in memory. This migration
-- reserves the module schema for persisted history in a later release.
-- It is intentionally not run by the scaffold's Docker Compose profile.

CREATE TABLE IF NOT EXISTS stats_schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO stats_schema_version (version)
VALUES (1)
ON CONFLICT (version) DO NOTHING;
