-- Databases (owned by default 'postgres' user). Airflow and MLflow get their
-- own databases; features/incidents live in the primary 'ai' DB.
CREATE DATABASE airflow;
CREATE DATABASE mlflow;
CREATE DATABASE ai;

\connect ai

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS function_features (
  ts           TIMESTAMPTZ NOT NULL,
  service      TEXT NOT NULL,
  profile_type TEXT NOT NULL,
  function     TEXT NOT NULL,
  self_value   DOUBLE PRECISION NOT NULL,
  total_value  DOUBLE PRECISION NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_function_features_svc_pt_ts
  ON function_features (service, profile_type, ts DESC);
CREATE INDEX IF NOT EXISTS idx_function_features_ts ON function_features (ts DESC);

CREATE TABLE IF NOT EXISTS integration_series (
  ts           TIMESTAMPTZ NOT NULL,
  service      TEXT NOT NULL,
  integration  TEXT NOT NULL,
  profile_type TEXT NOT NULL,
  value        DOUBLE PRECISION NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_integration_series_svc_int_ts
  ON integration_series (service, integration, ts DESC);

CREATE TABLE IF NOT EXISTS fingerprints (
  ts           TIMESTAMPTZ NOT NULL,
  service      TEXT NOT NULL,
  profile_type TEXT NOT NULL,
  vector       VECTOR(128) NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_fingerprints_vec
  ON fingerprints USING ivfflat (vector vector_cosine_ops) WITH (lists = 50);

CREATE TABLE IF NOT EXISTS incidents (
  id             UUID PRIMARY KEY,
  kind           TEXT NOT NULL,
  service        TEXT NOT NULL,
  start_ts       TIMESTAMPTZ NOT NULL,
  end_ts         TIMESTAMPTZ,
  notes          TEXT,
  postmortem_md  TEXT,
  fingerprint    VECTOR(128)
);
CREATE INDEX IF NOT EXISTS idx_incidents_kind_ts ON incidents (kind, start_ts DESC);
CREATE INDEX IF NOT EXISTS idx_incidents_fp
  ON incidents USING ivfflat (fingerprint vector_cosine_ops) WITH (lists = 50);

CREATE TABLE IF NOT EXISTS anomalies (
  ts           TIMESTAMPTZ NOT NULL,
  service      TEXT,
  metric       TEXT,
  score        DOUBLE PRECISION,
  window_start TIMESTAMPTZ,
  window_end   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_anomalies_ts ON anomalies (ts DESC);

CREATE TABLE IF NOT EXISTS regressions (
  detected_at  TIMESTAMPTZ NOT NULL,
  service      TEXT,
  function     TEXT,
  profile_type TEXT,
  before_value DOUBLE PRECISION,
  after_value  DOUBLE PRECISION,
  shift        DOUBLE PRECISION,
  llm_summary  TEXT
);
CREATE INDEX IF NOT EXISTS idx_regressions_svc_ts ON regressions (service, detected_at DESC);

-- Retention helpers (invoked by daily Airflow DAG)
CREATE OR REPLACE FUNCTION prune_old_data() RETURNS void AS $$
BEGIN
  DELETE FROM function_features   WHERE ts < now() - INTERVAL '30 days';
  DELETE FROM integration_series  WHERE ts < now() - INTERVAL '30 days';
  DELETE FROM fingerprints        WHERE ts < now() - INTERVAL '30 days';
  DELETE FROM anomalies           WHERE ts < now() - INTERVAL '90 days';
  DELETE FROM regressions         WHERE detected_at < now() - INTERVAL '90 days';
  DELETE FROM incidents           WHERE start_ts < now() - INTERVAL '90 days';
END;
$$ LANGUAGE plpgsql;
