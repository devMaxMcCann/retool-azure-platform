-- jobs_analytics rebuild. Runs as analytics_builder, in ONE transaction, so
-- Retool (retool_reader, read-only) only ever sees a complete build.
--
-- Inputs are foreign tables in schema `ingest` (postgres_fdw -> jobs_ingest,
-- logged in as the read-only analytics_fdw role). Outputs are plain tables in
-- schema `analytics`, which is the only thing Retool can read.
--
-- Mirrors the homelab jobs-scoring serving layer (serving_company_rollup,
-- serving_public_companies, serving_facets, serving_counts, /map markers)
-- minus every private input: no applications, postings, messages, scans,
-- parcels, domains. Matching is the homelab's rule: exact normalized name,
-- never containment.

-- ------------------------------------------------------------ companies
-- One company per normalized WARN filer name. Spelling variants of one filer
-- ("Acme, Inc." / "ACME INC") hash to different synthetic ids, so the
-- smallest id is kept as THE id: stable as long as the variant exists.
DROP TABLE IF EXISTS analytics.companies CASCADE;
CREATE TABLE analytics.companies AS
SELECT min(company_id)                                            AS company_id,
       normalized_name,
       (array_agg(company_name ORDER BY notice_date DESC NULLS LAST))[1] AS company_name,
       count(*)                                                   AS n_warn_events,
       sum(employees_affected)                                    AS employees_affected_total,
       min(notice_date)                                           AS first_notice_date,
       max(notice_date)                                           AS latest_notice_date,
       string_agg(DISTINCT county, ', ')                          AS counties,
       (array_agg(naics ORDER BY notice_date DESC NULLS LAST))[1] AS naics
  FROM ingest.warn_events
 WHERE normalized_name <> ''
 GROUP BY normalized_name;
ALTER TABLE analytics.companies ADD PRIMARY KEY (company_id);
CREATE UNIQUE INDEX ON analytics.companies (normalized_name);

DROP TABLE IF EXISTS analytics.warn_events;
CREATE TABLE analytics.warn_events AS
SELECT c.company_id, e.company_name, e.notice_date, e.effective_date, e.employees_affected,
       e.event_type, e.layoff_type, e.county, e.il_location, e.il_location_precision,
       e.reported_state, e.naics, e.source_url,
       g.lat, g.lon
  FROM ingest.warn_events e
  JOIN analytics.companies c USING (normalized_name)
  LEFT JOIN ingest.warn_geocodes g ON g.address_key = e.il_location AND g.status = 'matched';
CREATE INDEX ON analytics.warn_events (company_id);

-- -------------------------------------------------- licence links
-- Chicago: legal name first, else DBA. relationship='franchise' when a
-- company is matched by DBA only, across more than one distinct legal
-- entity (homelab link_business_licenses_to_companies).
DROP TABLE IF EXISTS analytics.chicago_business_licenses;
CREATE TABLE analytics.chicago_business_licenses AS
SELECT account_number, site_number, legal_name, doing_business_as_name, address, city, state, zip,
       license_description, business_activity, license_status, license_start_date, expiration_date,
       date_issued, city_lat AS lat, city_lon AS lon, normalized_legal, normalized_dba
  FROM ingest.chicago_business_licenses;
ALTER TABLE analytics.chicago_business_licenses ADD PRIMARY KEY (account_number, site_number);

DROP TABLE IF EXISTS analytics.license_links;
CREATE TABLE analytics.license_links AS
WITH m AS (
    SELECT c.company_id, l.account_number, l.site_number, l.legal_name,
           CASE WHEN l.normalized_legal = c.normalized_name THEN 'legal' ELSE 'dba' END AS matched_on
      FROM analytics.chicago_business_licenses l
      JOIN analytics.companies c
        ON c.normalized_name IN (l.normalized_legal, l.normalized_dba)
)
SELECT m.company_id, m.account_number, m.site_number, m.matched_on,
       CASE WHEN m.matched_on = 'dba'
             AND (SELECT count(DISTINCT m2.legal_name) FROM m m2
                   WHERE m2.company_id = m.company_id AND m2.matched_on = 'dba') > 1
            THEN 'franchise' ELSE 'direct' END AS relationship
  FROM m;
