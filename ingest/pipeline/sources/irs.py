"""IRS Exempt Organizations Business Master File: the IRS's own registry of
every organisation granted tax-exempt status, EIN in the first column.
Ported from the homelab's sources/irs_eo_bmf.py, which uses it as an
independent EIN source for companies (companies.ein / ein_eo_bmf_check).

robots.txt (www.irs.gov, read 2026-10-08): /pub/irs-soi/ is not disallowed.

Four files (eo1..eo4.csv, ~1.96M rows, ~0.5 GB together). Each is streamed
straight off the socket and parsed line by line; the whole CSV is never read
into memory (the homelab OOM-killed its 1.5Gi container doing exactly that,
fixed 2026-10-05). Only rows whose NAME normalizes to a WARN filer's name are
kept, which is the publication row filter for company-keyed data
(tables.yaml `companies`: company_id IN demo_public_companies).

ICO ("in care of", usually a person) and STREET are never read.
"""
from __future__ import annotations

import csv
import io
import time

from ..common import http_get, log, normalize, replace_table, warn_names

_BASE = "https://www.irs.gov/pub/irs-soi/{}.csv"
FILES = ["eo1", "eo2", "eo3", "eo4"]
DELAY = 2.0  # between files


def run_eo_bmf(conn) -> int:
    wanted = set(warn_names(conn))
    kept: dict[str, tuple] = {}
    seen = 0
    for f in FILES:
        with http_get(_BASE.format(f), timeout=300) as r:
            reader = csv.reader(io.TextIOWrapper(r, encoding="utf-8", errors="replace", newline=""))
            header = next(reader)
            i = {c: header.index(c) for c in ("EIN", "NAME", "CITY", "STATE", "SUBSECTION", "NTEE_CD", "RULING",
                                              "REVENUE_AMT")}
            width = max(i.values())
            for row in reader:
                seen += 1
                if len(row) <= width:
                    continue
                key = normalize(row[i["NAME"]])
                ein = row[i["EIN"]].strip()
                if not key or key not in wanted or len(ein) != 9:
                    continue
                kept[ein] = (f"{ein[:2]}-{ein[2:]}", row[i["NAME"]], key, row[i["CITY"]] or None,
                             row[i["STATE"]] or None, row[i["SUBSECTION"]] or None, row[i["NTEE_CD"]] or None,
                             row[i["RULING"]] or None, int(row[i["REVENUE_AMT"]]) if row[i["REVENUE_AMT"]].isdigit()
                             else None, f)
        time.sleep(DELAY)
    n = replace_table(conn, "irs_eo_bmf_orgs",
                      ["ein", "name", "normalized_name", "city", "state", "subsection", "ntee_cd", "ruling",
                       "revenue_amt", "source_file"], kept.values())
    log(f"{seen} IRS EO BMF rows read, {n} match a WARN filer by exact normalized name")
    return n
