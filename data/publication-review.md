# Publication review: which public sources the Azure platform may publish

- **Reviewed:** 2026-10-07. All citations were fetched that day.
- **Scope:** every public data source used by the source system (a private job-search database) and every table it holds. Only public-source data is eligible.
- **Machine-readable version:** `tables.yaml`, next to this file.
- **Owner's rule:** "only legal things I can put on the net, nothing personal, no comments, strictly showing the sourcing tools and MCP citations on the reasoning why it's legal/ok to share".
- **Compliance registry:** the compliance-registry MCP did not connect during the review (connection timeout). Every `compliance_registry_id` is `null`, to be filled in later.

**How the labels work**
- **verified** — the quoted words were read on the publisher's own page (or the dataset's own metadata API) on 2026-10-07.
- **unverified** — no primary-source licence statement was found. The basis relied on is stated, and is not presented as a licence.
- **owner_decision** — no licence exists; the owner's recorded judgement is the basis, labelled as such.

**Decision rule**
- **Publish:** only when the source permits redistribution, or it is a US federal agency's own data (17 U.S.C. 105). In either case personal data must be removable with a column drop or a row filter.
- **Exclude:** state and county sources with no licence found, third-party terms that restrict use, anything whose acquisition is disallowed by robots.txt, and anything that can't be made non-personal.

---

## 0. Summary

