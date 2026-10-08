# ingest: public-data pipeline

Loaders pull public sources into `jobs_ingest`; `analytics` rebuilds
`jobs_analytics.analytics`, the only schema Retool can read.

```
python -m pipeline schema        # tables + source_catalog (runs as an init container)
python -m pipeline <source>      # one loader, recorded in ingest_runs
python -m pipeline analytics     # rebuild the published layer (analytics_builder creds)
```

| Source | Step | Schedule (UTC) | Notes |
|---|---|---|---|
| Illinois WARN | `warn` | daily 10:00 | the company spine; every .xlsx report since 2020 |
| Census geocoder | `geocode` | daily 10:30 | WARN street addresses only, 500 per run, cached |
| Chicago business licences | `chicago_licenses` | daily 11:00 | entity names only; no home occupation/peddler/home repair |
| IDFPR business licences | `idfpr_licenses` | Sun 11:30 | ODbL; entity names only |
| BLS JOLTS + LAUS | `bls_series` | Mon 12:00 | about three years per series |
| BLS QCEW (Cook) | `bls_qcew` | Mon 12:15 | last 8 published quarters |
| DOL LCA (H-1B) | `dol_lca` | 1st 06:00 | aggregated per employer |
| DOL PERM | `dol_perm` | 2nd 06:00 | aggregated per employer |
| MSHA violations | `msha_violations` | 3rd 06:00 | controller names never read |
| SBA PPP > $150k | `sba_ppp` | 4th 06:00 | person business types dropped |
| OSHA severe injuries | `osha_sir` | suspended | OSHA's CloudFront refuses non-browser clients (403, robots.txt included) |
| IRS EO BMF | `irs_eo_bmf` | 6th 06:00 | four CSVs streamed off the socket; WARN-name matches only; no ICO/street |
| FDIC BankFind | `fdic_bankfind` | 7th 06:00 | whole institution list (3 pages), WARN-name matches only |
| CMS hospitals | `cms_care_compare` | 8th 06:00 | whole list at robots crawl-delay 10s, WARN-name matches only |
| SEC EDGAR | `sec_edgar` | Tue 07:00 | bulk name index -> submissions JSON; CIK/EIN, 8-K Item 2.05, Form D; no individuals |
| SEC XBRL financials | `sec_financials` | Tue 08:30 | annual revenue/net income/debt for matched CIKs; 2 req/s |
| USAspending | `usaspending` | daily 07:15 | ~300 WARN filers per run; exact recipient-name matches |
| FMCSA SAFER | `fmcsa_safer` | daily 08:15 | ~300 per run; USDOT only when one carrier matches exactly |
| CFPB complaints | `cfpb_complaints` | daily 09:15 | ~300 per run; one count per company, no narratives |
| FTC cases | `ftc_cases` | Wed 07:00 | 150 listing pages per run at crawl-delay 5s; single-party titles only |
| Fed enforcement | `fed_enforcement` | Thu 07:00 | RSS, accumulates; titles naming individuals dropped |
| analytics build | `analytics` | daily 13:00 | one transaction; Retool never sees a half build |

Not ported, and why: EPA ECHO (echodata.epa.gov robots.txt is `Disallow: *`), DOJ
Antitrust case index (justice.gov answers with an Akamai bot-verification page),
SEC related entities (the homelab fills them by name containment), and every
source data/tables.yaml excludes (Cook County, courts, FINRA, NFA, Form ADV, IL
debarred, crt.sh, RDAP, layoff trackers, ProPublica) or leaves to the owner
(NLRB, OCC).

## Rules the code enforces

- **Publication filters run at ingest** (`data/tables.yaml`): a row that can't be
  published never enters Azure, not even in the raw database.
- **One honest User-Agent**, with a contact from `INGEST_CONTACT`. The pipeline
  refuses to start without it.
- **A refusal is final.** 401/403/429 marks the run `blocked` in `ingest_runs`
  and exits cleanly, so Kubernetes doesn't retry it. No other identity is tried.
- **Matching is exact normalized name**, the homelab rule; never containment.
  Company-keyed sources store only rows matching a WARN filer's normalized name
  (the `demo_public_companies` row filter, applied at ingest). Case titles are
  split into parties and each party must match exactly.
- **Each host's robots.txt was read once** before its loader was written; the
  result is in the loader's docstring. Crawl-delays are honoured.
- **4xx other than 401/403/429 is not retried** (our request is wrong); the
  geocoder caches such addresses as `invalid` and moves on.
- Every change of a source's terms goes in `data/publication-review.md` first,
  then `pipeline/catalog.py`.

## Build and run

```bash
make ingest-image                 # builds in ACR, prints the tag
# set ingest_image_tag (and ingest_contact) in infra/platform/local.auto.tfvars, then plan/apply
make ingest-run STEP=warn         # run one step now
make ingest-status
```