CREATE INDEX ON analytics.license_links (company_id);

DROP TABLE IF EXISTS analytics.idfpr_licenses;
CREATE TABLE analytics.idfpr_licenses AS
SELECT license_number, license_type, description, business_name, businessdba, license_status,
       original_issue_date, effective_date, expiration_date, city, state, zip, county, ever_disciplined,
       normalized_name, normalized_dba
  FROM ingest.idfpr_licenses;

DROP TABLE IF EXISTS analytics.idfpr_links;
CREATE TABLE analytics.idfpr_links AS
SELECT c.company_id, l.license_number,
       CASE WHEN l.normalized_name = c.normalized_name THEN 'legal' ELSE 'dba' END AS matched_on
  FROM analytics.idfpr_licenses l
  JOIN analytics.companies c ON c.normalized_name IN (l.normalized_name, l.normalized_dba);
CREATE INDEX ON analytics.idfpr_links (company_id);

-- -------------------------------------------- federal employer matches
DROP TABLE IF EXISTS analytics.dol_lca_matches;
CREATE TABLE analytics.dol_lca_matches AS
SELECT c.company_id, d.employer_name, d.certified_lca_count, d.latest_job_title, d.latest_received_date,
       d.min_annual_wage, d.max_annual_wage, d.fy_quarter
  FROM ingest.dol_lca_employers d JOIN analytics.companies c USING (normalized_name);

DROP TABLE IF EXISTS analytics.dol_perm_matches;
CREATE TABLE analytics.dol_perm_matches AS
SELECT c.company_id, d.employer_name, d.certified_perm_count, d.latest_job_title, d.latest_received_date,
       d.latest_worksite_city, d.latest_worksite_state, d.min_annual_wage, d.max_annual_wage, d.fiscal_year
  FROM ingest.dol_perm_employers d JOIN analytics.companies c USING (normalized_name);

DROP TABLE IF EXISTS analytics.msha_violations_matches;
CREATE TABLE analytics.msha_violations_matches AS
SELECT c.company_id, m.violator_name, m.violation_count, m.sig_sub_count, m.total_proposed_penalty,
       m.total_amount_paid, m.distinct_mine_count, m.latest_violation_date
  FROM ingest.msha_violations_employers m JOIN analytics.companies c USING (normalized_name);

DROP TABLE IF EXISTS analytics.sba_ppp_matches;
CREATE TABLE analytics.sba_ppp_matches AS
SELECT c.company_id, p.borrower_name, p.loan_count, p.total_current_approval, p.total_forgiveness,
       p.total_jobs_reported, p.latest_date_approved, p.latest_loan_status, p.latest_naics_code,
       p.latest_business_type, p.borrower_state
  FROM ingest.sba_ppp_employers p JOIN analytics.companies c USING (normalized_name);

DROP TABLE IF EXISTS analytics.osha_severe_injury_reports;
CREATE TABLE analytics.osha_severe_injury_reports AS
SELECT c.company_id, o.report_id, o.employer, o.event_date, o.city, o.state, o.naics,
       o.hospitalized_count, o.amputation_count, o.loss_of_eye_count, o.nature_title, o.event_title
  FROM ingest.osha_severe_injury_reports o JOIN analytics.companies c USING (normalized_name);
CREATE INDEX ON analytics.osha_severe_injury_reports (company_id);

-- ------------------------------------- company-keyed federal sources
-- Ingest already kept only rows whose own name normalizes to a WARN filer's
-- name; these joins attach them to the company by that exact key.
DROP TABLE IF EXISTS analytics.irs_eo_bmf_matches;
CREATE TABLE analytics.irs_eo_bmf_matches AS
SELECT c.company_id, o.ein, o.name, o.city, o.state, o.subsection, o.ntee_cd, o.ruling, o.revenue_amt
  FROM ingest.irs_eo_bmf_orgs o JOIN analytics.companies c USING (normalized_name);
CREATE INDEX ON analytics.irs_eo_bmf_matches (company_id);

