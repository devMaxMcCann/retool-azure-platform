"""SEC EDGAR: registrant identity (CIK, EIN), restructuring/offering filings,
and XBRL annual financials for WARN filers that are SEC registrants.

Ported from the homelab's sources/sec_edgar.py, sec_filings.py and
sec_financials.py, with three changes forced by robots.txt and the
publication review:

  - Candidate CIKs come from EDGAR's bulk name index
    (www.sec.gov/Archives/edgar/cik-lookup-data.txt, ~40 MB, streamed), not
    the homelab's browse-edgar search: robots.txt disallows /cgi-bin.
  - Filings come from each registrant's submissions JSON (structured form
    type and 8-K item numbers), not EDGAR full-text search: efts.sec.gov
    answered our robots.txt request with 403, and the homelab's 10-K/10-Q
    "severance" keyword hits were company prose (tables.yaml drops `excerpt`)
    that mostly measured "is listed". What is kept is the sharper signal the
    homelab added later: 8-K Item 2.05 (costs of exit or disposal
    activities, due within four business days), plus Form D offering notices
    (tables.yaml sec_form_d_filings, metadata only).
  - company_related_entities is not ported: the homelab fills it by
    name containment ("wanted in got"), which this pipeline never does.

robots.txt, read 2026-10-08:
  www.sec.gov   /Archives/edgar/ allowed (only /Archives/bin|etc|usr and a few
                vprr paths disallowed); /cgi-bin disallowed (not used)
  data.sec.gov  no robots.txt (404); /submissions and /api/xbrl used
  efts.sec.gov  robots.txt itself returned 403; not used

SEC fair access: at most 10 requests/second with a contact in the
User-Agent. common.user_agent() supplies the contact; DELAY keeps this at
<= 2 requests/second.

Matching is exact normalized name, and an EDGAR entity typed 'individual'
(insiders have CIKs) is never stored.
"""
from __future__ import annotations

import datetime
import io
import time
import urllib.error

from ..common import get_json, http_get, log, normalize, replace_table, warn_names

DELAY = 0.5  # 2 req/s, a fifth of SEC's ceiling
_LOOKUP = "https://www.sec.gov/Archives/edgar/cik-lookup-data.txt"
_SUBMISSIONS = "https://data.sec.gov/submissions/CIK{}.json"
_FACTS = "https://data.sec.gov/api/xbrl/companyfacts/CIK{}.json"
MAX_CIKS_PER_NAME = 10
FILING_YEARS = 5
_KEEP_FORMS = {"D", "D/A"}
_8K = {"8-K", "8-K/A"}

# homelab sec_financials.py: first tag with real data wins; never spliced.
_METRICS = {
    "revenue": ["Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax", "SalesRevenueGoodsNet",
                "SalesRevenueNet"],
    "net_income": ["NetIncomeLoss"],
    "long_term_debt": ["LongTermDebtNoncurrent", "LongTermDebt"],
}
_FISCAL_YEARS = 4


def _candidates(wanted: set[str]) -> dict[str, set[str]]:
    """Stream the bulk name index ('NAME:CIK:' per line) and keep the CIKs
    whose name normalizes to a WARN filer's name."""
    out: dict[str, set[str]] = {}
    with http_get(_LOOKUP, timeout=300) as r:
        for line in io.TextIOWrapper(r, encoding="latin-1", newline=""):
            parts = line.rstrip("\r\n").rsplit(":", 2)
            if len(parts) != 3 or not parts[1].isdigit():
                continue
            key = normalize(parts[0])
            if key in wanted:
                out.setdefault(key, set()).add(parts[1].zfill(10))
    return out


def _filing_url(cik: str, accession: str, doc: str) -> str:
    return f"https://www.sec.gov/Archives/edgar/data/{int(cik)}/{accession.replace('-', '')}/{doc}"


