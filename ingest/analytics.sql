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

-- -------------------------------------------------------------- scoring
-- Public-only version of the homelab score_weights model.
--   risk       = mean of the conduct signals that are present (0..1)
--   confidence = share of evidence pillars we hold (0..100)
--   goodness   = 100 - (1 - confidence)*40 - risk*60   (homelab common.goodness_nines)
-- Every company is a WARN filer, so every company carries the WARN risk
-- signal: this registry is "employers that filed layoff notices", by design.
DROP TABLE IF EXISTS analytics.score_weights;
CREATE TABLE analytics.score_weights (axis text, measure text, label text, scale_n numeric, explanation text);
INSERT INTO analytics.score_weights VALUES
 ('risk', 'warn', 'WARN notices', 3, 'min(notices / 3, 1)'),
 ('risk', 'osha', 'OSHA severe injury reports', 5, 'min(reports / 5, 1)'),
 ('risk', 'msha', 'MSHA significant & substantial violations', 10, 'min(S&S violations / 10, 1)'),
 ('confidence', 'identity_name', 'Named filer', NULL, 'always held: the WARN notice names the employer'),
 ('confidence', 'warn_data', 'WARN notice on file', NULL, 'always held'),
 ('confidence', 'chicago_license', 'City of Chicago licence', NULL, 'linked by exact normalized name'),
 ('confidence', 'idfpr_license', 'Illinois IDFPR licence', NULL, 'linked by exact normalized name'),
 ('confidence', 'located', 'Geocoded Illinois address', NULL, 'Census geocoder matched a WARN street address'),
 ('confidence', 'hiring_evidence', 'Federal hiring filings (LCA/PERM)', NULL, 'certified H-1B LCA or PERM on file');

DROP TABLE IF EXISTS analytics.company_scores;
CREATE TABLE analytics.company_scores AS
WITH s AS (
    SELECT c.company_id,
           least(c.n_warn_events / 3.0, 1)                                                  AS r_warn,
           (SELECT least(count(*) / 5.0, 1) FROM analytics.osha_severe_injury_reports o
             WHERE o.company_id = c.company_id HAVING count(*) > 0)                         AS r_osha,
           (SELECT least(m.sig_sub_count / 10.0, 1) FROM analytics.msha_violations_matches m
             WHERE m.company_id = c.company_id AND m.sig_sub_count > 0)                     AS r_msha,
           EXISTS (SELECT 1 FROM analytics.license_links l WHERE l.company_id = c.company_id) AS p_chicago,
           EXISTS (SELECT 1 FROM analytics.idfpr_links l WHERE l.company_id = c.company_id)   AS p_idfpr,
           EXISTS (SELECT 1 FROM analytics.warn_events w
                    WHERE w.company_id = c.company_id AND w.lat IS NOT NULL)                  AS p_located,
           EXISTS (SELECT 1 FROM analytics.dol_lca_matches d WHERE d.company_id = c.company_id)
        OR EXISTS (SELECT 1 FROM analytics.dol_perm_matches d WHERE d.company_id = c.company_id) AS p_hiring
      FROM analytics.companies c
), r AS (
    SELECT s.*,
           (SELECT avg(x) FROM unnest(ARRAY[r_warn, r_osha, r_msha]) x)                    AS risk_score,
           100.0 * (2 + p_chicago::int + p_idfpr::int + p_located::int + p_hiring::int) / 6 AS confidence_score
      FROM s
)
SELECT company_id, risk_score, confidence_score,
       greatest(0, 100 - (1 - confidence_score / 100) * 40 - coalesce(risk_score, 0) * 60) AS goodness_percent,
       jsonb_build_object('warn', r_warn, 'osha', r_osha, 'msha', r_msha)                  AS risk_breakdown,
       jsonb_build_object('identity_name', true, 'warn_data', true, 'chicago_license', p_chicago,
                          'idfpr_license', p_idfpr, 'located', p_located, 'hiring_evidence', p_hiring)
                                                                                           AS confidence_breakdown
  FROM r;
