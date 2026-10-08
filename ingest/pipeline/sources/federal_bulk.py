"""Bulk federal disclosure files, aggregated to one row per employer:
DOL LCA (H-1B), DOL PERM, MSHA violations, SBA PPP (loans > $150k), and
OSHA severe injury reports (kept per report, narrative never read).

Ported from the homelab's ingest_dol_lca.py, ingest_dol_perm.py,
ingest_msha_violations.py, ingest_sba_ppp.py and sources/osha_severe_injury.py.
Files are streamed to the pod's scratch disk (/scratch, an emptyDir) and
parsed row by row; only the per-employer aggregate is held in memory.

The entity filter from data/tables.yaml runs BEFORE aggregation, so a natural
person's name is never stored, not even as a key.

DOL's performance page has refused custom User-Agents in the past (homelab
note: an Akamai quirk). This pipeline sends its identifying UA anyway; if DOL
refuses, the run is recorded as `blocked` and a human decides. It does not
retry with a different identity.
"""
from __future__ import annotations

import csv
import io
import os
import re
import zipfile

import openpyxl

from ..common import download, http_get, is_entity, log, normalize, to_date, to_num

SCRATCH = os.environ.get("SCRATCH_DIR", "/scratch")
_DOL_PAGE = "https://www.dol.gov/agencies/eta/foreign-labor/performance"
_LCA_RE = re.compile(r'href="(https?://[^"]*LCA_Disclosure_Data_(FY\d+_Q\d+)\.xlsx)"')
_PERM_RE = re.compile(r'href="(https?://[^"]*PERM_Disclosure_Data_(FY[0-9A-Za-z_]+)\.xlsx)"')
_MSHA_ZIP = "https://arlweb.msha.gov/OpenGovernmentData/DataSets/Violations.zip"
_PPP_CSV = "https://data.sba.gov/sites/default/files/distribution/SBA-OCA-2022-07-001/public_150k_plus_240930.csv"
# OSHA renames this file when it extends the range; the landing page is the index.
_OSHA_PAGE = "https://www.osha.gov/severe-injury-reports"
_OSHA_RE = re.compile(r'href="([^"]*/sites/default/files/[^"]*\.zip)"', re.IGNORECASE)
_PPP_PERSON_TYPES = {"Sole Proprietorship", "Self-Employed Individuals", "Independent Contractors",
                     "Single Member LLC"}


def _dol_file(pattern: re.Pattern) -> tuple[str, str]:
    with http_get(_DOL_PAGE) as r:
        html = r.read().decode("utf-8", errors="replace")
    m = pattern.search(html)
    if not m:
        raise RuntimeError(f"no {pattern.pattern[:40]}... link on {_DOL_PAGE}")
    return m.group(1).replace("//media", "/media"), m.group(2)


def _xlsx_rows(path: str):
    ws = openpyxl.load_workbook(path, read_only=True).worksheets[0]
    it = ws.iter_rows(values_only=True)
    header = next(it)
    return {name: i for i, name in enumerate(header)}, it


def _replace(conn, table: str, cols: list[str], rows) -> int:
    with conn.transaction():
        conn.execute(f"DELETE FROM {table}")
        n = 0
        with conn.cursor() as cur, cur.copy(f"COPY {table} ({', '.join(cols)}) FROM STDIN") as cp:
            for r in rows:
                cp.write_row(r)
                n += 1
    return n


