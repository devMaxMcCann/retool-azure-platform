"""python -m pipeline <step>

  schema            create/upgrade jobs_ingest tables, refresh source_catalog
  <source>          run one loader inside an ingest_runs ledger row
  analytics         rebuild jobs_analytics from jobs_ingest (needs the
                    analytics_builder credentials, not ingest_loader's)

Each CronJob runs exactly one step, so a slow or blocked source never holds
up the others and each has its own memory limit and schedule.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from . import analytics, catalog
from .common import Blocked, connect, ledger, log
from .sources import bls, federal_bulk, geocode, socrata, warn

LOADERS = {
    "warn": warn.run,
    "geocode": geocode.run,
    "chicago_licenses": socrata.run_chicago,
    "idfpr_licenses": socrata.run_idfpr,
    "bls_series": bls.run_series,
    "bls_qcew": bls.run_qcew,
    "dol_lca": federal_bulk.run_lca,
    "dol_perm": federal_bulk.run_perm,
    "msha_violations": federal_bulk.run_msha,
    "sba_ppp": federal_bulk.run_ppp,
    "osha_sir": federal_bulk.run_osha,
}


def main(argv: list[str]) -> int:
    if len(argv) != 1 or argv[0] not in {*LOADERS, "schema", "analytics"}:
        print(__doc__, file=sys.stderr)
        print("steps:", ", ".join(["schema", *LOADERS, "analytics"]), file=sys.stderr)
        return 2
    step = argv[0]
    os.environ["INGEST_SOURCE"] = step

    if step == "schema":
        with connect() as conn:
            conn.execute((Path(__file__).parent.parent / "schema.sql").read_text())
            catalog.seed(conn)
        log("schema applied, catalog seeded")
        return 0
    if step == "analytics":
        analytics.build()
        return 0

    try:
        with ledger(step) as state, connect() as conn:
            state["rows"] = LOADERS[step](conn)
            conn.commit()
    except Blocked as e:
        # Not a crash: the publisher said no. Exit 0 so Kubernetes doesn't
        # retry it (backoffLimit would hammer them); the ledger says 'blocked'.
        log(f"BLOCKED: {e}")
        return 0
    log(f"ok: {state['rows']} rows")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
