"""Illinois WARN notices (DCEO via Illinois workNet): the company spine.

Ported from the homelab's sources/warn_act.py + enrich.ingest_warn_notices.
Differences:
  - every filer becomes a company by its synthetic id; there is no other
    company source in Azure, so no exact-name lookup against existing rows
  - rows are keyed (source_url, row_no), so re-reading a report replaces it
    instead of duplicating it (the homelab table had no unique key)
  - only the columns the publication review allows are kept: no contact
    name/phone (some months have them), no raw_record, no event_causes
"""
from __future__ import annotations

import io
import os
import time
import re

import openpyxl

from ..common import http_get, log, normalize, synthetic_company_id, to_date

SOURCE = "warn"
ARCHIVE_URL = "https://www.illinoisworknet.com/LayoffRecovery/Pages/ArchivedWARNReports.aspx"
_LINK_RE = re.compile(r'href="(/_layouts/(?:15/)?download\.aspx\?SourceUrl=[^"]*?\.xlsx)"', re.IGNORECASE)
# Pause between report downloads: the first run backfills every report since
# 2020 from a small state site, so it must not arrive as a burst.
DELAY = float(os.getenv("WARN_DELAY_SECONDS", "3"))
MONTHS_BACK = int(os.getenv("WARN_MONTHS_BACK", "120"))  # every .xlsx report (2020 on); older ones are PDF

# Column layout drifts between months (homelab warn_act.py), so columns are
# found by normalized header text, never by position.
_FIELD_ALIASES = {
    "company_name": ["COMPANY NAME"],
    "address": ["COMPANY ADDRESS"],
    "city_state_zip": ["CITY, STATE, ZIP", "CITY STATE ZIP"],
    "event_type": ["TYPE OF EVENT"],
    "notice_date": ["WARN RECEIVED DATE"],
    "first_layoff_date": ["FIRST LAYOFF DATE"],
    "workers_affected": ["WORKERS AFFECTED", "# WORKERS AFFECTED"],
    "layoff_type": ["TYPE OF LAYOFF"],
    "county": ["COUNTY"],
    "naics": ["COMPANY NAICS"],
}
_STATE_RE = re.compile(r",?\s*([A-Za-z]{2})\s+\d{5}(?:-\d{4})?\s*$")
_LEADING_INT = re.compile(r"\s*(-?\d+)")


def _count(value):
    """Leading integer only: some cells hold two figures run together."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(round(value))
    m = _LEADING_INT.match(str(value).replace(",", ""))
    return int(m.group(1)) if m else None


def _header(cell) -> str:
    return re.sub(r"\s+", " ", str(cell or "").upper().replace("#", "").replace(":", "")).strip()


def list_reports() -> list[str]:
    with http_get(ARCHIVE_URL) as r:
        html = r.read().decode("utf-8", errors="replace")
    urls: list[str] = []
    for href in _LINK_RE.findall(html):
        url = "https://www.illinoisworknet.com" + href if href.startswith("/") else href
        if url not in urls:
            urls.append(url)
    return urls[:MONTHS_BACK]


def parse_report(xlsx: bytes) -> list[dict]:
    ws = openpyxl.load_workbook(io.BytesIO(xlsx), data_only=True, read_only=True).worksheets[0]
    rows = ws.iter_rows(values_only=True)
    header = [_header(c) for c in next(rows, [])]
    cols = {}
    for field, aliases in _FIELD_ALIASES.items():
        for a in aliases:
            if a in header:
                cols[field] = header.index(a)
                break
    if "company_name" not in cols:
        raise ValueError("no COMPANY NAME column")

    def get(row, f):
        i = cols.get(f)
        return row[i] if i is not None and i < len(row) else None

    out = []
    for row in rows:
        name = get(row, "company_name")
        if not name:
            continue
        name = str(name).strip()
        if name.endswith(":"):
            break  # the appended "Supplemental notices" table: different columns
        out.append({
            "company_name": name,
            "address": get(row, "address"),
            "city_state_zip": get(row, "city_state_zip"),
            "notice_date": to_date(get(row, "notice_date")),
            "effective_date": to_date(get(row, "first_layoff_date")),
            "employees_affected": _count(get(row, "workers_affected")),
            "event_type": get(row, "event_type"),
            "layoff_type": get(row, "layoff_type"),
            "county": get(row, "county"),
            "naics": None if get(row, "naics") is None else str(get(row, "naics")),
        })
    return out


def _il_location(address, csz, state, county):
    """Prefer an Illinois street address; else the named IL county; else none
    (homelab enrich._resolve_il_location)."""
    if state == "IL":
        combined = ", ".join(str(p) for p in (address, csz) if p)
        return (combined, "street") if combined else (None, None)
    if county and str(county).strip().lower() not in ("multiple", "out of state", ""):
        return f"{str(county).strip()} County, IL", "county"
    return None, None


def run(conn) -> int:
    done = {r[0] for r in conn.execute("SELECT source_url FROM warn_reports")}
    written = 0
    for url in list_reports():
        if url in done:
            continue
        time.sleep(DELAY)
        with http_get(url) as r:
            events = parse_report(r.read())
        with conn.transaction():
            conn.execute("DELETE FROM warn_reports WHERE source_url = %s", (url,))
            conn.execute("INSERT INTO warn_reports (source_url, rows) VALUES (%s, %s)", (url, len(events)))
            for i, e in enumerate(events):
                csz = e["city_state_zip"]
                m = _STATE_RE.search(str(csz or ""))
                state = m.group(1).upper() if m else None
                loc, precision = _il_location(e["address"], csz, state, e["county"])
                conn.execute(
                    """INSERT INTO warn_events (source_url, row_no, company_name, normalized_name, company_id,
                           company_address, company_city_state_zip, reported_state, county, il_location,
                           il_location_precision, notice_date, effective_date, employees_affected,
                           event_type, layoff_type, naics)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                    (url, i, e["company_name"], normalize(e["company_name"]), synthetic_company_id(e["company_name"]),
                     e["address"], csz, state, e["county"], loc, precision, e["notice_date"], e["effective_date"],
                     e["employees_affected"], e["event_type"], e["layoff_type"], e["naics"]))
        written += len(events)
        log(f"{url.rsplit('/', 1)[-1]}: {len(events)} notices")
    return written
