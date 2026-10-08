"""Shared plumbing for every loader: HTTP, the database, the run ledger, and
the name rules that the publication filters and the analytics joins share.

Every loader is a function `run(conn) -> int` (rows written). The CLI wraps it
in a ledger row (ingest_runs) so the dashboard's pipeline tab can show what ran,
when, how much, and why it failed -- without anyone reading pod logs.
"""
from __future__ import annotations

import contextlib
import datetime
import hashlib
import json
import os
import re
import sys
import time
import traceback
import urllib.error
import urllib.request

import psycopg

# ---------------------------------------------------------------- HTTP

def user_agent() -> str:
    """One identifying User-Agent for every source.

    SEC's fair-access policy requires contact details in it, and it is the
    honest thing to send everywhere else. It comes from the environment so no
    personal address is baked into the image. Refusing to run without it is
    deliberate: an anonymous scraper is the thing this pipeline is not.
    """
    contact = os.environ.get("INGEST_CONTACT", "").strip()
    if not contact:
        raise SystemExit("INGEST_CONTACT is not set (an email or URL publishers can reach)")
    return f"retool-azure-platform-ingest/1.0 (+{contact})"


class Blocked(Exception):
    """The publisher refused us (401/403/429). Never retried, never worked
    around: the run records it and a human decides what to do."""


def http_get(url: str, *, timeout: int = 60, retries: int = 4, data: bytes | None = None,
             headers: dict | None = None):
    """GET (or POST when `data` is given) with backoff on transient errors.

    Returns the open response so large files can be streamed; callers use it
    as a context manager. 401/403/429 raise Blocked immediately.
    """
    h = {"User-Agent": user_agent()}
    h.update(headers or {})
    last = None
    for attempt in range(retries):
        try:
            return urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), timeout=timeout)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403, 429):
                raise Blocked(f"{e.code} from {url}") from e
            last = e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = e
        time.sleep(2 ** attempt)
    raise last


def get_json(url: str, **kw):
    with http_get(url, **kw) as r:
        return json.loads(r.read().decode("utf-8", errors="replace"))


def download(url: str, path: str, **kw) -> str:
    """Stream a large file to disk (the pod's emptyDir), never into memory."""
    with http_get(url, timeout=300, **kw) as r, open(path, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    return path


# ---------------------------------------------------------------- names

_SUFFIX_RE = re.compile(
    r"\b(inc|incorporated|corp|corporation|co|company|llc|ltd|limited|plc|llp|lp)\b\.?", re.IGNORECASE)


def normalize(name: str | None) -> str:
    """Exact-match key, identical to the homelab's sources/name_match.py.

    Two names are the same company only when they normalize identically --
    never containment, which produced real false positives there.
    """
    if not name:
        return ""
    return re.sub(r"[^a-z0-9]", "", _SUFFIX_RE.sub("", name).lower())


def synthetic_company_id(name: str) -> int:
    """Same formula as the homelab (enrich._synthetic_company_id): negative
    48-bit, deterministic, so re-ingesting a filer is an update not a dupe."""
    digest = hashlib.sha256(name.strip().lower().encode()).digest()
    return -int.from_bytes(digest[:6], "big")


# The publication review's entity filter (data/tables.yaml). Applied AT INGEST
# for sources whose rows can name natural persons, so those rows never enter
# Azure at all. Kept as a Python regex with the same word list.
_ENTITY_RE = re.compile(
    r"\b(inc|incorporated|llc|l\.l\.c|corp|corporation|company|co|ltd|limited|lp|llp|lllp|pllc|pc|p\.c|nfp|"
    r"foundation|association|assn|bank|n\.a|university|college|hospital|church|district|authority|partners|"
    r"partnership|holdings|group)\b", re.IGNORECASE)


def is_entity(name: str | None) -> bool:
    return bool(name) and bool(_ENTITY_RE.search(name))


def to_date(v) -> datetime.date | None:
    """Publishers mix datetime cells, ISO strings, US m/d/Y and Socrata
    timestamps. Anything unparseable becomes None, never a guess."""
    if v is None or v == "":
        return None
    if isinstance(v, datetime.datetime):
        return v.date()
    if isinstance(v, datetime.date):
        return v
    s = str(v).strip()
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y",
                "%d-%b-%y", "%d-%b-%Y"):
        try:
            return datetime.datetime.strptime(s, fmt).date()
        except ValueError:
            pass
    return None


def to_num(v) -> float | None:
    if v is None or v == "" or isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v).replace(",", "").replace("$", "").strip())
    except ValueError:
        return None


# ---------------------------------------------------------------- database

def connect() -> psycopg.Connection:
    """libpq reads PGHOST/PGUSER/PGPASSWORD/... from the Secret Infisical syncs."""
    return psycopg.connect(application_name=f"ingest:{os.environ.get('INGEST_SOURCE', '?')}")


def copy_rows(conn, table: str, columns: list[str], rows) -> int:
    """COPY an iterable of tuples into `table`. Streams; nothing is buffered
    beyond psycopg's own write buffer."""
    n = 0
    with conn.cursor() as cur, cur.copy(f"COPY {table} ({', '.join(columns)}) FROM STDIN") as cp:
        for row in rows:
            cp.write_row(row)
            n += 1
    return n


@contextlib.contextmanager
def ledger(source: str):
    """One ingest_runs row per attempt: started, finished, rows, status, error.

    Uses its own autocommit connection so a failed load's rollback can't
    erase the record that it failed.
    """
    with psycopg.connect(autocommit=True, application_name=f"ledger:{source}") as lc:
        run_id = lc.execute(
            "INSERT INTO ingest_runs (source, status) VALUES (%s, 'running') RETURNING id", (source,)
        ).fetchone()[0]
        state = {"rows": 0, "note": None}
        try:
            yield state
        except Blocked as e:
            lc.execute("UPDATE ingest_runs SET status='blocked', finished_at=clock_timestamp(), error=%s WHERE id=%s",
                       (str(e), run_id))
            raise
        except BaseException as e:
            lc.execute("UPDATE ingest_runs SET status='failed', finished_at=clock_timestamp(), error=%s WHERE id=%s",
                       ("".join(traceback.format_exception_only(type(e), e)).strip()[:2000], run_id))
            raise
        else:
            lc.execute("UPDATE ingest_runs SET status='ok', finished_at=clock_timestamp(), rows_written=%s, note=%s "
                       "WHERE id=%s", (state["rows"], state["note"], run_id))


def log(msg: str) -> None:
    print(f"[{os.environ.get('INGEST_SOURCE', 'ingest')}] {msg}", file=sys.stderr, flush=True)
