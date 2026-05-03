-- Idempotent CREATE DATABASE for the sms-gw module.
-- Run by the sms-gw-db-init one-shot service against the postgres
-- container before sms-gw-service starts. Ent inside sms-gw owns the
-- schema; we only need the empty database to exist.
SELECT 'CREATE DATABASE sms_gw'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'sms_gw')
\gexec