DROP TABLE IF EXISTS analytics.sec_companies;
CREATE TABLE analytics.sec_companies AS
SELECT c.company_id, s.cik, s.name, s.ein, s.entity_type, s.sic, s.sic_description, s.state_of_incorporation,
       s.tickers, s.exchanges
  FROM ingest.sec_companies s JOIN analytics.companies c USING (normalized_name);
CREATE INDEX ON analytics.sec_companies (company_id);

-- Identifiers per company. An EIN/CIK is published as THE company's only
-- when the sources agree on exactly one value (homelab irs_eo_bmf: a name
-- shared by organisations with different EINs is ambiguous, so none).
DROP TABLE IF EXISTS analytics.company_identifiers;
CREATE TABLE analytics.company_identifiers AS
WITH e AS (
    SELECT company_id, ein, 'irs_eo_bmf' AS src FROM analytics.irs_eo_bmf_matches
    UNION ALL SELECT company_id, ein, 'sec_edgar' FROM analytics.sec_companies WHERE ein IS NOT NULL
), ein AS (
    SELECT company_id, count(DISTINCT ein) AS n_ein, min(ein) AS ein, string_agg(DISTINCT src, ',') AS ein_sources
      FROM e GROUP BY company_id
), cik AS (
    SELECT company_id, count(DISTINCT cik) AS n_cik, min(cik) AS cik FROM analytics.sec_companies GROUP BY company_id
)
SELECT c.company_id,
       CASE WHEN ein.n_ein = 1 THEN ein.ein END AS ein,
       CASE WHEN ein.n_ein = 1 THEN ein.ein_sources END AS ein_sources,
       coalesce(ein.n_ein, 0) AS ein_candidates,
       CASE WHEN cik.n_cik = 1 THEN cik.cik END AS cik,
       coalesce(cik.n_cik, 0) AS cik_candidates
  FROM analytics.companies c LEFT JOIN ein USING (company_id) LEFT JOIN cik USING (company_id);
ALTER TABLE analytics.company_identifiers ADD PRIMARY KEY (company_id);

DROP TABLE IF EXISTS analytics.sec_filings;
CREATE TABLE analytics.sec_filings AS
SELECT s.company_id, f.cik, f.accession_number, f.filing_type, f.filing_date, f.items, f.item_205, f.source_url
  FROM ingest.sec_filings f JOIN analytics.sec_companies s USING (cik);
CREATE INDEX ON analytics.sec_filings (company_id);

DROP TABLE IF EXISTS analytics.sec_financials;
CREATE TABLE analytics.sec_financials AS
SELECT s.company_id, f.cik, f.metric, f.fiscal_year, f.value, f.filed, f.accn, f.xbrl_tag
  FROM ingest.sec_financials f JOIN analytics.sec_companies s USING (cik);
CREATE INDEX ON analytics.sec_financials (company_id);

DROP TABLE IF EXISTS analytics.usaspending_awards;
CREATE TABLE analytics.usaspending_awards AS
SELECT c.company_id, a.generated_internal_id, a.award_id, a.recipient_name, a.amount, a.awarding_agency,
       a.start_date, a.award_category, a.source_url
  FROM ingest.usaspending_awards a JOIN analytics.companies c USING (normalized_name);
CREATE INDEX ON analytics.usaspending_awards (company_id);

DROP TABLE IF EXISTS analytics.fdic_institutions;
CREATE TABLE analytics.fdic_institutions AS
SELECT c.company_id, f.cert, f.name, f.city, f.state, f.active, f.source_url
  FROM ingest.fdic_institutions f JOIN analytics.companies c USING (normalized_name);

DROP TABLE IF EXISTS analytics.cms_hospitals;
CREATE TABLE analytics.cms_hospitals AS
SELECT c.company_id, h.facility_id, h.facility_name, h.city, h.state, h.hospital_type, h.hospital_ownership,
       h.overall_rating, h.mort_measures_worse, h.safety_measures_worse, h.readm_measures_worse, h.source_url
  FROM ingest.cms_hospitals h JOIN analytics.companies c USING (normalized_name);

