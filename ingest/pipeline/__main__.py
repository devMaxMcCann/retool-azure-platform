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
from .sources import (bls, enforcement, federal_bulk, federal_lookups, federal_registries, geocode, irs, sec, socrata,
                      warn)

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
    # Company-keyed federal sources: only rows matching a WARN filer's
    # normalized name are written (tables.yaml row filter), so run after warn.
    "irs_eo_bmf": irs.run_eo_bmf,
    "sec_edgar": sec.run_edgar,
    "sec_financials": sec.run_financials,
    "usaspending": federal_lookups.run_usaspending,
    "fdic_bankfind": federal_registries.run_fdic,
    "cms_care_compare": federal_registries.run_cms,
    "fmcsa_safer": federal_lookups.run_fmcsa,
    "cfpb_complaints": federal_lookups.run_cfpb,
    "ftc_cases": enforcement.run_ftc,
    "fed_enforcement": enforcement.run_fed,
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
            # Every loader pod runs this as its init container, so several can
            # start at once; CREATE ... IF NOT EXISTS is not safe under that
            # (duplicate key on pg_type). Serialize it, as the homelab's
            # init_db does with pg_advisory_lock(918273645).
            conn.execute("SELECT pg_advisory_lock(918273645)")
            try:
                conn.execute((Path(__file__).parent.parent / "schema.sql").read_text())
                catalog.seed(conn)
            finally:
                conn.execute("SELECT pg_advisory_unlock(918273645)")
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
