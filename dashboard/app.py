"""Read-only ingestion + analytics dashboard for the public-data platform.

Two data sources, both read-only by construction:
  * Postgres jobs_analytics as retool_reader (SELECT on the analytics schema
    only, read-only sessions) -- the published layer, nothing raw.
  * The Kubernetes API with a ServiceAccount whose Role allows get/list on
    Jobs, CronJobs and Pods in the `ingest` namespace -- the live view of which
    loaders are running right now. No secrets, no logs, no writes.

Generic on purpose: risk/confidence signals are rendered from the jsonb
breakdowns, so a new source in analytics.sql shows up without a code change.
"""
import html
import json
import os
import ssl
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

# ---------------------------------------------------------------- data access

_cache: dict = {}
_lock = threading.Lock()
TTL = int(os.environ.get("CACHE_SECONDS", "30"))


def cached(key, fn):
    with _lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < TTL:
            return hit[1]
    val = fn()
    with _lock:
        _cache[key] = (time.time(), val)
    return val


def q(sql, params=()):
    # libpq reads PGHOST/PGUSER/PGPASSWORD/... from the synced Secret.
    with psycopg.connect(connect_timeout=10, application_name="platform-dashboard") as c:
        cur = c.execute(sql, params)
        cols = [d.name for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]


K8S = "https://kubernetes.default.svc.cluster.local"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"


