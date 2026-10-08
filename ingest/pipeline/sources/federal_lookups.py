"""Federal sources with no usable bulk file, queried once per WARN filer:
USAspending awards, FMCSA SAFER carrier registrations, CFPB complaint counts.

Ported from the homelab's sources/usaspending.py, fmcsa_safer.py and
cfpb_complaints.py. Each publisher's search is full-text, so every result
is re-checked: only a record whose OWN name field normalizes to the WARN
filer's normalized name is kept (never containment). That is also the
publication row filter (tables.yaml: company_id IN demo_public_companies).

common.run_lookups walks the WARN filers a few hundred per run (never-checked
first, then the stalest), records each check in lookup_checks, and commits
per company, so a run is short, resumable and paced.

robots.txt, read 2026-10-08:
  api.usaspending.gov       no robots.txt (404)
  safer.fmcsa.dot.gov       no robots.txt (404)
  www.consumerfinance.gov   /data-research/consumer-complaints/search/api/ not
                            disallowed (only ?success, form-id, ask-cfpb search,
                            paying-for-college2 and similar are)
"""
from __future__ import annotations

import datetime
import html
import json
import os
import re
import time
import urllib.parse

from ..common import get_json, http_get, normalize, run_lookups

LIMIT = int(os.getenv("LOOKUP_LIMIT", "300"))

# ------------------------------------------------------------- USAspending
_USAS = "https://api.usaspending.gov/api/v2/search/spending_by_award/"
USAS_DELAY = 0.5
# award_type_codes must come from one group per request (homelab: a 422 names
# the groups), so contracts and grants are two searches.
_GROUPS = {"contract": ["A", "B", "C", "D"], "grant": ["02", "03", "04", "05"]}
USAS_PAGE = 100  # newest 100 per group; lookup_checks.found shows how many were kept


def _usaspending(conn, key: str, name: str) -> int:
    rows = {}
    for category, codes in _GROUPS.items():
        body = json.dumps({
            "filters": {"recipient_search_text": [name], "award_type_codes": codes,
                        "time_period": [{"start_date": "2007-10-01",  # the API's earliest
                                         "end_date": datetime.date.today().isoformat()}]},
            "fields": ["Award ID", "Recipient Name", "Award Amount", "Awarding Agency", "Start Date",
                       "generated_internal_id"],
            "limit": USAS_PAGE, "page": 1, "sort": "Start Date", "order": "desc",
        }).encode()
        with http_get(_USAS, data=body, headers={"Content-Type": "application/json"}, timeout=60) as r:
            results = json.loads(r.read().decode("utf-8", errors="replace")).get("results") or []
        time.sleep(USAS_DELAY)
        for a in results:
            gid = a.get("generated_internal_id")
            if not gid or normalize(a.get("Recipient Name")) != key:
                continue
            rows[gid] = (gid, a.get("Award ID"), a["Recipient Name"], key, a.get("Award Amount"),
                         a.get("Awarding Agency"), a.get("Start Date"), category,
                         f"https://www.usaspending.gov/award/{urllib.parse.quote(gid)}")
    conn.execute("DELETE FROM usaspending_awards WHERE normalized_name = %s", (key,))
    for row in rows.values():
        conn.execute(
            """INSERT INTO usaspending_awards (generated_internal_id, award_id, recipient_name, normalized_name,
                   amount, awarding_agency, start_date, award_category, source_url)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)
               ON CONFLICT (generated_internal_id) DO UPDATE SET amount = excluded.amount,
                   normalized_name = excluded.normalized_name""", row)
    return len(rows)


def run_usaspending(conn) -> int:
    return run_lookups(conn, "usaspending", _usaspending, limit=LIMIT, recheck_days=30)


# ------------------------------------------------------------------ FMCSA
_SAFER = "https://safer.fmcsa.dot.gov/query.asp"
FMCSA_DELAY = 2.0
# keywordx.asp results are server-rendered links whose original_query_string
# is the carrier's own name (sample 2026-10-08: literal spaces, not %20).
_ROW_RE = re.compile(r'href="query\.asp\?searchtype=ANY&query_type=queryCarrierSnapshot&query_param=USDOT'
                     r'&original_query_param=NAME&query_string=(?P<usdot>\d+)&original_query_string=(?P<name>[^"]+)"')