DROP TABLE IF EXISTS analytics.fmcsa_carriers;
CREATE TABLE analytics.fmcsa_carriers AS
SELECT c.company_id, f.usdot_number, f.carrier_name, f.source_url
  FROM ingest.fmcsa_carriers f JOIN analytics.companies c USING (normalized_name);

DROP TABLE IF EXISTS analytics.cfpb_complaint_counts;
CREATE TABLE analytics.cfpb_complaint_counts AS
SELECT c.company_id, x.cfpb_company, x.total_complaints, x.as_of, x.source_url
  FROM ingest.cfpb_complaint_counts x JOIN analytics.companies c USING (normalized_name);

DROP TABLE IF EXISTS analytics.ftc_cases;
CREATE TABLE analytics.ftc_cases AS
SELECT c.company_id, f.url, f.title, f.party, f.first_seen
  FROM ingest.ftc_cases f JOIN analytics.companies c USING (normalized_name);
CREATE INDEX ON analytics.ftc_cases (company_id);

DROP TABLE IF EXISTS analytics.fed_enforcement_actions;
CREATE TABLE analytics.fed_enforcement_actions AS
SELECT c.company_id, f.url, f.party, f.action_kind, f.title, f.published
  FROM ingest.fed_enforcement_actions f JOIN analytics.companies c USING (normalized_name);
CREATE INDEX ON analytics.fed_enforcement_actions (company_id);

-- -------------------------------------------------------------- scoring
-- Public-only version of the homelab score_weights model, and like the
-- homelab the weights ARE the definition: company_scores is computed from
-- this table, so adding a measure is a row here plus its line in
-- company_signals, not a change to the formula.
--   risk       = weighted mean of least(n / scale_n, 1) over the risk
--                measures that have a finding (a source with nothing to say
--                drops out instead of counting as zero, homelab scoring.py)
--   confidence = weighted share of confidence pillars held (0..100)
--   employer_rating_score = 100 - (1 - confidence)*40 - risk*60 (homelab common.goodness_nines),
--   banded into employer_rating A+..F. (Homelab calls these employer_rating_score/employer_rating.)
-- Every company is a WARN filer, so every company carries the WARN risk
-- signal: this registry is "employers that filed layoff notices", by design.
-- Measure names follow the homelab's (warn_act -> warn, identity_ein,
-- sec_filing_data) or its source table names (ftc_cases, fed_enforcement).
DROP TABLE IF EXISTS analytics.score_weights;
CREATE TABLE analytics.score_weights (axis text, measure text, label text, scale_n numeric, explanation text,
                                      weight numeric NOT NULL DEFAULT 1);
INSERT INTO analytics.score_weights (axis, measure, label, scale_n, explanation) VALUES
 ('risk', 'warn', 'WARN notices', 3, 'min(notices / 3, 1)'),
 ('risk', 'osha', 'OSHA severe injury reports', 5, 'min(reports / 5, 1)'),
 ('risk', 'msha', 'MSHA significant & substantial violations', 10, 'min(S&S violations / 10, 1)'),
 ('risk', 'sec_item205', 'SEC 8-K Item 2.05 (exit or disposal costs)', 2,
  'min(Item 2.05 8-Ks in the last 5 years / 2, 1): a registrant''s own disclosure of a committed restructuring'),
 ('risk', 'ftc_cases', 'FTC cases and proceedings', 2,
  'min(cases / 2, 1); single-party case titles only (publication filter)'),
 ('risk', 'fed_enforcement', 'Federal Reserve enforcement actions', 1,
  'min(actions issued / 1, 1); terminations of earlier actions are not counted'),
 ('confidence', 'identity_name', 'Named filer', NULL, 'always held: the WARN notice names the employer'),
 ('confidence', 'warn_data', 'WARN notice on file', NULL, 'always held'),
 ('confidence', 'chicago_license', 'City of Chicago licence', NULL, 'linked by exact normalized name'),
 ('confidence', 'idfpr_license', 'Illinois IDFPR licence', NULL, 'linked by exact normalized name'),
 ('confidence', 'located', 'Geocoded Illinois address', NULL, 'Census geocoder matched a WARN street address'),
 ('confidence', 'hiring_evidence', 'Federal hiring filings (LCA/PERM)', NULL, 'certified H-1B LCA or PERM on file'),
 ('confidence', 'identity_ein', 'Federal EIN', NULL,
  'exactly one EIN from the IRS EO BMF and/or SEC EDGAR for this exact name'),
 ('confidence', 'sec_filing_data', 'SEC registrant', NULL, 'an SEC registrant with this exact current name'),
 ('confidence', 'federal_awards', 'Federal contracts or grants', NULL,
  'USAspending award whose recipient name matches exactly'),
 ('confidence', 'regulated_entity', 'Federal registry entry', NULL,
  'FDIC-insured institution, CMS-rated hospital or FMCSA-registered carrier with this exact name');

