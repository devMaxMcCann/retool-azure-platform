"""Bureau of Labor Statistics: national JOLTS, Illinois/Cook unemployment
(LAUS), and Cook County QCEW. Context for the dashboard, not linked to
companies. Ported from the homelab's bls_jolts.py and bls_local_labor.py,
but keeps the full series BLS returns (about three years) instead of only
the newest point, so the dashboard can chart trends.
"""
from __future__ import annotations

import csv
import datetime
import io
import time
import urllib.error

from ..common import Blocked, get_json, http_get, log

_API = "https://api.bls.gov/publicAPI/v2/timeseries/data/"
SERIES = [
    ("JTS000000000000000JOL", "US job openings (thousands)"),
    ("JTS000000000000000HIL", "US hires (thousands)"),
    ("JTS000000000000000LDL", "US layoffs and discharges (thousands)"),
    ("LASST170000000000003", "Illinois unemployment rate (%)"),
    ("LAUCN170310000000003", "Cook County unemployment rate (%)"),
]
COOK_FIPS = "17031"


def run_series(conn) -> int:
    rows = []
    for series_id, label in SERIES:
        # One request per series: the unregistered v2 API doesn't reliably
        # batch (homelab finding). Unregistered limits are small; 5 calls/run.
        data = get_json(f"{_API}{series_id}")
        if data.get("status") != "REQUEST_SUCCEEDED":
            raise RuntimeError(f"BLS {series_id}: {data.get('status')} {data.get('message')}")
        for p in (data["Results"]["series"] or [{}])[0].get("data", []):
            try:
                value = float(p["value"])
            except (KeyError, ValueError):
                value = None  # BLS marks unavailable points with "-"
            rows.append((series_id, label, int(p["year"]), p["period"], p.get("periodName"), value))
        time.sleep(0.5)
    with conn.transaction():
        conn.execute("DELETE FROM bls_series")
        with conn.cursor() as cur, cur.copy(
                "COPY bls_series (series_id, label, year, period, period_name, value) FROM STDIN") as cp:
            for r in rows:
                cp.write_row(r)
    log(f"{len(rows)} data points across {len(SERIES)} series")
    return len(rows)


def run_qcew(conn, quarters: int = 8) -> int:
    """QCEW publishes with a lag of about two quarters, so walk back from the
    current quarter and keep every quarter that exists. Keeps the county
    total plus private-sector supersectors (own_code 5, agglvl 73)."""
    today = datetime.date.today()
    year, qtr = today.year, (today.month - 1) // 3 + 1
    rows = []
    for _ in range(quarters + 3):
        qtr -= 1
        if qtr == 0:
            qtr, year = 4, year - 1
        try:
            with http_get(f"https://data.bls.gov/cew/data/api/{year}/{qtr}/area/{COOK_FIPS}.csv", retries=1) as r:
                text = r.read().decode("utf-8", errors="replace")
        except Blocked:
            raise
        except (urllib.error.URLError, OSError):
            continue  # not published yet
        for row in csv.DictReader(io.StringIO(text)):
            if (row.get("agglvl_code") == "70" and row.get("own_code") == "0") or \
               (row.get("agglvl_code") == "73" and row.get("own_code") == "5"):
                rows.append((year, qtr, row["own_code"], row["industry_code"], int(row["qtrly_estabs"] or 0),
                             int(row["month3_emplvl"] or 0), float(row["total_qtrly_wages"] or 0),
                             float(row["avg_wkly_wage"] or 0)))
        if len({(y, q) for y, q, *_ in rows}) >= quarters:
            break
    with conn.transaction():
        conn.execute("DELETE FROM bls_qcew_cook")
        with conn.cursor() as cur, cur.copy(
                "COPY bls_qcew_cook (year, qtr, own_code, industry_code, qtrly_estabs, month3_emplvl, "
                "total_qtrly_wages, avg_wkly_wage) FROM STDIN") as cp:
            for r in rows:
                cp.write_row(r)
    log(f"{len(rows)} QCEW rows")
    return len(rows)
