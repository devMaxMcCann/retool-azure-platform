"""Map points for WARN filers, from the US Census geocoder only.

The homelab chained Census -> Cook County parcel GIS -> Cook County Assessor.
Cook County is excluded from publication (terms restrictive/unverified), so
this keeps step one alone. Only street-precision Illinois addresses are sent;
a county-only location is never turned into a fake point.

Each address is geocoded once and cached in warn_geocodes, including misses,
so reruns only cost the new filings.
"""
from __future__ import annotations

import os
import re
import time
import urllib.error
import urllib.parse

from ..common import get_json, log

_URL = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress"
LIMIT = int(os.getenv("GEOCODE_LIMIT", "500"))
DELAY = 0.3
# The geocoder answers 400 "Address cannot be empty and cannot exceed 100
# characters" (confirmed 2026-10-08 with a 126-char address). WARN cells can
# also carry line breaks and runs of spaces from the spreadsheet.
MAX_LEN = 100


def clean_address(addr: str | None) -> str:
    """One line, single spaces, no control characters, trimmed commas."""
    s = re.sub(r"[\x00-\x1f\x7f]+", " ", str(addr or ""))
    s = re.sub(r"\s+", " ", s).strip(" ,")
    return re.sub(r"\s*,\s*", ", ", s)


def run(conn) -> int:
    todo = [r[0] for r in conn.execute(
        """SELECT DISTINCT e.il_location FROM warn_events e
           LEFT JOIN warn_geocodes g ON g.address_key = e.il_location
           WHERE e.il_location_precision = 'street' AND g.address_key IS NULL
           LIMIT %s""", (LIMIT,))]
    matched = invalid = 0
    for addr in todo:
        # The cache key stays the exact il_location (what analytics joins on);
        # only the text sent to Census is cleaned.
        sent = clean_address(addr)
        row = None
        if not sent or len(sent) > MAX_LEN:
            row = (addr, "invalid", None, None, None)
        else:
            q = urllib.parse.urlencode({"address": sent, "benchmark": "Public_AR_Current", "format": "json"})
            try:
                hits = get_json(f"{_URL}?{q}", timeout=30)["result"]["addressMatches"]
            except urllib.error.HTTPError as e:
                # 401/403/429 never get here (common.http_get raises Blocked).
                # Any other 4xx is our request being invalid for this address:
                # cache it as such so it is never sent again, and carry on.
                if 400 <= e.code < 500:
                    log(f"geocoder {e.code} for one address; cached as invalid")
                    row = (addr, "invalid", None, None, None)
                else:
                    raise
            except (KeyError, ValueError):
                hits = None
            if row is None and hits:
                c = hits[0]["coordinates"]
                row = (addr, "matched", c["y"], c["x"], hits[0].get("matchedAddress"))
                matched += 1
            elif row is None:
                row = (addr, "no_match" if hits == [] else "error", None, None, None)
            time.sleep(DELAY)
        invalid += row[1] == "invalid"
        conn.execute(
            """INSERT INTO warn_geocodes (address_key, status, lat, lon, matched_address)
               VALUES (%s,%s,%s,%s,%s)
               ON CONFLICT (address_key) DO UPDATE SET status=excluded.status, lat=excluded.lat,
                   lon=excluded.lon, matched_address=excluded.matched_address, geocoded_at=now()""", row)
        conn.commit()
    log(f"{len(todo)} addresses tried, {matched} matched, {invalid} invalid (empty, over {MAX_LEN} chars or 4xx)")
    return len(todo)