-- One row per (company, measure) that has a finding; n is the raw count.
DROP TABLE IF EXISTS analytics.company_signals;
CREATE TABLE analytics.company_signals AS
SELECT company_id, 'warn'::text AS measure, n_warn_events::numeric AS n FROM analytics.companies
UNION ALL SELECT company_id, 'osha', count(*) FROM analytics.osha_severe_injury_reports GROUP BY 1
UNION ALL SELECT company_id, 'msha', sum(sig_sub_count) FROM analytics.msha_violations_matches GROUP BY 1
UNION ALL SELECT company_id, 'sec_item205', count(*) FROM analytics.sec_filings WHERE item_205 GROUP BY 1
UNION ALL SELECT company_id, 'ftc_cases', count(*) FROM analytics.ftc_cases GROUP BY 1
UNION ALL SELECT company_id, 'fed_enforcement', count(DISTINCT url) FROM analytics.fed_enforcement_actions
           WHERE action_kind = 'action' GROUP BY 1
UNION ALL SELECT company_id, 'identity_name', 1 FROM analytics.companies
UNION ALL SELECT company_id, 'warn_data', 1 FROM analytics.companies
UNION ALL SELECT company_id, 'chicago_license', count(*) FROM analytics.license_links GROUP BY 1
UNION ALL SELECT company_id, 'idfpr_license', count(*) FROM analytics.idfpr_links GROUP BY 1
UNION ALL SELECT company_id, 'located', count(*) FROM analytics.warn_events WHERE lat IS NOT NULL GROUP BY 1
UNION ALL SELECT company_id, 'hiring_evidence', count(*)
            FROM (SELECT company_id FROM analytics.dol_lca_matches
                  UNION ALL SELECT company_id FROM analytics.dol_perm_matches) h GROUP BY 1
UNION ALL SELECT company_id, 'identity_ein', 1 FROM analytics.company_identifiers WHERE ein IS NOT NULL
UNION ALL SELECT company_id, 'sec_filing_data', count(*) FROM analytics.sec_companies GROUP BY 1
UNION ALL SELECT company_id, 'federal_awards', count(*) FROM analytics.usaspending_awards GROUP BY 1
UNION ALL SELECT company_id, 'regulated_entity', count(*)
            FROM (SELECT company_id FROM analytics.fdic_institutions
                  UNION ALL SELECT company_id FROM analytics.cms_hospitals
                  UNION ALL SELECT company_id FROM analytics.fmcsa_carriers) r GROUP BY 1;
CREATE INDEX ON analytics.company_signals (company_id);