def run_edgar(conn) -> int:
    wanted = set(warn_names(conn))
    cands = _candidates(wanted)
    log(f"{sum(len(v) for v in cands.values())} candidate CIKs for {len(cands)} WARN filers")
    cutoff = (datetime.date.today() - datetime.timedelta(days=365 * FILING_YEARS)).isoformat()
    companies, filings = {}, {}
    for key, ciks in cands.items():
        for cik in sorted(ciks)[:MAX_CIKS_PER_NAME]:
            time.sleep(DELAY)
            try:
                d = get_json(_SUBMISSIONS.format(cik), timeout=60)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    continue  # name index lists CIKs that have no submissions file
                raise
            # The index carries former names too; the CURRENT name must match.
            if normalize(d.get("name")) != key or d.get("entityType") == "individual":
                continue
            ein = d.get("ein") or ""
            ein = f"{ein[:2]}-{ein[2:]}" if len(ein) == 9 and ein.strip("0") else None
            companies[cik] = (cik, d.get("name"), key, ein, d.get("entityType"), d.get("sic") or None,
                              d.get("sicDescription") or None, d.get("stateOfIncorporation") or None,
                              ",".join(d.get("tickers") or []) or None, ",".join(d.get("exchanges") or []) or None)
            rec = (d.get("filings") or {}).get("recent") or {}
            for j, form in enumerate(rec.get("form") or []):
                date = rec["filingDate"][j]
                items = (rec.get("items") or [""] * (j + 1))[j] or ""
                is_205 = form in _8K and "2.05" in [x.strip() for x in items.split(",")]
                if date < cutoff or not (is_205 or form in _KEEP_FORMS):
                    continue
                acc = rec["accessionNumber"][j]
                filings[(cik, acc)] = (cik, acc, form, date, items or None, is_205,
                                       _filing_url(cik, acc, rec["primaryDocument"][j]))
    n = replace_table(conn, "sec_companies",
                      ["cik", "name", "normalized_name", "ein", "entity_type", "sic", "sic_description",
                       "state_of_incorporation", "tickers", "exchanges"], companies.values())
    m = replace_table(conn, "sec_filings",
                      ["cik", "accession_number", "filing_type", "filing_date", "items", "item_205", "source_url"],
                      filings.values())
    log(f"{n} SEC registrants matched exactly, {m} Item 2.05 / Form D filings")
    return n + m


def _annual_series(concept_data: dict, tags: list[str]) -> list[tuple]:
    """homelab sec_financials._annual_series: 10-K full-year USD values, one
    per period, keyed by the period's END year (not `fy`, which a 10-K
    repeats across its comparative columns), newest first."""
    for tag in tags:
        entries = ((concept_data.get(tag) or {}).get("units") or {}).get("USD") or []
        by_year: dict[int, dict] = {}
        for e in entries:
            if e.get("form") != "10-K" or e.get("fp") != "FY" or not e.get("end"):
                continue
            if e.get("start"):
                span = (datetime.date.fromisoformat(e["end"]) - datetime.date.fromisoformat(e["start"])).days
                if span < 300:
                    continue
            y = int(e["end"][:4])
            if y not in by_year or e.get("filed", "") > by_year[y].get("filed", ""):
                by_year[y] = e
        if by_year:
            return [(y, by_year[y]["val"], by_year[y].get("filed"), by_year[y].get("accn"), tag)
                    for y in sorted(by_year, reverse=True)[:_FISCAL_YEARS]]
    return []


def run_financials(conn) -> int:
    """Only for CIKs run_edgar already matched; most WARN filers are private
    and file no XBRL at all. Informational, as in the homelab: no score."""
    ciks = [r[0] for r in conn.execute("SELECT cik FROM sec_companies ORDER BY cik")]
    rows = []
    for cik in ciks:
        time.sleep(DELAY)
        try:
            # companyfacts for a large filer is a few MB of JSON: fine in the
            # pod's memory, and freed before the next CIK.
            facts = get_json(_FACTS.format(cik), timeout=120)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue  # registrant files no XBRL
            raise
        usgaap = (facts.get("facts") or {}).get("us-gaap") or {}
        for metric, tags in _METRICS.items():
            for fy, val, filed, accn, tag in _annual_series(usgaap, tags):
                rows.append((cik, metric, fy, val, filed, accn, tag))
        del facts, usgaap
    n = replace_table(conn, "sec_financials",
                      ["cik", "metric", "fiscal_year", "value", "filed", "accn", "xbrl_tag"], rows)
    log(f"{len(ciks)} registrants, {n} annual figures")
    return n