def _dol(conn, *, pattern, table, name_col, fein_col, wage_from, wage_to, wage_unit, status_ok, extra) -> int:
    url, label = _dol_file(pattern)
    path = download(url, os.path.join(SCRATCH, f"{table}.xlsx"))
    idx, rows = _xlsx_rows(path)
    agg: dict[str, dict] = {}
    seen = kept = 0
    for row in rows:
        seen += 1
        if not status_ok(row, idx):
            continue
        name = row[idx[name_col]]
        if not is_entity(name):
            continue
        key = normalize(name)
        if not key:
            continue
        kept += 1
        e = agg.setdefault(key, {"name": name, "n": 0, "latest": None, "title": None, "lo": None, "hi": None,
                                 "city": None, "state": None})
        e["n"] += 1
        received = to_date(row[idx["RECEIVED_DATE"]])
        if received and (e["latest"] is None or received > e["latest"]):
            e["latest"], e["title"] = received, row[idx["JOB_TITLE"]]
            if extra:
                e["city"], e["state"] = row[idx[extra[0]]], row[idx[extra[1]]]
        if row[idx[wage_unit]] == "Year":
            lo = to_num(row[idx[wage_from]])
            hi = to_num(row[idx[wage_to]]) or lo
            if lo:
                e["lo"] = lo if e["lo"] is None else min(e["lo"], lo)
                e["hi"] = hi if e["hi"] is None else max(e["hi"], hi)
    os.remove(path)
    log(f"{label}: {seen} rows, {kept} kept after filters, {len(agg)} employers")
    if extra:
        cols = ["normalized_name", "employer_name", "certified_perm_count", "latest_job_title",
                "latest_received_date", "latest_worksite_city", "latest_worksite_state", "min_annual_wage",
                "max_annual_wage", "fiscal_year"]
        out = ((k, e["name"], e["n"], e["title"], e["latest"], e["city"], e["state"], e["lo"], e["hi"], label)
               for k, e in agg.items())
    else:
        cols = ["normalized_name", "employer_name", "certified_lca_count", "latest_job_title",
                "latest_received_date", "min_annual_wage", "max_annual_wage", "fy_quarter"]
        out = ((k, e["name"], e["n"], e["title"], e["latest"], e["lo"], e["hi"], label) for k, e in agg.items())
    return _replace(conn, table, cols, out)


def run_lca(conn) -> int:
    return _dol(conn, pattern=_LCA_RE, table="dol_lca_employers", name_col="EMPLOYER_NAME",
                fein_col="EMPLOYER_FEIN", wage_from="WAGE_RATE_OF_PAY_FROM", wage_to="WAGE_RATE_OF_PAY_TO",
                wage_unit="WAGE_UNIT_OF_PAY", extra=None,
                status_ok=lambda r, i: str(r[i["CASE_STATUS"]] or "").startswith("Certified")
                and r[i["VISA_CLASS"]] == "H-1B")


def run_perm(conn) -> int:
    return _dol(conn, pattern=_PERM_RE, table="dol_perm_employers", name_col="EMP_BUSINESS_NAME",
                fein_col="EMP_FEIN", wage_from="JOB_OPP_WAGE_FROM", wage_to="JOB_OPP_WAGE_TO",
                wage_unit="JOB_OPP_WAGE_PER", extra=("PRIMARY_WORKSITE_CITY", "PRIMARY_WORKSITE_STATE"),
                status_ok=lambda r, i: str(r[i["CASE_STATUS"]] or "").startswith("Certified"))


def run_msha(conn) -> int:
    """latest_controller_name is never read: controllers are often people."""
    path = download(_MSHA_ZIP, os.path.join(SCRATCH, "msha_violations.zip"))
    agg: dict[str, dict] = {}
    seen = 0
    with zipfile.ZipFile(path) as zf:
        member = next(n for n in zf.namelist() if n.lower().endswith(".txt"))
        reader = csv.DictReader(io.TextIOWrapper(zf.open(member), encoding="utf-8", errors="replace"),
                                delimiter="|", quotechar='"')
        for row in reader:
            seen += 1
            name = row.get("VIOLATOR_NAME")
            if not is_entity(name):
                continue
            key = normalize(name)
            if not key:
                continue
            v = agg.setdefault(key, {"name": name, "n": 0, "ss": 0, "pen": 0.0, "paid": 0.0, "mines": set(),
                                     "latest": None})
            v["n"] += 1
            v["ss"] += row.get("SIG_SUB") == "Y"
            v["pen"] += to_num(row.get("PROPOSED_PENALTY")) or 0.0
            v["paid"] += to_num(row.get("AMOUNT_PAID")) or 0.0
            if row.get("MINE_ID"):
                v["mines"].add(row["MINE_ID"])
            d = to_date(row.get("VIOLATION_ISSUE_DT"))
            if d and (v["latest"] is None or d > v["latest"]):
                v["latest"] = d
    os.remove(path)
    log(f"{seen} violations -> {len(agg)} entity violators")
    return _replace(conn, "msha_violations_employers",
                    ["normalized_name", "violator_name", "violation_count", "sig_sub_count",
                     "total_proposed_penalty", "total_amount_paid", "distinct_mine_count", "latest_violation_date"],
                    ((k, v["name"], v["n"], v["ss"], v["pen"], v["paid"], len(v["mines"]), v["latest"])
                     for k, v in agg.items()))


