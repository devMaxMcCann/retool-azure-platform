"""Rebuild jobs_analytics from jobs_ingest.

Re-imports the foreign tables first (so a column added to jobs_ingest shows
up without a manual step), then runs analytics.sql, all in one transaction.

This role can't write jobs_ingest's ledger, so a failed build is recorded by
the CronJob's own status (non-zero exit), and analytics.build_info.built_at
shows when the last good build finished.
"""
from __future__ import annotations

import time
from pathlib import Path

from .common import connect, log

SQL = Path(__file__).parent.parent / "analytics.sql"


def build() -> None:
    t0 = time.monotonic()
    with connect() as conn:
        with conn.transaction():
            # Refresh the foreign-table definitions from the live ingest schema.
            for (name,) in conn.execute(
                    "SELECT foreign_table_name FROM information_schema.foreign_tables "
                    "WHERE foreign_table_schema = 'ingest'").fetchall():
                conn.execute(f'DROP FOREIGN TABLE IF EXISTS ingest."{name}" CASCADE')
            conn.execute("IMPORT FOREIGN SCHEMA public FROM SERVER ingest_srv INTO ingest")
            conn.execute(SQL.read_text())
        counts = dict(conn.execute("SELECT name, n FROM analytics.counts").fetchall())
    log(f"analytics rebuilt in {time.monotonic() - t0:.1f}s: {counts}")
