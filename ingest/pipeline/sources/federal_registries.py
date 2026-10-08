"""Federal registries small enough to pull whole and match locally: FDIC
BankFind institutions and CMS Care Compare hospitals.

Ported from the homelab's sources/fdic_bankfind.py and cms_care_compare.py,
which searched one company at a time. Both registries are a few thousand to
~28k rows, so this pulls the full list in a handful of pages (bulk instead
of one request per company) and keeps only exact normalized-name matches to
a WARN filer, the publication row filter for these tables (tables.yaml:
company_id IN demo_public_companies). Nothing else is written.

robots.txt, read 2026-10-08:
  api.fdic.gov  no robots.txt (404)
  data.cms.gov  /provider-data/api/ not disallowed; asks `crawl-delay: 10`,
                which CMS_DELAY honours
"""
from __future__ import annotations

import time
import urllib.parse

from ..common import get_json, log, normalize, replace_table, warn_names

_FDIC = "https://api.fdic.gov/banks/institutions"
FDIC_PAGE = 10000  # the API's maximum; ~28k institutions incl. inactive = 3 requests
FDIC_DELAY = 1.0
_CMS = "https://data.cms.gov/provider-data/api/1/datastore/query/xubh-q36u/0"
CMS_PAGE = 500
CMS_DELAY = 10.0  # robots.txt crawl-delay


def run_fdic(conn) -> int:
    wanted = set(warn_names(conn))
    rows, offset, total = {}, 0, None
    while total is None or offset < total:
        q = urllib.parse.urlencode({"fields": "NAME,CERT,ACTIVE,CITY,STALP", "limit": FDIC_PAGE,
                                    "offset": offset, "sort_by": "CERT", "sort_order": "ASC"})
        page = get_json(f"{_FDIC}?{q}", timeout=120)
        total = int((page.get("meta") or {}).get("total") or 0)
        data = page.get("data") or []
        if not data:
            break
        for entry in data:
            d = entry.get("data") or {}
            key = normalize(d.get("NAME"))
            if key in wanted and d.get("CERT") is not None:
                cert = int(d["CERT"])
                rows[cert] = (cert, d["NAME"], key, d.get("CITY"), d.get("STALP"), bool(d.get("ACTIVE")),
                              "https://banks.data.fdic.gov/bankfind-suite/bankfind?activeStatus=&bankName="
                              f"{urllib.parse.quote(d['NAME'])}&cert={cert}")
        offset += len(data)
        time.sleep(FDIC_DELAY)
    n = replace_table(conn, "fdic_institutions",
                      ["cert", "name", "normalized_name", "city", "state", "active", "source_url"], rows.values())
    log(f"{offset} FDIC institutions read, {n} match a WARN filer")
    return n


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None  # CMS uses 'Not Available'


def run_cms(conn) -> int:
    wanted = set(warn_names(conn))
    rows, offset = {}, 0
    while True:
        q = urllib.parse.urlencode({"limit": CMS_PAGE, "offset": offset, "count": "false", "schema": "false"})
        data = get_json(f"{_CMS}?{q}", timeout=120).get("results") or []
        for r in data:
            key = normalize(r.get("facility_name"))
            if key in wanted and r.get("facility_id"):
                fid = r["facility_id"]
                rows[fid] = (fid, r["facility_name"], key, r.get("citytown"), r.get("state"), r.get("hospital_type"),
                             r.get("hospital_ownership"), _int(r.get("hospital_overall_rating")),
                             _int(r.get("count_of_mort_measures_worse")), _int(r.get("count_of_safety_measures_worse")),
                             _int(r.get("count_of_readm_measures_worse")),
                             f"https://www.medicare.gov/care-compare/details/hospital/{fid}")
        offset += len(data)
        if len(data) < CMS_PAGE:
            break
        time.sleep(CMS_DELAY)
    n = replace_table(conn, "cms_hospitals",
                      ["facility_id", "facility_name", "normalized_name", "city", "state", "hospital_type",
                       "hospital_ownership", "overall_rating", "mort_measures_worse", "safety_measures_worse",
                       "readm_measures_worse", "source_url"], rows.values())
    log(f"{offset} CMS hospitals read, {n} match a WARN filer")
    return n
