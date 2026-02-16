-- TimescaleDB Setup for Go-Tangra Platform
-- This script enables TimescaleDB analytics features on audit log tables.
-- Run after initial schema migration. Safe to re-run (uses IF NOT EXISTS / OR REPLACE).
--
-- NOTE: We intentionally do NOT convert Ent-managed tables to hypertables.
-- Hypertables require ALL unique constraints to include the partition column,
-- which is incompatible with Ent's auto-migration (PK on id, unique indexes).
-- Instead, we use time_bucket() directly on regular tables and create
-- materialized views for fast aggregated analytics queries.

-- Enable TimescaleDB extension (needed for time_bucket and other analytics functions)
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- =============================================================================
-- Performance Indexes for Time-Series Queries
-- These accelerate time_bucket() queries on audit tables.
-- =============================================================================

-- API Audit Logs: time-range queries
CREATE INDEX IF NOT EXISTS idx_sys_api_audit_logs_created_at_brin
    ON sys_api_audit_logs USING BRIN (created_at)
    WITH (pages_per_range = 32);

-- API Audit Logs: tenant + time range (most common query pattern)
CREATE INDEX IF NOT EXISTS idx_sys_api_audit_logs_tenant_created
    ON sys_api_audit_logs (tenant_id, created_at DESC);

-- Login Audit Logs: time-range queries
CREATE INDEX IF NOT EXISTS idx_sys_login_audit_logs_created_at_brin
    ON sys_login_audit_logs USING BRIN (created_at)
    WITH (pages_per_range = 32);

-- Login Audit Logs: tenant + time range
CREATE INDEX IF NOT EXISTS idx_sys_login_audit_logs_tenant_created
    ON sys_login_audit_logs (tenant_id, created_at DESC);

-- Login Audit Logs: status + time (for failed login trends)
CREATE INDEX IF NOT EXISTS idx_sys_login_audit_logs_status_created
    ON sys_login_audit_logs (status, created_at DESC);

-- Operation Audit Logs: time-range queries
CREATE INDEX IF NOT EXISTS idx_sys_operation_audit_logs_created_at_brin
    ON sys_operation_audit_logs USING BRIN (created_at)
    WITH (pages_per_range = 32);

-- Operation Audit Logs: tenant + time range
CREATE INDEX IF NOT EXISTS idx_sys_operation_audit_logs_tenant_created
    ON sys_operation_audit_logs (tenant_id, created_at DESC);

-- =============================================================================
-- Materialized Views for Analytics
-- Provide fast pre-aggregated data for dashboard widgets.
-- Refresh via pg_cron or application-level scheduler.
-- =============================================================================

-- API Request Volume + Latency (hourly buckets)
CREATE MATERIALIZED VIEW IF NOT EXISTS api_stats_hourly AS
SELECT
    time_bucket('1 hour', created_at) AS bucket,
    tenant_id,
    COALESCE(api_module, 'unknown') AS api_module,
    COUNT(*) AS total_requests,
    COUNT(*) FILTER (WHERE success = true) AS success_count,
    COUNT(*) FILTER (WHERE success = false) AS error_count,
    AVG(latency_ms)::double precision AS avg_latency_ms,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY latency_ms)::double precision AS p50_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY latency_ms)::double precision AS p95_latency_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY latency_ms)::double precision AS p99_latency_ms,
    COUNT(DISTINCT user_id) AS unique_users
FROM sys_api_audit_logs
GROUP BY bucket, tenant_id, api_module
WITH NO DATA;

-- API Request Volume + Latency (daily buckets)
CREATE MATERIALIZED VIEW IF NOT EXISTS api_stats_daily AS
SELECT
    time_bucket('1 day', created_at) AS bucket,
    tenant_id,
    COALESCE(api_module, 'unknown') AS api_module,
    COUNT(*) AS total_requests,
    COUNT(*) FILTER (WHERE success = true) AS success_count,
    COUNT(*) FILTER (WHERE success = false) AS error_count,
    AVG(latency_ms)::double precision AS avg_latency_ms,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY latency_ms)::double precision AS p50_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY latency_ms)::double precision AS p95_latency_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY latency_ms)::double precision AS p99_latency_ms,
    COUNT(DISTINCT user_id) AS unique_users
FROM sys_api_audit_logs
GROUP BY bucket, tenant_id, api_module
WITH NO DATA;

-- Login Activity (hourly buckets)
CREATE MATERIALIZED VIEW IF NOT EXISTS login_stats_hourly AS
SELECT
    time_bucket('1 hour', created_at) AS bucket,
    tenant_id,
    COUNT(*) AS total_attempts,
    COUNT(*) FILTER (WHERE status = 'SUCCESS') AS success_count,
    COUNT(*) FILTER (WHERE status = 'FAILED') AS failed_count,
    COUNT(*) FILTER (WHERE status = 'LOCKED') AS locked_count,
    AVG(risk_score)::double precision AS avg_risk_score,
    COUNT(DISTINCT user_id) AS unique_users,
    COUNT(DISTINCT ip_address) AS unique_ips
FROM sys_login_audit_logs
GROUP BY bucket, tenant_id
WITH NO DATA;

-- Login Activity (daily buckets)
CREATE MATERIALIZED VIEW IF NOT EXISTS login_stats_daily AS
SELECT
    time_bucket('1 day', created_at) AS bucket,
    tenant_id,
    COUNT(*) AS total_attempts,
    COUNT(*) FILTER (WHERE status = 'SUCCESS') AS success_count,
    COUNT(*) FILTER (WHERE status = 'FAILED') AS failed_count,
    COUNT(*) FILTER (WHERE status = 'LOCKED') AS locked_count,
    AVG(risk_score)::double precision AS avg_risk_score,
    COUNT(DISTINCT user_id) AS unique_users,
    COUNT(DISTINCT ip_address) AS unique_ips
FROM sys_login_audit_logs
GROUP BY bucket, tenant_id
WITH NO DATA;

-- Indexes on materialized views for fast lookups
CREATE UNIQUE INDEX IF NOT EXISTS idx_api_stats_hourly_pk
    ON api_stats_hourly (bucket, tenant_id, api_module);

CREATE UNIQUE INDEX IF NOT EXISTS idx_api_stats_daily_pk
    ON api_stats_daily (bucket, tenant_id, api_module);

CREATE UNIQUE INDEX IF NOT EXISTS idx_login_stats_hourly_pk
    ON login_stats_hourly (bucket, tenant_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_login_stats_daily_pk
    ON login_stats_daily (bucket, tenant_id);

-- =============================================================================
-- Initial Refresh
-- Populate materialized views with existing data.
-- =============================================================================

REFRESH MATERIALIZED VIEW api_stats_hourly;
REFRESH MATERIALIZED VIEW api_stats_daily;
REFRESH MATERIALIZED VIEW login_stats_hourly;
REFRESH MATERIALIZED VIEW login_stats_daily;