DROP TABLE IF EXISTS analytics.company_scores;
CREATE TABLE analytics.company_scores AS
WITH grid AS (
    SELECT c.company_id, w.axis, w.measure, w.weight, w.scale_n, s.n
      FROM analytics.companies c
     CROSS JOIN analytics.score_weights w
      LEFT JOIN analytics.company_signals s
        ON s.company_id = c.company_id AND s.measure = w.measure AND s.n > 0
), agg AS (
    SELECT company_id,
           sum(weight * least(n / scale_n, 1)) FILTER (WHERE axis = 'risk' AND n IS NOT NULL)
             / nullif(sum(weight) FILTER (WHERE axis = 'risk' AND n IS NOT NULL), 0)             AS risk_score,
           100.0 * coalesce(sum(weight) FILTER (WHERE axis = 'confidence' AND n IS NOT NULL), 0)
             / nullif(sum(weight) FILTER (WHERE axis = 'confidence'), 0)                          AS confidence_score,
           jsonb_object_agg(measure, CASE WHEN n IS NOT NULL THEN round(least(n / scale_n, 1), 4) END)
             FILTER (WHERE axis = 'risk')                                                         AS risk_breakdown,
           jsonb_object_agg(measure, n IS NOT NULL) FILTER (WHERE axis = 'confidence')            AS confidence_breakdown
      FROM grid GROUP BY company_id
)
SELECT company_id, risk_score, confidence_score,
       greatest(0, 100 - (100 - confidence_score) * 0.1 - coalesce(risk_score, 0) * 60) AS employer_rating_score,
       risk_breakdown, confidence_breakdown
  FROM agg;
ALTER TABLE analytics.company_scores ADD COLUMN employer_rating text;
UPDATE analytics.company_scores SET employer_rating = CASE
    WHEN employer_rating_score >= 90 THEN 'A+' WHEN employer_rating_score >= 80 THEN 'A'
    WHEN employer_rating_score >= 70 THEN 'B'  WHEN employer_rating_score >= 60 THEN 'C'
    WHEN employer_rating_score >= 50 THEN 'D'  ELSE 'F' END;
ALTER TABLE analytics.company_scores ADD PRIMARY KEY (company_id);

-- -------------------------------------------------------- serving layer
-- The grouped dashboard (homelab serving_company_rollup), one row per company.
DROP TABLE IF EXISTS analytics.company_rollup;
CREATE TABLE analytics.company_rollup AS
SELECT c.company_id, c.company_name, c.naics, c.counties,
       s.risk_score, s.confidence_score, s.employer_rating_score, s.employer_rating,
       c.n_warn_events, c.employees_affected_total, c.first_notice_date, c.latest_notice_date,
       (SELECT count(*) FROM analytics.license_links l WHERE l.company_id = c.company_id)          AS n_licenses,
       (SELECT count(*) FROM analytics.idfpr_links l WHERE l.company_id = c.company_id)            AS n_idfpr_licenses,
       (SELECT count(*) FROM analytics.osha_severe_injury_reports o WHERE o.company_id = c.company_id) AS n_osha_reports,
       lca.certified_lca_count, perm.certified_perm_count,
       greatest(lca.max_annual_wage, perm.max_annual_wage)                                         AS max_annual_wage_filed,
       ppp.total_current_approval                                                                  AS ppp_approved,
       msha.sig_sub_count                                                                          AS msha_sig_sub,
       ids.ein, ids.cik,
       (SELECT count(*) FROM analytics.sec_filings f WHERE f.company_id = c.company_id AND f.item_205) AS n_sec_item205,
       (SELECT f.value FROM analytics.sec_financials f WHERE f.company_id = c.company_id AND f.metric = 'revenue'
         ORDER BY f.fiscal_year DESC LIMIT 1)                                                     AS sec_latest_revenue,
       (SELECT count(*) FROM analytics.usaspending_awards a WHERE a.company_id = c.company_id)     AS n_federal_awards,
       (SELECT sum(a.amount) FROM analytics.usaspending_awards a WHERE a.company_id = c.company_id) AS federal_award_amount,
       (SELECT min(f.cert) FROM analytics.fdic_institutions f WHERE f.company_id = c.company_id)   AS fdic_cert,
       (SELECT max(h.overall_rating) FROM analytics.cms_hospitals h WHERE h.company_id = c.company_id) AS cms_overall_rating,
       (SELECT min(f.usdot_number) FROM analytics.fmcsa_carriers f WHERE f.company_id = c.company_id) AS fmcsa_usdot,
       -- Informational, not scored: complaints are consumer allegations.
       (SELECT x.total_complaints FROM analytics.cfpb_complaint_counts x WHERE x.company_id = c.company_id) AS cfpb_complaints,
       (SELECT count(*) FROM analytics.ftc_cases f WHERE f.company_id = c.company_id)              AS n_ftc_cases,
       (SELECT count(DISTINCT f.url) FROM analytics.fed_enforcement_actions f
         WHERE f.company_id = c.company_id AND f.action_kind = 'action')                           AS n_fed_actions
  FROM analytics.companies c
  JOIN analytics.company_scores s USING (company_id)
  JOIN analytics.company_identifiers ids USING (company_id)
  LEFT JOIN analytics.dol_lca_matches lca USING (company_id)
  LEFT JOIN analytics.dol_perm_matches perm USING (company_id)
  LEFT JOIN analytics.sba_ppp_matches ppp USING (company_id)
  LEFT JOIN analytics.msha_violations_matches msha USING (company_id);
