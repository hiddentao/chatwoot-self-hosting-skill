-- Prepares the Chatwoot database. Run as a privileged role, connected to the
-- Chatwoot database itself, before the first migration.
--
--   psql -v approle=chatwoot -v ON_ERROR_STOP=1 -f db-init.sql \
--        'host=... port=... dbname=chatwoot user=<admin> sslmode=require'
--
-- Dropped into a container's initdb directory it also runs unattended, where
-- the role defaults to chatwoot and ownership is already correct.
--
-- Run it from inside the network that reaches the database. A managed cluster
-- on a private network is not reachable from your laptop.

\if :{?approle}
\else
\set approle chatwoot
\endif

-- Chatwoot's schema enables these extensions itself, but only a privileged role
-- may create them. Creating them here first turns that step into a no-op.
-- Five are needed, not one.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS plpgsql;
CREATE EXTENSION IF NOT EXISTS vector;

-- The application role owns its database. On Postgres 15 and later the public
-- schema belongs to the database owner, which lets migrations create tables.
-- When the admin role may not hand over ownership, explicit grants give the
-- application role the same ability to create and change objects.
SELECT set_config('chatwoot.approle', :'approle', false);

DO $$
DECLARE
  approle text := current_setting('chatwoot.approle');
BEGIN
  EXECUTE format('ALTER DATABASE %I OWNER TO %I', current_database(), approle);
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'ownership transfer refused, granting privileges instead';
  EXECUTE format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', current_database(), approle);
  EXECUTE format('GRANT ALL ON SCHEMA public TO %I', approle);
END
$$;

SELECT pg_catalog.pg_get_userbyid(datdba) AS database_owner
FROM pg_database WHERE datname = current_database();

SELECT extname, extversion FROM pg_extension ORDER BY extname;
