-- Pyroscope SOR schema — PostgreSQL
-- Run once against the target database before deploying SOR services.

-- Performance baselines: approved thresholds per service/profile/function
CREATE TABLE IF NOT EXISTS performance_baseline (
    id              SERIAL PRIMARY KEY,
    app_name        VARCHAR(255)  NOT NULL,
    profile_type    VARCHAR(50)   NOT NULL,
    function_name   VARCHAR(1024) NOT NULL,
    max_self_percent DOUBLE PRECISION NOT NULL,
    severity        VARCHAR(20)   NOT NULL DEFAULT 'warning',
    created_by      VARCHAR(255),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    UNIQUE(app_name, profile_type, function_name)
);

-- Triage history: audit trail of every triage assessment
CREATE TABLE IF NOT EXISTS triage_history (
    id              SERIAL PRIMARY KEY,
    app_name        VARCHAR(255) NOT NULL,
    profile_types   VARCHAR(255) NOT NULL,
    diagnosis       VARCHAR(100) NOT NULL,
    severity        VARCHAR(20)  NOT NULL,
    top_functions   JSONB,
    recommendation  TEXT,
    requested_by    VARCHAR(255),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_triage_history_app_time
    ON triage_history(app_name, created_at DESC);

-- Service registry: metadata about monitored services
CREATE TABLE IF NOT EXISTS service_registry (
    id                   SERIAL PRIMARY KEY,
    app_name             VARCHAR(255) UNIQUE NOT NULL,
    team_owner           VARCHAR(255),
    tier                 VARCHAR(20)  NOT NULL DEFAULT 'standard',
    environment          VARCHAR(50),
    notification_channel VARCHAR(255),
    pyroscope_labels     JSONB        NOT NULL DEFAULT '{}',
    metadata             JSONB        NOT NULL DEFAULT '{}',
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Alert rules: profiling threshold alerts per service
CREATE TABLE IF NOT EXISTS alert_rule (
    id                   SERIAL PRIMARY KEY,
    app_name             VARCHAR(255)  NOT NULL,
    profile_type         VARCHAR(50)   NOT NULL,
    function_pattern     VARCHAR(1024),
    threshold_percent    DOUBLE PRECISION NOT NULL,
    severity             VARCHAR(20)   NOT NULL DEFAULT 'warning',
    notification_channel VARCHAR(255),
    enabled              BOOLEAN       NOT NULL DEFAULT TRUE,
    created_by           VARCHAR(255),
    created_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_alert_rule_app
    ON alert_rule(app_name, enabled);