ALTER TABLE analytics.company_rollup ADD COLUMN n_total bigint;
UPDATE analytics.company_rollup SET n_total = n_warn_events + n_licenses + n_idfpr_licenses + n_osha_reports
    + n_sec_item205 + n_federal_awards + n_ftc_cases + n_fed_actions;
ALTER TABLE analytics.company_rollup ADD PRIMARY KEY (company_id);

-- The flat dashboard (homelab ?group=0): one row per record, WARN + licence branches.
DROP TABLE IF EXISTS analytics.records;
CREATE TABLE analytics.records AS
SELECT 'warn_event'::text AS record_type, w.company_id, c.company_name, NULL::text AS business_name,
       w.il_location AS address, w.county, w.notice_date AS record_date, w.effective_date,
       w.employees_affected, w.event_type AS detail, NULL::text AS relationship, w.source_url
  FROM analytics.warn_events w JOIN analytics.companies c USING (company_id)
UNION ALL
SELECT 'license', ll.company_id, c.company_name, coalesce(l.doing_business_as_name, l.legal_name),
       concat_ws(', ', l.address, l.city, l.state, l.zip), NULL, l.license_start_date, l.expiration_date,
       NULL, l.license_description, ll.relationship, NULL
  FROM analytics.license_links ll
  JOIN analytics.chicago_business_licenses l USING (account_number, site_number)
  JOIN analytics.companies c ON c.company_id = ll.company_id;
CREATE INDEX ON analytics.records (company_id);

-- Map (homelab /map): WARN filings with a Census point, and licences linked
-- to a company using the City's own coordinates.
DROP TABLE IF EXISTS analytics.map_points;
CREATE TABLE analytics.map_points AS
SELECT 'warn'::text AS layer, w.company_id, c.company_name AS label, w.il_location AS address,
       w.notice_date AS record_date, w.employees_affected, w.lat, w.lon
  FROM analytics.warn_events w JOIN analytics.companies c USING (company_id)
 WHERE w.lat IS NOT NULL
UNION ALL
SELECT 'license', ll.company_id, coalesce(l.doing_business_as_name, l.legal_name),
       concat_ws(', ', l.address, l.city), l.license_start_date, NULL, l.lat, l.lon
  FROM analytics.license_links ll
  JOIN analytics.chicago_business_licenses l USING (account_number, site_number)
 WHERE l.lat IS NOT NULL;

DROP TABLE IF EXISTS analytics.facets;
CREATE TABLE analytics.facets AS
SELECT 'county' AS facet, county AS value, count(*) AS n FROM analytics.warn_events WHERE county IS NOT NULL GROUP BY 2
UNION ALL SELECT 'event_type', event_type, count(*) FROM analytics.warn_events WHERE event_type IS NOT NULL GROUP BY 2
UNION ALL SELECT 'license_description', license_description, count(*) FROM analytics.chicago_business_licenses
          WHERE license_description IS NOT NULL GROUP BY 2
UNION ALL SELECT 'business_activity', business_activity, count(*) FROM analytics.chicago_business_licenses
          WHERE business_activity IS NOT NULL GROUP BY 2
UNION ALL SELECT 'grade', employer_rating, count(*) FROM analytics.company_scores GROUP BY 2;