def k8s(path):
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    with open(f"{SA}/token") as f:
        tok = f.read().strip()
    req = urllib.request.Request(K8S + path, headers={"Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.load(r)


def live_jobs():
    try:
        cj = k8s("/apis/batch/v1/namespaces/ingest/cronjobs")["items"]
        jobs = k8s("/apis/batch/v1/namespaces/ingest/jobs")["items"]
        pods = k8s("/api/v1/namespaces/ingest/pods")["items"]
    except Exception as e:  # dashboard must still render without the k8s view
        return {"error": str(e), "cronjobs": [], "running": []}
    names = sorted((c["metadata"]["name"] for c in cj), key=len, reverse=True)

    def owner(job_name):
        # Scheduled: <cronjob>-<digits>; manual: <cronjob>-manual-<digits>.
        # Longest name first so "bls-series" never claims a "bls-series-x" sibling.
        for n in names:
            rest = job_name[len(n) + 1:] if job_name.startswith(n + "-") else None
            if rest and (rest.isdigit() or rest.startswith("manual-")):
                return n
        return None

    latest = {}
    for j in jobs:
        o = owner(j["metadata"]["name"])
        if o and (o not in latest or j["metadata"]["creationTimestamp"] > latest[o]["metadata"]["creationTimestamp"]):
            latest[o] = j
    rows = []
    for c in sorted(cj, key=lambda x: x["metadata"]["name"]):
        n = c["metadata"]["name"]
        j = latest.get(n)
        st = j.get("status", {}) if j else {}
        state = ("running" if st.get("active") else "succeeded" if st.get("succeeded")
                 else "failed" if st.get("failed") else "never run")
        rows.append({"step": n, "schedule": c["spec"]["schedule"],
                     "suspended": c["spec"].get("suspend", False), "last_job": state,
                     "last_start": (st.get("startTime") or ""), "last_done": (st.get("completionTime") or "")})
    running = [p["metadata"]["name"] for p in pods if p.get("status", {}).get("phase") == "Running"]
    return {"error": None, "cronjobs": rows, "running": running}


# ---------------------------------------------------------------- rendering

CSS = """
:root{--ink:#222;--muted:#666;--line:#e2e2e2;--blue:#0073e6;--card:#f6f7f9;--ok:#1a6b2a;--warn:#8a5a00;--bad:#a01818}
*{box-sizing:border-box}body{margin:0;font-family:Arial,sans-serif;color:var(--ink);background:#fff;line-height:1.5}
header{background:var(--blue);color:#fff;padding:14px 20px}header h1{margin:0;font-size:1.3rem}
header nav a{color:#fff;margin-right:16px;text-decoration:none;font-size:.92rem}header p{margin:2px 0 6px;font-size:.88rem;opacity:.9}
main{max-width:1150px;margin:0 auto;padding:16px}section{background:var(--card);border-radius:8px;padding:14px 16px;margin-bottom:16px}
h2{margin:0 0 8px;font-size:1.1rem}table{width:100%;border-collapse:collapse;background:#fff;font-size:.88rem}
th,td{padding:6px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{background:#eef0f3;font-weight:600}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}.scroll{overflow-x:auto}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.stat{background:#fff;border:1px solid var(--line);border-radius:6px;padding:8px 10px}.stat b{display:block;font-size:1.45rem;color:var(--blue)}
.stat span{font-size:.8rem;color:var(--muted)}.pill{display:inline-block;padding:0 8px;border-radius:10px;font-size:.78rem;border:1px solid}
.ok{color:var(--ok);border-color:var(--ok)}.warn{color:var(--warn);border-color:var(--warn)}.bad{color:var(--bad);border-color:var(--bad)}
.muted{color:var(--muted)}.g-Aplus,.g-A{color:#0c7a0c}.g-B{color:#4c8a22}.g-C{color:#a77300}.g-D{color:#c4572c}.g-F{color:#b02a2a}
.i{display:inline-block;width:15px;height:15px;border-radius:50%;border:1px solid var(--muted);color:var(--muted);font-size:10px;
 text-align:center;line-height:13px;font-style:italic;cursor:help;position:relative;margin-left:4px;font-weight:700}
.i:hover::after,.i:focus::after{content:attr(data-tip);position:absolute;left:18px;top:-4px;width:260px;background:#222;color:#fff;
 font-style:normal;font-weight:400;font-size:.78rem;line-height:1.35;padding:6px 8px;border-radius:5px;z-index:5;text-align:left}
form input{padding:5px 8px;border:1px solid #bbb;border-radius:4px;min-width:240px}form button{padding:5px 10px}
a{color:var(--blue)}footer{text-align:center;color:var(--muted);font-size:.8rem;padding:10px}
"""

e = html.escape


def tip(text):
    return f'<span class="i" tabindex="0" data-tip="{e(text)}">i</span>'


def num(v, d=0):
    if v is None:
        return '<span class="muted">-</span>'
    return f"{float(v):,.{d}f}"


def page(title, body, refresh=None):
    meta = f'<meta http-equiv="refresh" content="{refresh}">' if refresh else ""
    built = cached("built", lambda: q("SELECT max(built_at) AS b FROM analytics.build_info"))
    b = built[0]["b"].strftime("%Y-%m-%d %H:%M UTC") if built and built[0]["b"] else "never"
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
{meta}<title>{e(title)} | Public-data platform</title><style>{CSS}</style></head><body>
<header><h1>Public-data platform</h1><p>Azure AKS ingestion pods &rarr; Postgres &rarr; published analytics. Read-only view.</p>
<nav><a href="/">Ingestion</a><a href="/companies">Company risk</a><a href="/sources">Sources</a></nav></header>
<main>{body}</main><footer>Analytics last built {e(b)} &middot; reads only the published layer as a read-only role</footer></body></html>"""


def grade_cls(g):
    return "g-" + (g or "").replace("+", "plus")


def view_ingestion():
    live = cached("live", live_jobs)
    fresh = cached("fresh", lambda: q(
        "SELECT source, publisher, licence_status, last_success, rows_written, last_status, last_attempt, last_error "
        "FROM analytics.source_freshness ORDER BY source"))
    counts = {r["name"]: r["n"] for r in cached("counts", lambda: q("SELECT name, n FROM analytics.counts"))}
    stats = "".join(f'<div class="stat"><b>{v}</b><span>{l}</span></div>' for v, l in [
        (len(live["running"]), "ingestion pods running now"),
        (len(live["cronjobs"]), "scheduled loaders"),
        (num(counts.get("companies")), "companies"),
        (num(counts.get("records_total")), "published records")])
    if live["error"]:
        cj = f'<p class="muted">Kubernetes view unavailable: {e(live["error"])}</p>'
    else:
        rows = "".join(
            f'<tr><td>{e(r["step"])}</td><td><code>{e(r["schedule"])}</code></td>'
            f'<td>{"<span class=\"pill warn\">suspended</span>" if r["suspended"] else ""}'
            f'<span class="pill {"ok" if r["last_job"]=="succeeded" else "bad" if r["last_job"]=="failed" else "warn"}">{e(r["last_job"])}</span></td>'
            f'<td>{e(r["last_start"].replace("T"," ").replace("Z",""))}</td><td>{e(r["last_done"].replace("T"," ").replace("Z",""))}</td></tr>'
            for r in live["cronjobs"])
        cj = (f'<div class="scroll"><table><tr><th>Loader (CronJob)</th><th>Schedule (UTC)</th><th>Last job</th>'
              f'<th>Started</th><th>Finished</th></tr>{rows}</table></div>')
    def st(r):
        s = r["last_status"] or "never run"
        cls = "ok" if s == "ok" else "bad" if s in ("failed", "blocked") else "warn"
        return f'<span class="pill {cls}">{e(s)}</span>'
    frows = "".join(
        f'<tr><td>{e(r["publisher"] or r["source"])}</td><td>{st(r)}</td><td class="n">{num(r["rows_written"])}</td>'
        f'<td>{e(r["last_success"].strftime("%Y-%m-%d %H:%M") if r["last_success"] else "-")}</td>'
        f'<td class="muted">{e((r["last_error"] or "")[:120])}</td></tr>' for r in fresh)
    body = f"""<section><h2>Right now</h2><div class="stats">{stats}</div></section>
<section><h2>Loaders in the cluster {tip("Live from the Kubernetes API: one CronJob per public source, each run as a short-lived pod in the restricted ingest namespace. A 401/403/429 from a publisher marks the run blocked and is never retried.")}</h2>{cj}</section>
<section><h2>What each source has delivered {tip("From the run log, as of the last analytics build. Rows are what passed the publication filters; filtered rows are never stored.")}</h2>
<div class="scroll"><table><tr><th>Source</th><th>Last status</th><th class="n">Rows</th><th>Last success (UTC)</th><th>Note</th></tr>{frows}</table></div></section>"""
    return page("Ingestion", body, refresh=60)


def view_companies(query):
    term = (query.get("q") or [""])[0].strip()
    sql = ("SELECT company_id, company_name, counties, risk_score, confidence_score, goodness_percent, goodness_grade, "
           "n_warn_events, employees_affected_total, latest_notice_date FROM analytics.company_rollup "
           + ("WHERE company_name ILIKE %s " if term else "")
           + "ORDER BY risk_score DESC NULLS LAST, employees_affected_total DESC NULLS LAST LIMIT 200")
    rows = q(sql, (f"%{term}%",) if term else ())
    tr = "".join(
        f'<tr><td><a href="/company/{r["company_id"]}">{e(r["company_name"] or "")}</a></td>'
        f'<td class="n">{num(r["risk_score"], 2)}</td><td class="n">{num(r["confidence_score"])}</td>'
        f'<td class="{grade_cls(r["goodness_grade"])}"><b>{e(r["goodness_grade"] or "-")}</b> <span class="muted">{num(r["goodness_percent"])}%</span></td>'
        f'<td class="n">{num(r["n_warn_events"])}</td><td class="n">{num(r["employees_affected_total"])}</td>'
        f'<td>{e(str(r["latest_notice_date"] or ""))}</td><td class="muted">{e((r["counties"] or "")[:40])}</td></tr>' for r in rows)
    weights = cached("weights", lambda: q("SELECT axis, label, explanation FROM analytics.score_weights ORDER BY axis, label"))
    wtxt = " | ".join(f'{w["axis"]}: {w["label"]} ({w["explanation"]})' for w in weights)
    body = f"""<section><h2>Company risk {tip("Risk = mean of the conduct signals present for a company (0-1). Confidence = share of evidence pillars held (0-100). Grade blends both, the homelab model. Weights: " + wtxt)}</h2>
<form method="get"><input name="q" value="{e(term)}" placeholder="Search company name"> <button>Search</button></form><br>
<div class="scroll"><table><tr><th>Company</th><th class="n">Risk</th><th class="n">Confidence</th><th>Grade</th><th class="n">WARN notices</th>
<th class="n">Employees affected</th><th>Latest notice</th><th>Counties</th></tr>{tr}</table></div>
<p class="muted">Top 200 by risk. Companies come only from public WARN filings; other sources join by exact normalized name.</p></section>"""
    return page("Company risk", body)


def view_company(cid):
    r = q("SELECT * FROM analytics.company_rollup WHERE company_id = %s", (cid,))
    if not r:
        return None
    r = r[0]
    s = q("SELECT risk_breakdown, confidence_breakdown FROM analytics.company_scores WHERE company_id = %s", (cid,))
    rb, cb = (s[0]["risk_breakdown"], s[0]["confidence_breakdown"]) if s else ({}, {})
    rbr = "".join(f'<tr><td>{e(k)}</td><td class="n">{num(v, 2) if v is not None else "<span class=\"muted\">no data</span>"}</td></tr>' for k, v in rb.items())
    cbr = "".join(f'<tr><td>{e(k)}</td><td>{"<span class=\"pill ok\">held</span>" if v else "<span class=\"pill warn\">missing</span>"}</td></tr>' for k, v in cb.items())
    facts = "".join(f'<tr><td>{e(k)}</td><td>{e(str(v))}</td></tr>' for k, v in r.items()
                    if v not in (None, "") and k not in ("company_id",))
    recs = q("SELECT record_type, record_date, detail, address, county, employees_affected, source_url "
             "FROM analytics.records WHERE company_id = %s ORDER BY record_date DESC NULLS LAST LIMIT 100", (cid,))
    rr = "".join(f'<tr><td>{e(x["record_type"])}</td><td>{e(str(x["record_date"] or ""))}</td><td>{e(x["detail"] or "")}</td>'
                 f'<td>{e(x["address"] or "")}</td><td class="n">{num(x["employees_affected"])}</td>'
                 f'<td>{"<a href=\"" + e(x["source_url"]) + "\">source</a>" if x["source_url"] else ""}</td></tr>' for x in recs)
    body = f"""<section><h2>{e(r["company_name"] or "")} <span class="{grade_cls(r.get("goodness_grade"))}">{e(r.get("goodness_grade") or "")}</span></h2>
<div class="stats"><div class="stat"><b>{num(r.get("risk_score"),2)}</b><span>risk</span></div><div class="stat"><b>{num(r.get("confidence_score"))}</b><span>confidence</span></div>
<div class="stat"><b>{num(r.get("goodness_percent"))}%</b><span>goodness</span></div></div></section>
<section><h2>Why this score</h2><div class="scroll" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px">
<table><tr><th>Risk signal</th><th class="n">Value (0-1)</th></tr>{rbr}</table>
<table><tr><th>Evidence pillar</th><th>State</th></tr>{cbr}</table></div></section>
<section><h2>Records</h2><div class="scroll"><table><tr><th>Type</th><th>Date</th><th>Detail</th><th>Address</th><th class="n">Employees</th><th></th></tr>{rr}</table></div></section>
<section><h2>All published fields</h2><div class="scroll"><table>{facts}</table></div></section>"""
    return page(r["company_name"] or "Company", body)


def view_sources():
    rows = cached("catalog", lambda: q("SELECT source, publisher, url, licence, licence_url, licence_status, filters "
                                       "FROM analytics.source_catalog ORDER BY source"))
    cls = {"verified": "ok", "owner_decision": "warn", "unverified": "bad"}
    tr = "".join(
        f'<tr><td><a href="{e(r["url"] or "")}">{e(r["publisher"] or r["source"])}</a></td>'
        f'<td><span class="pill {cls.get(r["licence_status"], "warn")}">{e((r["licence_status"] or "").replace("_", " "))}</span><br>'
        + (f'<a href="{e(r["licence_url"])}">{e(r["licence"] or "")}</a>' if r["licence_url"] else e(r["licence"] or ""))
        + f'</td><td>{e(r["filters"] or "none needed")}</td></tr>' for r in rows)
    body = f"""<section><h2>Sources and why each is publishable {tip("verified = licence read on the publisher's own page; owner decision = no licence published, owner's recorded judgement; unverified = no licence found yet.")}</h2>
<div class="scroll"><table><tr><th>Source</th><th>Basis</th><th>Filters applied at ingest</th></tr>{tr}</table></div></section>"""
    return page("Sources", body)


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # one line per request, no query strings
        print(f'{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ} {self.command} {self.path.split("?")[0]} {args[1] if len(args) > 1 else ""}', flush=True)

    def send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; form-action 'self'; frame-ancestors 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        try:
            if u.path == "/healthz":
                return self.send(200, "ok", "text/plain")
            if u.path == "/":
                return self.send(200, view_ingestion())
            if u.path == "/companies":
                return self.send(200, view_companies(urllib.parse.parse_qs(u.query)))
            if u.path.startswith("/company/"):
                try:
                    cid = int(u.path.rsplit("/", 1)[1])
                except ValueError:
                    return self.send(404, page("Not found", "<section>Not found.</section>"))
                body = view_company(cid)
                return self.send(200 if body else 404, body or page("Not found", "<section>Not found.</section>"))
            if u.path == "/sources":
                return self.send(200, view_sources())
            return self.send(404, page("Not found", "<section>Not found.</section>"))
        except Exception as ex:
            print(f"error {u.path}: {ex!r}", flush=True)
            return self.send(500, "<p>Temporarily unavailable.</p>")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