def run_ppp(conn) -> int:
    """Natural-person business types are dropped row by row, and a borrower
    whose LATEST loan is a person type is dropped entirely (tables.yaml)."""
    path = download(_PPP_CSV, os.path.join(SCRATCH, "ppp.csv"))
    agg: dict[str, dict] = {}
    seen = 0
    with open(path, encoding="utf-8", errors="replace", newline="") as f:
        for row in csv.DictReader(f):
            seen += 1
            name = row.get("BorrowerName")
            if row.get("BusinessType") in _PPP_PERSON_TYPES or not is_entity(name):
                continue
            key = normalize(name)
            if not key:
                continue
            b = agg.setdefault(key, {"name": name, "n": 0, "cur": 0.0, "forg": 0.0, "jobs": 0, "latest": None,
                                     "status": None, "naics": None, "type": None, "state": None})
            b["n"] += 1
            b["cur"] += to_num(row.get("CurrentApprovalAmount")) or 0.0
            b["forg"] += to_num(row.get("ForgivenessAmount")) or 0.0
            b["jobs"] += int(to_num(row.get("JobsReported")) or 0)
            d = to_date(row.get("DateApproved"))
            if d and (b["latest"] is None or d > b["latest"]):
                b.update(latest=d, status=row.get("LoanStatus"), naics=row.get("NAICSCode"),
                         type=row.get("BusinessType"), state=row.get("BorrowerState"))
    os.remove(path)
    log(f"{seen} loans -> {len(agg)} entity borrowers")
    return _replace(conn, "sba_ppp_employers",
                    ["normalized_name", "borrower_name", "loan_count", "total_current_approval", "total_forgiveness",
                     "total_jobs_reported", "latest_date_approved", "latest_loan_status", "latest_naics_code",
                     "latest_business_type", "borrower_state"],
                    ((k, b["name"], b["n"], b["cur"], b["forg"], b["jobs"], b["latest"], b["status"], b["naics"],
                      b["type"], b["state"]) for k, b in agg.items()))


def run_osha(conn) -> int:
    """Final Narrative is free text about an injured worker: never read."""
    with http_get(_OSHA_PAGE) as r:
        html = r.read().decode("utf-8", errors="replace")
    links = [u for u in _OSHA_RE.findall(html) if "severe" in u.lower() or re.search(r"20\d\d", u)]
    if not links:
        raise RuntimeError(f"no data .zip link on {_OSHA_PAGE}")
    url = links[0] if links[0].startswith("http") else "https://www.osha.gov" + links[0]
    path = download(url, os.path.join(SCRATCH, "osha_sir.zip"))

    def count(v):
        return int(to_num(v) or 0)

    def rows():
        with zipfile.ZipFile(path) as zf:
            member = next(n for n in zf.namelist() if n.lower().endswith(".csv"))
            seen_ids = set()
            for row in csv.DictReader(io.TextIOWrapper(zf.open(member), encoding="utf-8", errors="replace")):
                emp, rid = row.get("Employer"), row.get("ID")
                if not rid or rid in seen_ids or not is_entity(emp):
                    continue
                seen_ids.add(rid)
                yield (rid, emp, normalize(emp), to_date(row.get("EventDate")), row.get("City"), row.get("State"),
                       row.get("Primary NAICS"), count(row.get("Hospitalized")), count(row.get("Amputation")),
                       count(row.get("Loss of Eye")), row.get("NatureTitle"), row.get("EventTitle"))

    n = _replace(conn, "osha_severe_injury_reports",
                 ["report_id", "employer", "normalized_name", "event_date", "city", "state", "naics",
                  "hospitalized_count", "amputation_count", "loss_of_eye_count", "nature_title", "event_title"],
                 rows())
    os.remove(path)
    log(f"{url.rsplit('/', 1)[-1]}: {n} entity reports")
    return n