def _fmcsa(conn, key: str, name: str) -> int:
    q = urllib.parse.urlencode({"searchtype": "ANY", "query_type": "queryCarrierSnapshot", "query_param": "NAME",
                                "query_string": name})
    with http_get(f"{_SAFER}?{q}", timeout=60) as r:
        final = r.geturl()
        body = r.read().decode("utf-8", errors="replace")
    time.sleep(FMCSA_DELAY)
    found: dict[str, str] = {}
    if "query_param=USDOT" in final:
        # One exact hit redirects straight to the snapshot (homelab finding).
        qs = urllib.parse.parse_qs(urllib.parse.urlsplit(final).query)
        usdot, carrier = (qs.get("query_string") or [None])[0], (qs.get("original_query_string") or [None])[0]
        if usdot and usdot.isdigit() and normalize(carrier) == key:
            found[usdot] = carrier
    else:
        for m in _ROW_RE.finditer(body):
            carrier = html.unescape(urllib.parse.unquote_plus(m.group("name"))).strip()
            if normalize(carrier) == key:
                found[m.group("usdot")] = carrier
    conn.execute("DELETE FROM fmcsa_carriers WHERE normalized_name = %s", (key,))
    # More than one USDOT under one exact name is ambiguous: the homelab
    # stores none, and so does this.
    if len(found) != 1:
        return 0
    usdot, carrier = next(iter(found.items()))
    conn.execute(
        """INSERT INTO fmcsa_carriers (usdot_number, carrier_name, normalized_name, source_url) VALUES (%s,%s,%s,%s)
           ON CONFLICT (usdot_number) DO UPDATE SET carrier_name = excluded.carrier_name,
               normalized_name = excluded.normalized_name""",
        (usdot, carrier, key, f"{_SAFER}?searchtype=ANY&query_type=queryCarrierSnapshot&query_param=USDOT"
                              f"&query_string={usdot}"))
    return 1


def run_fmcsa(conn) -> int:
    return run_lookups(conn, "fmcsa_safer", _fmcsa, limit=LIMIT, recheck_days=90)


# ------------------------------------------------------------------- CFPB
_CFPB = "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/"
CFPB_DELAY = 1.0
_SAMPLE = 5


def _cfpb(conn, key: str, name: str) -> int:
    """Step 1 (homelab): full-text search, accept only if the top hits'
    `company` field all normalize to the filer's name. Step 2 (new): count
    with the exact `company=` filter, which the API honours (sample
    2026-10-08: company=EQUIFAX, INC. -> 4.85M of ~17M), so the total isn't
    inflated by complaints that merely mention the name.

    Only `company` is read from a hit. Narratives, consumer ZIP/state and
    every other complaint field are never read or stored: the table holds
    one count per company (tables.yaml: "no narratives")."""
    q = urllib.parse.urlencode({"search_term": name, "size": _SAMPLE, "no_aggs": "true"})
    hits = (get_json(f"{_CFPB}?{q}", timeout=60).get("hits") or {}).get("hits") or []
    time.sleep(CFPB_DELAY)
    companies = {(h.get("_source") or {}).get("company") or "" for h in hits}
    conn.execute("DELETE FROM cfpb_complaint_counts WHERE normalized_name = %s", (key,))
    if not hits or len(companies) != 1 or normalize(next(iter(companies))) != key:
        return 0
    company = companies.pop()
    q = urllib.parse.urlencode({"company": company, "size": 0, "no_aggs": "true"})
    total = ((get_json(f"{_CFPB}?{q}", timeout=60).get("hits") or {}).get("total") or {}).get("value")
    time.sleep(CFPB_DELAY)
    if not total:
        return 0
    conn.execute(
        """INSERT INTO cfpb_complaint_counts (normalized_name, cfpb_company, total_complaints, as_of, source_url)
           VALUES (%s,%s,%s,current_date,%s)""",
        (key, company, int(total), "https://www.consumerfinance.gov/data-research/consumer-complaints/search/"
                                   f"?company={urllib.parse.quote(company)}"))
    return 1


def run_cfpb(conn) -> int:
    return run_lookups(conn, "cfpb_complaints", _cfpb, limit=LIMIT, recheck_days=30)
