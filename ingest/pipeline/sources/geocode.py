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
import time
import urllib.parse

from ..common import get_json, log

_URL = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress"
LIMIT = int(os.getenv("GEOCODE_LIMIT", "500"))
DELAY = 0.3


def run(conn) -> int:
    todo = [r[0] for r in conn.execute(
        """SELECT DISTINCT e.il_location FROM warn_events e
           LEFT JOIN warn_geocodes g ON g.address_key = e.il_location
           WHERE e.il_location_precision = 'street' AND g.address_key IS NULL
           LIMIT %s""", (LIMIT,))]
    matched = 0
    for addr in todo:
        q = urllib.parse.urlencode({"address": addr, "benchmark": "Public_AR_Current", "format": "json"})
        try:
            hits = get_json(f"{_URL}?{q}", timeout=30)["result"]["addressMatches"]
        except (KeyError, ValueError):
            hits = None
        if hits:
            c = hits[0]["coordinates"]
            row = (addr, "matched", c["y"], c["x"], hits[0].get("matchedAddress"))
            matched += 1
        else:
            row = (addr, "no_match" if hits == [] else "error", None, None, None)
        conn.execute(
            """INSERT INTO warn_geocodes (address_key, status, lat, lon, matched_address)
               VALUES (%s,%s,%s,%s,%s)
               ON CONFLICT (address_key) DO UPDATE SET status=excluded.status, lat=excluded.lat,
                   lon=excluded.lon, matched_address=excluded.matched_address, geocoded_at=now()""", row)
        conn.commit()
        time.sleep(DELAY)
    log(f"{len(todo)} addresses tried, {matched} matched")
    return len(todo)