DROP TABLE IF EXISTS analytics.counts;
CREATE TABLE analytics.counts AS
SELECT 'companies' AS name, count(*) AS n FROM analytics.companies
UNION ALL SELECT 'warn_events', count(*) FROM analytics.warn_events
UNION ALL SELECT 'warn_events_geocoded', count(*) FROM analytics.warn_events WHERE lat IS NOT NULL
UNION ALL SELECT 'licences_total', count(*) FROM analytics.chicago_business_licenses
UNION ALL SELECT 'licences_linked', count(DISTINCT (account_number, site_number)) FROM analytics.license_links
UNION ALL SELECT 'idfpr_total', count(*) FROM analytics.idfpr_licenses
UNION ALL SELECT 'idfpr_linked', count(DISTINCT license_number) FROM analytics.idfpr_links
UNION ALL SELECT 'records_total', count(*) FROM analytics.records
UNION ALL SELECT 'companies_with_ein', count(*) FROM analytics.company_identifiers WHERE ein IS NOT NULL
UNION ALL SELECT 'sec_registrants', count(*) FROM analytics.sec_companies
UNION ALL SELECT 'sec_item205_filings', count(*) FROM analytics.sec_filings WHERE item_205
UNION ALL SELECT 'usaspending_awards', count(*) FROM analytics.usaspending_awards
UNION ALL SELECT 'fdic_institutions', count(*) FROM analytics.fdic_institutions
UNION ALL SELECT 'cms_hospitals', count(*) FROM analytics.cms_hospitals
UNION ALL SELECT 'fmcsa_carriers', count(*) FROM analytics.fmcsa_carriers
UNION ALL SELECT 'cfpb_companies', count(*) FROM analytics.cfpb_complaint_counts
UNION ALL SELECT 'ftc_cases', count(*) FROM analytics.ftc_cases
UNION ALL SELECT 'fed_enforcement_actions', count(*) FROM analytics.fed_enforcement_actions;

-- ------------------------------------------------ context + provenance
DROP TABLE IF EXISTS analytics.bls_series;
CREATE TABLE analytics.bls_series AS
SELECT series_id, label, year, period, period_name, value,
       make_date(year, nullif(regexp_replace(period, '^M', ''), '13')::int, 1) AS period_start
  FROM ingest.bls_series WHERE period ~ '^M(0[1-9]|1[0-2])$';

DROP TABLE IF EXISTS analytics.bls_qcew_cook;
CREATE TABLE analytics.bls_qcew_cook AS SELECT * FROM ingest.bls_qcew_cook;

DROP TABLE IF EXISTS analytics.source_catalog CASCADE;  -- source_freshness (recreated below) depends on it
CREATE TABLE analytics.source_catalog AS SELECT * FROM ingest.source_catalog;

-- Live, not snapshotted: the pipeline tab must show a run that failed after
-- this build. A view over a foreign table runs with the view owner's user
-- mapping, so retool_reader needs no access to jobs_ingest.
DROP VIEW IF EXISTS analytics.ingest_runs;
CREATE VIEW analytics.ingest_runs AS
SELECT id, source, status, started_at, finished_at,
       finished_at - started_at AS duration, rows_written, note, error
  FROM ingest.ingest_runs;

DROP VIEW IF EXISTS analytics.source_freshness;
CREATE VIEW analytics.source_freshness AS
SELECT c.source, c.publisher, c.licence_status,
       last_ok.finished_at AS last_success, last_ok.rows_written,
       last_any.status AS last_status, last_any.started_at AS last_attempt, last_any.error AS last_error
  FROM analytics.source_catalog c
  LEFT JOIN LATERAL (SELECT * FROM ingest.ingest_runs r WHERE r.source = c.source AND r.status = 'ok'
                      ORDER BY r.started_at DESC LIMIT 1) last_ok ON true
  LEFT JOIN LATERAL (SELECT * FROM ingest.ingest_runs r WHERE r.source = c.source
                      ORDER BY r.started_at DESC LIMIT 1) last_any ON true;

DROP TABLE IF EXISTS analytics.build_info;
CREATE TABLE analytics.build_info AS SELECT now() AS built_at;
