CREATE TABLE daily_usage (
    utc_day TEXT NOT NULL,
    package_version TEXT NOT NULL,
    launches INTEGER NOT NULL DEFAULT 1,
    export_status INTEGER NOT NULL DEFAULT 0 CHECK (export_status IN (0, 1, 2)),
    PRIMARY KEY (utc_day, package_version)
) STRICT;
