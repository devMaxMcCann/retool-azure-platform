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
| analytics build | `analytics` | daily 13:00 | one transaction; Retool never sees a half build |

## Rules the code enforces

- **Publication filters run at ingest** (`data/tables.yaml`): a row that can't be
  published never enters Azure, not even in the raw database.
- **One honest User-Agent**, with a contact from `INGEST_CONTACT`. The pipeline
  refuses to start without it.
- **A refusal is final.** 401/403/429 marks the run `blocked` in `ingest_runs`
  and exits cleanly, so Kubernetes doesn't retry it. No other identity is tried.
- **Matching is exact normalized name**, the homelab rule; never containment.
- Every change of a source's terms goes in `data/publication-review.md` first,
  then `pipeline/catalog.py`.

## Build and run

```bash
make ingest-image                 # builds in ACR, prints the tag
# set ingest_image_tag (and ingest_contact) in infra/platform/local.auto.tfvars, then plan/apply
make ingest-run STEP=warn         # run one step now
make ingest-status
```
