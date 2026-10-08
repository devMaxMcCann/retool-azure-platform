-- jobs_ingest: raw public rows, as published, after the publication filters
-- in data/tables.yaml. Owned by ingest_loader; read by analytics through
-- postgres_fdw (as analytics_fdw). Retool cannot connect here.
--
-- Every table carries normalized_name (common.normalize) so analytics can
-- match on equality in SQL. Applied by `python -m pipeline schema`; idempotent.

CREATE TABLE IF NOT EXISTS ingest_runs (
    id            bigserial PRIMARY KEY,
    source        text        NOT NULL,
    status        text        NOT NULL CHECK (status IN ('running','ok','failed','blocked')),
    started_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at   timestamptz,
    rows_written  bigint,
    note          text,
    error         text
);
CREATE INDEX IF NOT EXISTS ingest_runs_source_started ON ingest_runs (source, started_at DESC);

-- Where each source comes from and why publishing it is OK. Seeded by the
-- loaders themselves (sources.py), shown verbatim on the dashboard.
CREATE TABLE IF NOT EXISTS source_catalog (
    source        text PRIMARY KEY,
    publisher     text NOT NULL,
    url           text NOT NULL,
    licence       text NOT NULL,
    licence_url   text,
    licence_status text NOT NULL,        -- verified | unverified | owner_decision
    attribution   text,                  -- text the dashboard must display, if any
    filters       text                   -- what the publication filters removed
);

-- ------------------------------------------------------------ Illinois WARN
CREATE TABLE IF NOT EXISTS warn_reports (
    source_url  text PRIMARY KEY,
    rows        int NOT NULL,
    fetched_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS warn_events (
    source_url            text NOT NULL REFERENCES warn_reports (source_url) ON DELETE CASCADE,
    row_no                int  NOT NULL,
    company_name          text NOT NULL,
    normalized_name       text NOT NULL,
    company_id            bigint NOT NULL,          -- synthetic, from the filer name
    company_address       text,
    company_city_state_zip text,
    reported_state        text,
    county                text,
    il_location           text,
    il_location_precision text,                     -- street | county | NULL
    notice_date           date,
    effective_date        date,
    employees_affected    int,
    event_type            text,
    layoff_type           text,
    naics                 text,
    PRIMARY KEY (source_url, row_no)
);
CREATE INDEX IF NOT EXISTS warn_events_norm ON warn_events (normalized_name);

-- Census geocoder results for WARN street addresses (no Cook County).
CREATE TABLE IF NOT EXISTS warn_geocodes (
    address_key     text PRIMARY KEY,               -- the exact one-line address sent
    status          text NOT NULL,                  -- matched | no_match | error
    lat             double precision,
    lon             double precision,
    matched_address text,
    geocoded_at     timestamptz NOT NULL DEFAULT now()
);

-- --------------------------------------------------- City of Chicago licences
CREATE TABLE IF NOT EXISTS chicago_business_licenses (
    account_number         text NOT NULL,
    site_number            text NOT NULL,
    legal_name             text,
    doing_business_as_name text,
    normalized_legal       text NOT NULL,
    normalized_dba         text NOT NULL,
    address                text,
    city                   text,
    state                  text,
    zip                    text,
    license_description    text,
    business_activity      text,
    license_status         text,
    license_start_date     date,
    expiration_date        date,
    date_issued            date,
    city_lat               double precision,
    city_lon               double precision,
    PRIMARY KEY (account_number, site_number)
);
CREATE INDEX IF NOT EXISTS cbl_norm_legal ON chicago_business_licenses (normalized_legal);
CREATE INDEX IF NOT EXISTS cbl_norm_dba ON chicago_business_licenses (normalized_dba);

-- ------------------------------------------------------- IDFPR (Illinois)
CREATE TABLE IF NOT EXISTS idfpr_licenses (
    license_number      text PRIMARY KEY,
    license_type        text,
    description         text,
    business_name       text,
    businessdba         text,
    normalized_name     text NOT NULL,
    normalized_dba      text NOT NULL,
    license_status      text,
    original_issue_date date,
    effective_date      date,
    expiration_date     date,
    city                text,
    state               text,
    zip                 text,
    county              text,
    ever_disciplined    boolean
);
CREATE INDEX IF NOT EXISTS idfpr_norm ON idfpr_licenses (normalized_name);
CREATE INDEX IF NOT EXISTS idfpr_norm_dba ON idfpr_licenses (normalized_dba);

-- ------------------------------------------------------------------- BLS
CREATE TABLE IF NOT EXISTS bls_series (
    series_id   text NOT NULL,
    label       text NOT NULL,
    year        int  NOT NULL,
    period      text NOT NULL,
    period_name text,
    value       numeric,
    PRIMARY KEY (series_id, year, period)
);

CREATE TABLE IF NOT EXISTS bls_qcew_cook (
    year               int NOT NULL,
    qtr                int NOT NULL,
    own_code           text NOT NULL,
    industry_code      text NOT NULL,
    qtrly_estabs       bigint,
    month3_emplvl      bigint,
    total_qtrly_wages  numeric,
    avg_wkly_wage      numeric,
    PRIMARY KEY (year, qtr, own_code, industry_code)
);

-- ------------------------------------------- bulk federal employer aggregates
-- One row per normalized employer, entity names only (tables.yaml filter).
CREATE TABLE IF NOT EXISTS dol_lca_employers (
    normalized_name       text PRIMARY KEY,
    employer_name         text NOT NULL,
    certified_lca_count   int  NOT NULL,
    latest_job_title      text,
    latest_received_date  date,
    min_annual_wage       numeric,
    max_annual_wage       numeric,
    fy_quarter            text NOT NULL
);

CREATE TABLE IF NOT EXISTS dol_perm_employers (
    normalized_name        text PRIMARY KEY,
    employer_name          text NOT NULL,
    certified_perm_count   int  NOT NULL,
    latest_job_title       text,
    latest_received_date   date,
    latest_worksite_city   text,
    latest_worksite_state  text,
    min_annual_wage        numeric,
    max_annual_wage        numeric,
    fiscal_year            text NOT NULL
);

CREATE TABLE IF NOT EXISTS msha_violations_employers (
    normalized_name        text PRIMARY KEY,
    violator_name          text NOT NULL,
    violation_count        int  NOT NULL,
    sig_sub_count          int  NOT NULL,
    total_proposed_penalty numeric,
    total_amount_paid      numeric,
    distinct_mine_count    int,
    latest_violation_date  date
);

CREATE TABLE IF NOT EXISTS sba_ppp_employers (
    normalized_name        text PRIMARY KEY,
    borrower_name          text NOT NULL,
    loan_count             int  NOT NULL,
    total_current_approval numeric,
    total_forgiveness      numeric,
    total_jobs_reported    bigint,
    latest_date_approved   date,
    latest_loan_status     text,
    latest_naics_code      text,
    latest_business_type   text,
    borrower_state         text
);

-- OSHA severe injury reports: entity employers only, narrative never stored.
CREATE TABLE IF NOT EXISTS osha_severe_injury_reports (
    report_id          text PRIMARY KEY,
    employer           text NOT NULL,
    normalized_name    text NOT NULL,
    event_date         date,
    city               text,
    state              text,
    naics              text,
    hospitalized_count int,
    amputation_count   int,
    loss_of_eye_count  int,
    nature_title       text,
    event_title        text
);
CREATE INDEX IF NOT EXISTS osha_norm ON osha_severe_injury_reports (normalized_name);
