"""Socrata open-data portals: City of Chicago business licences and Illinois
IDFPR business licences. Ported from the homelab's
sources/chicago_business_licenses.py and sources/idfpr_licenses.py.

Both are full refreshes inside one transaction: the old rows stay visible
until the new set commits, and a failed run leaves them untouched.

Publication filters (data/tables.yaml) are applied here, so filtered rows
never reach Azure:
  chicago: drop Home Occupation / Peddler / Home Repair licences, and legal
           names that don't look like an entity
  idfpr:   business_name must look like an entity
"""
from __future__ import annotations

import time
import urllib.parse

from ..common import get_json, is_entity, log, normalize, to_date

PAGE = 5000
DELAY = 0.3
_CHICAGO = "https://data.cityofchicago.org/resource/uupf-x98q.json"
_IDFPR = "https://illinois-edp.data.socrata.com/resource/pzzh-kp68.json"
_CHICAGO_EXCLUDED = {"Home Occupation", "Peddler License", "Home Repair"}


def _pages(base: str, select: str, where: str, order: str):
    """Offset paging with a fully deterministic order (:id last), so pages
    can't skip or repeat rows at the boundaries."""
    offset = 0
    while True:
        q = urllib.parse.urlencode({"$select": select, "$where": where, "$order": order,
                                    "$offset": offset, "$limit": PAGE})
        rows = get_json(f"{base}?{q}")
        if not rows:
            return
        yield from rows
        offset += len(rows)
        if len(rows) < PAGE:
            return
        time.sleep(DELAY)


def _coord(v, lo, hi):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if lo <= f <= hi else None


def run_chicago(conn) -> int:
    select = ("account_number,site_number,legal_name,doing_business_as_name,address,city,state,zip_code,"
              "license_description,business_activity,license_status,license_start_date,expiration_date,"
              "date_issued,latitude,longitude")
    latest: dict[tuple, tuple] = {}
    seen = 0
    # Oldest-first within each (account, site): the last row kept is the newest.
    for r in _pages(_CHICAGO, select, "license_status='AAI'", "account_number,site_number,license_start_date,:id"):
        seen += 1
        key = (r.get("account_number"), r.get("site_number"))
        if not all(key):
            continue
        if r.get("license_description") in _CHICAGO_EXCLUDED or not is_entity(r.get("legal_name")):
            latest.pop(key, None)
            continue
        latest[key] = (
            key[0], key[1], r.get("legal_name"), r.get("doing_business_as_name"),
            normalize(r.get("legal_name")), normalize(r.get("doing_business_as_name")),
            r.get("address"), r.get("city"), r.get("state"), r.get("zip_code"),
            r.get("license_description"), r.get("business_activity"), r.get("license_status"),
            to_date(r.get("license_start_date")), to_date(r.get("expiration_date")), to_date(r.get("date_issued")),
            _coord(r.get("latitude"), 41.0, 43.0), _coord(r.get("longitude"), -89.0, -87.0),
        )
    cols = ["account_number", "site_number", "legal_name", "doing_business_as_name", "normalized_legal",
            "normalized_dba", "address", "city", "state", "zip", "license_description", "business_activity",
            "license_status", "license_start_date", "expiration_date", "date_issued", "city_lat", "city_lon"]
    with conn.transaction():
        conn.execute("DELETE FROM chicago_business_licenses")
        with conn.cursor() as cur, cur.copy(f"COPY chicago_business_licenses ({', '.join(cols)}) FROM STDIN") as cp:
            for row in latest.values():
                cp.write_row(row)
    log(f"{seen} source rows -> {len(latest)} licences after filters")
    return len(latest)


def run_idfpr(conn) -> int:
    select = ("license_number,license_type,description,business_name,businessdba,license_status,"
              "original_issue_date,effective_date,expiration_date,city,state,zip,county,ever_disciplined")
    latest: dict[str, tuple] = {}
    seen = 0
    for r in _pages(_IDFPR, select, "business='Y'", "license_number,lastmodifieddate,:id"):
        seen += 1
        num = r.get("license_number")
        if not num:
            continue
        if not is_entity(r.get("business_name")):
            latest.pop(num, None)
            continue
        latest[num] = (
            num, r.get("license_type"), r.get("description"), r.get("business_name"), r.get("businessdba"),
            normalize(r.get("business_name")), normalize(r.get("businessdba")), r.get("license_status"),
            to_date(r.get("original_issue_date")), to_date(r.get("effective_date")),
            to_date(r.get("expiration_date")), r.get("city"), r.get("state"), r.get("zip"), r.get("county"),
            r.get("ever_disciplined") == "Y",
        )
    cols = ["license_number", "license_type", "description", "business_name", "businessdba", "normalized_name",
            "normalized_dba", "license_status", "original_issue_date", "effective_date", "expiration_date",
            "city", "state", "zip", "county", "ever_disciplined"]
    with conn.transaction():
        conn.execute("DELETE FROM idfpr_licenses")
        with conn.cursor() as cur, cur.copy(f"COPY idfpr_licenses ({', '.join(cols)}) FROM STDIN") as cp:
            for row in latest.values():
                cp.write_row(row)
    log(f"{seen} source rows -> {len(latest)} business licences after filters")
    return len(latest)
