-- Runs against the public-data Flexible Server as its admin. Idempotent:
-- every run re-asserts roles, passwords (rotation = new KV value + rerun),
-- ownership and grants.
--
--   ingest_loader      owns jobs_ingest.public; the only writer of raw rows
--   analytics_builder  owns jobs_analytics.analytics; builds serving tables
--   analytics_fdw      read-only on jobs_ingest; what postgres_fdw logs in as
--   retool_reader      SELECT on jobs_analytics.analytics ONLY; what Retool's
--                      resource uses. The publication filters are applied at
--                      ingest AND analytics is the only published layer, so
--                      Retool never sees raw rows.
-- No role but the admin has CREATEDB/CREATEROLE; none can write the other's DB.

SELECT format('CREATE ROLE %I LOGIN', r)
FROM unnest(ARRAY['ingest_loader','analytics_builder','analytics_fdw','retool_reader']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec

ALTER ROLE ingest_loader     WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'ingest_loader_pw';
ALTER ROLE analytics_builder WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'analytics_builder_pw';
ALTER ROLE analytics_fdw     WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'analytics_fdw_pw';
ALTER ROLE retool_reader     WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'retool_reader_pw';
-- Retool apps are read-only by construction, and a runaway query can't pin the server.
ALTER ROLE retool_reader SET default_transaction_read_only = on;
ALTER ROLE retool_reader SET statement_timeout = '30s';

GRANT ingest_loader, analytics_builder TO :"admin";

REVOKE ALL ON DATABASE jobs_ingest, jobs_analytics FROM PUBLIC;
GRANT CONNECT ON DATABASE jobs_ingest TO ingest_loader, analytics_fdw;
REVOKE CONNECT ON DATABASE jobs_ingest FROM retool_reader;
GRANT CONNECT ON DATABASE jobs_analytics TO analytics_builder, retool_reader;

-- ---------------------------------------------------------------- jobs_ingest
\connect jobs_ingest
CREATE EXTENSION IF NOT EXISTS pg_trgm;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER SCHEMA public OWNER TO ingest_loader;
GRANT USAGE ON SCHEMA public TO analytics_fdw;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analytics_fdw;
ALTER DEFAULT PRIVILEGES FOR ROLE ingest_loader IN SCHEMA public
  GRANT SELECT ON TABLES TO analytics_fdw;
-- Undo the earlier grant to retool_reader (this script used to give it raw access).
REVOKE ALL ON SCHEMA public FROM retool_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM retool_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE ingest_loader IN SCHEMA public
  REVOKE SELECT ON TABLES FROM retool_reader;

-- ------------------------------------------------------------- jobs_analytics
\connect jobs_analytics
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA IF NOT EXISTS analytics AUTHORIZATION analytics_builder;
CREATE SCHEMA IF NOT EXISTS ingest AUTHORIZATION analytics_builder;   -- foreign tables only
GRANT USAGE ON SCHEMA analytics TO retool_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO retool_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE analytics_builder IN SCHEMA analytics
  GRANT SELECT ON TABLES TO retool_reader;

-- Ingest is reachable from analytics only through this read-only mapping.
SELECT format('CREATE SERVER ingest_srv FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, dbname %L, sslmode %L)',
              :'data_host', 'jobs_ingest', 'require')
WHERE NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'ingest_srv') \gexec
GRANT USAGE ON FOREIGN SERVER ingest_srv TO analytics_builder;
DROP USER MAPPING IF EXISTS FOR analytics_builder SERVER ingest_srv;
CREATE USER MAPPING FOR analytics_builder SERVER ingest_srv
  OPTIONS (user 'analytics_fdw', password :'analytics_fdw_pw');