- The source system mixes public-source data with its owner's private records, so **none of its tables is copied**.
- The Azure build **ingests every eligible public source fresh from the publisher**, applies the publication filters at ingest (a row that can't be published is never stored), and rebuilds analytics from those published inputs only.
- Its company list is **Illinois WARN filers only** (§3.4); every other source joins to it by exact normalized name.

## 1. Private and operational tables → exclude

The source system's own records (private activity, review queues, scoring configuration, audit and operational logs) and every table derived from them: 30 tables in all. They are summarised as a single entry in `tables.yaml`. None is published, and none is needed: the public build recomputes its scores from published inputs with a public-only scoring configuration.

---

## 3. Public sources, by publisher

Each entry gives the URL actually called in code, the citation, the personal-data columns, and the decision.

### 3.1 City of Chicago Data Portal — verified

- **Called:**
  - `https://data.cityofchicago.org/resource/uupf-x98q.json` (Business Licenses – Current Active)
  - `https://data.cityofchicago.org/resource/g8p5-y4m5.json` (Lobbyist Data – Clients)
- **Terms** (https://www.chicago.gov/city/en/narr/foia/data_disclaimer.html, fetched 2026-10-07):
  - The City "may require a user of this data to terminate any and all display" — **verified**.
  - Derivative applications must display a fixed disclaimer, which begins "This site provides applications using data that has been modified" — **verified**.
  - Dataset metadata for uupf-x98q: `licenseId: SEE_TERMS_OF_USE` — **verified**.
- **Obligation:** the Retool app must show the City's disclaimer paragraph verbatim. Copy it from the page.
- **`chicago_business_licenses` personal data:**
  - `legal_name` is the owner's own name for sole proprietors. The schema comment confirms a peddler licence under an individual's name.
  - `address` is a home address for Home Occupation and Peddler licences.
  - `property_owner_reference`, `verified_address` and `verified_pin` come from Cook County (§3.3) and carry owner names.
  - **Decision: publish-filtered.** Keep `license_description NOT IN ('Home Occupation','Peddler License','Home Repair')` and keep only entity-suffixed `legal_name` values (Postgres regex in the yaml). Drop the Cook-derived columns. Keep `verified_lat`/`verified_lon`, which come from the Census geocoder (federal).
- **`chicago_lobbyist_clients`:** entity-level, matched to companies. **Decision: publish-filtered** on `demo_public_companies`.
- **`business_license_company_links`:** derived. Publish only links whose licence and company are both published.

### 3.2 Illinois IDFPR Professional Licensing — verified (ODbL)

- **Called:** `https://illinois-edp.data.socrata.com/resource/pzzh-kp68.json`, limited to `business='Y'`.
- **Licence:** dataset metadata (https://illinois-edp.data.socrata.com/api/views/pzzh-kp68.json, fetched 2026-10-07) shows `licenseId: "ODBL"` and `termsLink: http://opendatacommons.org/licenses/odbl/1.0/` — **verified**.
- **Obligations:**
  - Attribute IDFPR.
  - Any derived database used publicly must itself be offered under ODbL (share-alike). This covers `idfpr_license_company_links` and anything in analytics built from it.
- **Personal data:** a `business_name` with `business='Y'` can still be a person's name. No street address is stored (city, zip and county only).
- **Decision: publish-filtered** on entity-suffixed `business_name`.

### 3.3 Cook County (Assessor, GIS, Clerk) — restrictive or unverified → exclude

- **Called:**
  - `https://gis.cookcountyil.gov/hosting/rest/services/Hosted/Parcel_2022/FeatureServer/0/query`
  - `https://datacatalog.cookcountyil.gov/resource/3723-97qp.json`
  - `https://crs.cookcountyclerkil.gov/Search` (Clerk recordings)
- **Terms** (https://www.cookcountyil.gov/terms-use, fetched 2026-10-07): "The content of County websites is copyrighted". No reuse grant appears — **verified**.
- **Metadata:** for 3723-97qp, `license: null` — **verified**.
- **Clerk site:** only "© Copyright 2026 Cook County Clerk's Office." No terms page was found — **unverified**. The module scrapes it through a session cookie and an anti-forgery token.
- **Personal data:**
  - `commercial_parcels.owner_reference` holds homeowners' names for about 1.4M parcels, residential included.
  - `cook_county_recordings.other_party` holds individual buyers, sellers and mortgagors; `address` is the property address.
- **Decision: exclude** `commercial_parcels`, `cook_county_recordings` and `parcel_company_links`. Also drop the Cook-derived `verified_pin`, `verified_address` and `property_owner_reference` columns wherever they appear (`jobs`, `warn_events`, `chicago_business_licenses`).

### 3.4 Illinois WARN (DCEO via Illinois workNet) — unverified licence → publish (owner accepted 2026-10-08)

- **Called:** `https://www.illinoisworknet.com/LayoffRecovery/Pages/ArchivedWARNReports.aspx` (monthly report files).
- **Terms:** the WARN dashboard (https://www.illinoisworknet.com/warndashboard, fetched 2026-10-07) has only a data disclaimer: "It does not capture all layoff activity". There is no licence or terms-of-use link — **unverified**.
- DCEO says the monthly reports are issued publicly since 1999 (https://dceo.illinois.gov/workforcedevelopment/warn.html) — **verified** as a fact about publication, but **not** a licence.
- **Personal data:** the notices are filed by employers and give employer addresses, so low risk. `raw_record` (JSON) holds event type and NAICS. The Cook-derived columns should be dropped (§3.3).
- **Decision (2026-10-08): publish-filtered.** The owner accepted the basis: statutory public notices, published by DCEO since 1999. The licence is still **unverified**; the yaml records this as `owner_decision`, not as a licence. `warn_events` publishes with the drops listed in the yaml, and `companies` with it.
- **Azure build ingests WARN fresh from DCEO**, so the company list holds only public WARN filers.

### 3.5 Illinois Department of Labor debarred contractors — unverified → exclude

- **Called:** `https://labor.illinois.gov/laws-rules/conmed/debarred-contractors.html`.
- No licence on the page — **unverified**. The notice says debarment applies to "all its directors, officers" — **verified**. In other words, the notice reaches natural persons.
- **Decision: exclude.**

### 3.6 US federal sources: public domain by statute or agency statement

- **Statute** (17 U.S.C. 105(a), https://www.law.cornell.edu/uscode/text/17/105, fetched 2026-10-07): copyright is "not available for any work of the United States Government" — **verified**.
  - The official uscode.house.gov page was in maintenance, so this text is from Cornell LII.
- Where I couldn't fetch an agency page, the yaml says `unverified` and names the statute as the basis, not as the agency's own licence.

| source module(s) → table(s) | URL called | publisher statement | status |
|---|---|---|---|
| `bls_jolts.py`, `bls_local_labor.py` → `bls_*` | `api.bls.gov/publicAPI/v2/timeseries/data/`, `data.bls.gov/cew/data/api/...` | "everything that we publish ... is in the public domain" (https://www.bls.gov/opub/copyright-information.htm) | verified |
| `ingest_dol_lca.py`, `ingest_dol_perm.py` → `dol_*` | `dol.gov/agencies/eta/foreign-labor/performance` → `LCA_/PERM_Disclosure_Data_*.xlsx` | "may be used, reproduced and distributed without permission" (https://www.dol.gov/general/aboutdol/copyright) | verified |
| `msha_mines.py`, `ingest_msha_violations.py` | `arlweb.msha.gov/OpenGovernmentData/DataSets/Mines.zip`, `Violations.zip` | same DOL statement (MSHA is part of DOL) | verified |
| `osha_severe_injury.py` | `osha.gov/sites/default/files/January2015toNovember2025.zip` | same DOL statement (OSHA is part of DOL) | verified |
| `ingest_sba_ppp.py` | `data.sba.gov/.../public_150k_plus_240930.csv` | dataset licence field "U.S. Government Works" (https://data.sba.gov/dataset/ppp-foia) | verified |
| `fed_enforcement.py` | `federalreserve.gov/feeds/press_enforcement.xml` | "information on Board's website is in the public domain" (https://www.federalreserve.gov/disclaimer.htm) | verified |
| `doj_antitrust_cases.py` | `justice.gov/atr/antitrust-case-filings-alpha` | "information on Department of Justice websites is in the public domain" (https://www.justice.gov/legalpolicies) | verified |
| `sec_edgar.py`, `sec_filings.py`, `sec_form_d.py`, `sec_financials.py` | `data.sec.gov/submissions`, `efts.sec.gov/LATEST/search-index`, `data.sec.gov/api/xbrl/companyfacts`, `sec.gov/files/company_tickers.json` | "Anyone can access and download this information for free" (https://www.sec.gov/search-filings/edgar-search-assistance/accessing-edgar-data). This is an access statement, not a licence. Filings are company-authored, so 105 doesn't cover the prose. | unverified (licence) |
| `epa_echo.py` | `echodata.epa.gov/echo/echo_rest_services.get_facilities`, `DFR_rest_services.get_dfr` | "geospatial data produced by the EPA is by default in the public domain"; documents only for "non-commercial, scientific and educational purposes" (https://www.epa.gov/web-policies-and-procedures/epa-disclaimers). ECHO tabular data is not explicitly covered. | unverified |
| `usaspending.py` | `api.usaspending.gov/api/v2/search/spending_by_award/` | no licence text found on /about | unverified |
| `fdic_bankfind.py` | `api.fdic.gov/banks/institutions` | website-policies page has no public-domain statement | unverified |
| `cms_care_compare.py` | `data.cms.gov/provider-data/api/1/datastore/query/xubh-q36u/0` | policy page 404 | unverified |
| `fmcsa_safer.py` | `safer.fmcsa.dot.gov/query.asp` | no licence page fetched | unverified |
| `occ_enforcement.py` | `apps.occ.gov/EASearch/api/WebSearch/Actions` (reverse-engineered JSON API) | policies page has no licence text | unverified |
| `nlrb_case_search.py` | `nlrb.gov/search/case` → `/nlrb-downloads/...` CSV export (undocumented endpoint, self-minted session token) | site-policies 404 | unverified |
| `ftc_cases.py` | `ftc.gov/legal-library/browse/cases-proceedings` | copyright page 404 | unverified |
| `cfpb_complaints.py` | `consumerfinance.gov/data-research/consumer-complaints/search/api/v1/` | "We don't publish personal information" (https://www.consumerfinance.gov/complaint/data-use/). No reuse statement. | verified (privacy) / unverified (licence) |
| `irs_eo_bmf.py` (feeds only `companies.ein_eo_bmf_check`) | `irs.gov/pub/irs-soi/eo1..eo4.csv` | no licence text on the EO BMF page | unverified |
| Census geocoder (inside `chicago_property.py`) | `geocoding.geo.census.gov/geocoder/locations/onelineaddress` | no licence text on page | unverified |

**Personal data in the federal tables**

- **`dol_lca_employers`, `dol_perm_employers`:** employers can be natural persons. PERM includes private-household employers; LCA includes solo practices. Filter to entity-suffixed names.
  - Optional extra: a single-filing employer row shows one worker's wage, although the worker isn't named.
- **`msha_violations_employers`, `msha_violations_matches`:** MSHA controllers and violators are often individuals. Drop `latest_controller_name` and filter `violator_name` to entities.
- **`sba_ppp_employers`, `sba_ppp_matches`:** sole proprietors, self-employed people and independent contractors are natural persons. Filter them out by `latest_business_type` and by entity suffix.
- **`osha_severe_injury_reports`:** `narrative` is free text about the injured worker's incident. Drop it ("no comments", nothing personal).
- **`occ_enforcement_actions`:** actions include institution-affiliated individuals at a bank. Filter out prohibition, removal and individual action types. **The owner should review the distinct `enforcement_type` values.**
- **`fed_enforcement_actions`:** titles can name former employees (prohibition orders). Regex filter in the yaml.
- **`doj_antitrust_cases`, `ftc_cases`:** captions can list individual co-defendants. Keep single-party captions only.
- **`sec_filings`:** drop `excerpt`. It is company-authored prose, not a government work.
- **`company_related_entities`:** EDGAR name search can return individual insiders, who have CIKs. Filter to entities.
- **`nlrb_cases`, `fdic_institutions`, `cms_care_compare_hospitals`, `fmcsa_safer_carriers`, `msha_mines`, `usaspending_awards`, `sec_form_d_filings`, `company_financials`, `epa_echo_facilities`, `cfpb_complaints`:** entity-level only. No individual-name columns are stored; `cfpb_complaints` holds a count, not narratives.
- **Decision for all of these:** publish-filtered on `demo_public_companies`.
- **Base tables** (`dol_*_employers`, `msha_violations_employers`, `sba_ppp_employers`): these are bulk aggregates, not company-keyed, so they publish rows now.

### 3.7 FINRA BrokerCheck — verified restrictive → exclude

- **Called:** `https://api.brokercheck.finra.org/search/firm/{crd}`.
- **Terms** (https://www.finra.org/investors/learn-to-invest/choosing-investment-professional/about-brokercheck/permitted-uses, fetched 2026-10-07):
  - BrokerCheck permits use "for investor protection, academic, compliance or regulatory purposes" — **verified**.
  - Redistribution also requires an error-correction process and keeping the data current — **verified**.
  - The FINRA site ToS (https://www.finra.org/terms-of-use) says content is "ONLY for your own non-commercial personal or professional use" — **verified**.
- **Decision: exclude** `finra_brokercheck_detail`. An interview demo is none of the permitted purposes.

### 3.8 SEC IAPD (Form ADV/BD) and NFA BASIC → exclude

- **IAPD:** calls `https://api.adviserinfo.sec.gov/search/firm`. The terms could not be retrieved, and the data is FINRA-operated CRD data — **unverified**. **Exclude** `sec_form_adv`.
- **NFA BASIC:** calls `https://www.nfa.futures.org/BasicNet/basic-api/DataHandlerSearch.ashx`.
  - The terms (https://www.nfa.futures.org/BasicNet/basic-terms.aspx, fetched 2026-10-07) describe the data but grant no reuse right. The footer says "All Rights Reserved." — **verified**.
  - **Exclude** `nfa_basic_firms`.

### 3.9 Illinois JobLink — robots.txt disallows search → exclude

- **robots.txt** (https://illinoisjoblink.illinois.gov/robots.txt, fetched 2026-10-07): `Disallow: /search/jobs` — **verified**.
- The postings are employer-authored content. **Not used** by the public build.

### 3.10 ProPublica Nonprofit Explorer — verified restrictive → drop derived EINs

- **Called:** `https://projects.propublica.org/nonprofits/api/v2/search.json` (`sources/nonprofit_ein.py`). The results go into `companies.ein` with `ein_source='nonprofit_irs'`.
- **Terms** (https://www.propublica.org/datastore/terms, fetched 2026-10-07): "You can't republish the raw data in its entirety or otherwise distribute" — **verified**.
- **Decision:** drop `ein`/`ein_matched_name` on those rows, unless `ein_eo_bmf_check='match'`. A match means the IRS EO BMF independently carries the same EIN, so the published value is the IRS's own fact.

### 3.11 CourtListener / RECAP — licence OK, personal data → exclude

- **Called:** `https://www.courtlistener.com/api/rest/v4/search/` (type=r).
- **ToS** (https://www.courtlistener.com/terms/, fetched 2026-10-07): "judicial opinions, motions, and other filings are generally in the public domain". The ToS also says "Attribute honestly." — **verified**.
- The underlying court system is federal PACER, via the RECAP archive. PACER's own terms were not reviewed.
- **Personal data:** `case_name` names individual litigants (the module's own example is "Roberts v. Deloitte"). `docket_number` and `source_url` lead straight to them.
- **Decision: exclude** `court_records`. Dropping `case_name` would still leave a pointer to the individual.

### 3.12 Certificate Transparency (crt.sh) and RDAP → exclude

- **crt.sh:** called at `https://crt.sh/?` (`cert_transparency.py`). No terms page was found — **unverified**.
- **RDAP:** called at `https://rdap.org/domain/{d}`. The page shows "Copyright 2026 RDAP.ORG". Per-registry RDAP terms were not reviewed — **unverified**.
- **Personal data:** `domain_registrations.registrant_name` can be a person. Both tables are also keyed to private data (§1).
- **Decision: exclude.**

### 3.13 Layoff trackers → exclude

- `sources/layoff_trackers.py` raises `NotImplementedError`, and no site was ever chosen.
- Third-party aggregators are not primary sources. The module's own docstring warns that their reuse terms must be confirmed before anything is published.
- **Decision: exclude** `layoff_tracker_reports` (expected to be empty).

### 3.14 Socrata catalog discovery

- **Called:** `https://api.us.socrata.com/api/catalog/v1`. It feeds only `catalog_scan_findings`, an operational review queue. **Exclude.**

---

## 4. Azure build

- **Ingest DB:** one loader per eligible source, filters and drops applied at ingest exactly as `tables.yaml` lists them.
- **Analytics DB:** matches, licence links, scores and serving tables, rebuilt in one transaction from published inputs only, with a public-only scoring configuration.
- **Attribution and disclaimers shown with the data:**
  - The City of Chicago's verbatim derivative-application disclaimer.
  - IDFPR attribution and the ODbL notice.
  - The citation BLS requests.
- **Entity-name filters are heuristics.** The suffix regex (`inc|llc|corp|...`) will miss some entities and could keep names like "Smith Group". Spot-check a sample.

## 5. Needs the owner's judgement

1. ~~**Illinois WARN**~~ **Decided 2026-10-08: accepted** (§3.4). There is no licence. These are statutory public notices that DCEO publishes, and they record facts. If the owner accepts that basis, `warn_events` and `companies` flip to publish-filtered, and every company-keyed federal table starts publishing rows. Without it, the demo has no company spine.
2. **Federal sources with no agency licence page** (USAspending, FDIC, CMS, FMCSA, OCC, NLRB, FTC, EPA ECHO, CFPB). I relied on 17 U.S.C. 105 rather than an agency statement. EPA's page limits *documents* to non-commercial use. Is a job-interview demo "commercial"?
3. **Acquisition method.** NLRB (undocumented CSV export endpoint) and OCC (reverse-engineered API) are federal public-domain content. Are those methods acceptable to show in a demo of "sourcing tools"?
4. **The `occ_enforcement_actions` type filter, and the title filters for Fed, DOJ and FTC.** These are regexes that need a human pass over the distinct values.
