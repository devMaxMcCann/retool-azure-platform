-- Runs against Retool's own Flexible Server as its admin. Idempotent.
-- Creates Infisical's login role and hands it the `infisical` database
-- (the database itself is created by Terraform).

SELECT 'CREATE ROLE infisical LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'infisical') \gexec
ALTER ROLE infisical WITH LOGIN PASSWORD :'infisical_pw';

-- PG16: the creating admin needs membership to transfer ownership.
GRANT infisical TO :"admin";
ALTER DATABASE infisical OWNER TO infisical;
REVOKE ALL ON DATABASE infisical FROM PUBLIC;

-- Azure Flexible Server: `public` in a database the admin created is owned by
-- the admin (not pg_database_owner as in stock PG15+), so owning the database
-- alone leaves Infisical unable to create its tables ("permission denied for
-- schema public" at boot migration).
\connect infisical
ALTER SCHEMA public OWNER TO infisical;
