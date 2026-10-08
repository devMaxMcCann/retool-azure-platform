"""Federal enforcement listings: FTC cases and proceedings, and Federal
Reserve Board enforcement-action press releases.

Ported from the homelab's sources/ftc_cases.py and fed_enforcement.py, with
the matching rule changed. The homelab matched a company name ANYWHERE in a
case title (word-boundary containment); this pipeline never uses
containment. Instead each title is split into its named parties and a party
must normalize EXACTLY to a WARN filer's normalized name.

Publication row filters (tables.yaml), applied to the title BEFORE anything
is matched or written, with the same patterns, case-insensitive:
  ftc_cases                title !~* '(,| and |&|;|et al)'   single-party only
  fed_enforcement_actions  title !~* '(former|employee|individual|prohibit|
                           officer|director|president|institution-affiliated)'

Not ported here:
  doj_antitrust_cases  justice.gov now answers the alpha index with an Akamai
                       bot-verification interstitial (proof-of-work JS) to a
                       non-browser client (sample 2026-10-08). That is bot
                       detection; it is not worked around.

robots.txt, read 2026-10-08:
  www.ftc.gov              /legal-library/browse/cases-proceedings allowed;
                           ?page= allowed (only ?combine= and ?items_per_page=
                           disallowed); Crawl-delay: 5, honoured by FTC_DELAY
  www.federalreserve.gov   no robots.txt (404)
"""
from __future__ import annotations

import email.utils
import html
import os
import re
import time
import xml.etree.ElementTree as ET

from ..common import get_cursor, http_get, log, normalize, set_cursor, warn_names

# ------------------------------------------------------------------- FTC
_FTC = "https://www.ftc.gov/legal-library/browse/cases-proceedings"
FTC_DELAY = 5.0  # robots.txt Crawl-delay
FTC_PAGES_PER_RUN = int(os.getenv("FTC_PAGES_PER_RUN", "150"))  # ~306 pages in all (2026-10-08)
_FTC_LINK = re.compile(r'<a href="/legal-library/browse/cases-proceedings/(?P<slug>[^"/?#]+)" hreflang="en">'
                       r'(?P<title>[^<]+)</a>')
_FTC_NOT_CASES = {"adjudicative-proceedings", "commissioner-statements", "banned-debt-collectors"}
_FTC_FILTER = re.compile(r"(,| and |&|;|et al)", re.IGNORECASE)
_PLAINTIFF = re.compile(r"^(?:ftc|federal trade commission|u\.?s\.?|united states(?: of america)?)\s+v\.?\s+",
                        re.IGNORECASE)


def run_ftc(conn) -> int:
    """Walks the newest-first listing a slice of pages per run, resuming
    from source_cursors, so a full pass spans a couple of runs and no run
    approaches the job's one-hour deadline."""
    wanted = set(warn_names(conn))
    page = int(get_cursor(conn, "ftc_cases") or 0)
    written = scanned = 0
    for _ in range(FTC_PAGES_PER_RUN):
        with http_get(f"{_FTC}?page={page}", timeout=60) as r:
            body = r.read().decode("utf-8", errors="replace")
        time.sleep(FTC_DELAY)
        cases = [(m.group("slug"), html.unescape(m.group("title")).strip()) for m in _FTC_LINK.finditer(body)
                 if m.group("slug") not in _FTC_NOT_CASES]
        if not cases:
            page = 0  # past the last page: the next run starts a fresh pass
            break
        for slug, title in cases:
            scanned += 1
            if _FTC_FILTER.search(title):
                continue
            party = _PLAINTIFF.sub("", title).strip()
            key = normalize(party)
            if key not in wanted:
                continue
            written += conn.execute(
                """INSERT INTO ftc_cases (url, title, party, normalized_name) VALUES (%s,%s,%s,%s)
                   ON CONFLICT (url) DO UPDATE SET title = excluded.title, party = excluded.party,
                       normalized_name = excluded.normalized_name""",
                (f"{_FTC}/{slug}", title, party, key)).rowcount
        page += 1
        set_cursor(conn, "ftc_cases", str(page))
        conn.commit()
    set_cursor(conn, "ftc_cases", str(page))
    log(f"{scanned} FTC case titles scanned, {written} single-party exact matches; next page {page}")
    return written


# ------------------------------------------------------------- Federal Reserve
_FED = "https://www.federalreserve.gov/feeds/press_enforcement.xml"
_FED_FILTER = re.compile(r"(former|employee|individual|prohibit|officer|director|president|institution-affiliated)",
                         re.IGNORECASE)
# A title can hold several clauses ("issues ... with X and announces
# termination of ... with Y, Z"), each with its own kind.
_CLAUSE = re.compile(r"\b(issues|announces|fines)\b", re.IGNORECASE)
_PARTIES = re.compile(r"\b(?:with|against)\s+(.+)$", re.IGNORECASE)
_SPLIT = re.compile(r",\s*(?:and\s+)?|\s+and\s+", re.IGNORECASE)
_TAIL = re.compile(r"\s+(?:to|for|over|regarding|related)\s+.*$", re.IGNORECASE)


def fed_parties(title: str) -> list[tuple[str, str]]:
    """[(party, 'action'|'termination')] named in a press-release title.
    Splitting on commas and 'and' can leave a bare 'Inc.' segment, which
    normalizes to '' and is ignored; it can't create a different company."""
    out = []
    bounds = [m.start() for m in _CLAUSE.finditer(title)] + [len(title)]
    for a, b in zip(bounds, bounds[1:]):
        clause = title[a:b]
        kind = "termination" if "terminat" in clause.lower() else "action"
        m = _PARTIES.search(clause)
        if not m:
            continue
        for part in _SPLIT.split(_TAIL.sub("", m.group(1))):
            part = part.strip(" .;")
            if part:
                out.append((part, kind))
    return out


def run_fed(conn) -> int:
    """The feed holds only the ~15 newest releases, so rows accumulate run
    over run (keyed by url + company). A filer added to WARN later is not
    matched against releases that already left the feed."""
    wanted = set(warn_names(conn))
    with http_get(_FED, timeout=60) as r:
        root = ET.fromstring(r.read())
    written = items = 0
    for item in root.findall("./channel/item"):
        items += 1
        title = (item.findtext("title") or "").strip()
        url = (item.findtext("link") or "").strip()
        if not title or not url or _FED_FILTER.search(title):
            continue
        try:
            published = email.utils.parsedate_to_datetime(item.findtext("pubDate") or "").date()
        except (TypeError, ValueError):
            published = None
        for party, kind in fed_parties(title):
            key = normalize(party)
            if key in wanted:
                written += conn.execute(
                    """INSERT INTO fed_enforcement_actions (url, normalized_name, party, action_kind, title,
                           published) VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT (url, normalized_name) DO NOTHING""",
                    (url, key, party, kind, title, published)).rowcount
    log(f"{items} Fed releases in feed, {written} new exact matches")
    return written