ALTER TABLE analytics.company_scores ADD COLUMN goodness_grade text;
UPDATE analytics.company_scores SET goodness_grade = CASE
    WHEN goodness_percent >= 97 THEN 'A+' WHEN goodness_percent >= 90 THEN 'A'
    WHEN goodness_percent >= 80 THEN 'B'  WHEN goodness_percent >= 70 THEN 'C'
    WHEN goodness_percent >= 60 THEN 'D'  ELSE 'F' END;
ALTER TABLE analytics.company_scores ADD PRIMARY KEY (company_id);

-- -------------------------------------------------------- serving layer
-- The grouped dashboard (homelab serving_company_rollup), one row per company.
DROP TABLE IF EXISTS analytics.company_rollup;
CREATE TABLE analytics.company_rollup AS
SELECT c.company_id, c.company_name, c.naics, c.counties,
       s.risk_score, s.confidence_score, s.goodness_percent, s.goodness_grade,
       c.n_warn_events, c.employees_affected_total, c.first_notice_date, c.latest_notice_date,
       (SELECT count(*) FROM analytics.license_links l WHERE l.company_id = c.company_id)          AS n_licenses,
       (SELECT count(*) FROM analytics.idfpr_links l WHERE l.company_id = c.company_id)            AS n_idfpr_licenses,
       (SELECT count(*) FROM analytics.osha_severe_injury_reports o WHERE o.company_id = c.company_id) AS n_osha_reports,
       lca.certified_lca_count, perm.certified_perm_count,
       greatest(lca.max_annual_wage, perm.max_annual_wage)                                         AS max_annual_wage_filed,
       ppp.total_current_approval                                                                  AS ppp_approved,
       msha.sig_sub_count                                                                          AS msha_sig_sub
  FROM analytics.companies c
  JOIN analytics.company_scores s USING (company_id)
  LEFT JOIN analytics.dol_lca_matches lca USING (company_id)
  LEFT JOIN analytics.dol_perm_matches perm USING (company_id)
  LEFT JOIN analytics.sba_ppp_matches ppp USING (company_id)
  LEFT JOIN analytics.msha_violations_matches msha USING (company_id);
ALTER TABLE analytics.company_rollup ADD COLUMN n_total bigint;
UPDATE analytics.company_rollup SET n_total = n_warn_events + n_licenses + n_idfpr_licenses + n_osha_reports;
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
UNION ALL SELECT 'grade', goodness_grade, count(*) FROM analytics.company_scores GROUP BY 2;

DROP TABLE IF EXISTS analytics.counts;
CREATE TABLE analytics.counts AS
SELECT 'companies' AS name, count(*) AS n FROM analytics.companies
UNION ALL SELECT 'warn_events', count(*) FROM analytics.warn_events
UNION ALL SELECT 'warn_events_geocoded', count(*) FROM analytics.warn_events WHERE lat IS NOT NULL
UNION ALL SELECT 'licences_total', count(*) FROM analytics.chicago_business_licenses
UNION ALL SELECT 'licences_linked', count(DISTINCT (account_number, site_number)) FROM analytics.license_links
UNION ALL SELECT 'idfpr_total', count(*) FROM analytics.idfpr_licenses
UNION ALL SELECT 'idfpr_linked', count(DISTINCT license_number) FROM analytics.idfpr_links
UNION ALL SELECT 'records_total', count(*) FROM analytics.records;

-- ------------------------------------------------ context + provenance
DROP TABLE IF EXISTS analytics.bls_series;
CREATE TABLE analytics.bls_series AS
SELECT series_id, label, year, period, period_name, value,
       make_date(year, nullif(regexp_replace(period, '^M', ''), '13')::int, 1) AS period_start
  FROM ingest.bls_series WHERE period ~ '^M(0[1-9]|1[0-2])$';

DROP TABLE IF EXISTS analytics.bls_qcew_cook;
CREATE TABLE analytics.bls_qcew_cook AS SELECT * FROM ingest.bls_qcew_cook;

DROP TABLE IF EXISTS analytics.source_catalog;
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
