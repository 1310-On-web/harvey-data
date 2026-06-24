-- Harvey Usage Dashboard — Supabase schema
-- Run in Supabase SQL Editor after creating your project.

-- HR master data (refreshed monthly)
CREATE TABLE IF NOT EXISTS hr_employees (
    email TEXT PRIMARY KEY,
    workforce_id TEXT,
    workforce_name TEXT,
    location TEXT,
    date_of_joining DATE,
    designation TEXT,
    team TEXT,
    practice_function TEXT,
    reporting_manager_name TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enriched usage events (daily sync; file_ids excluded)
CREATE TABLE IF NOT EXISTS usage_events (
    unique_usage_id TEXT PRIMARY KEY,
    utc_time TIMESTAMPTZ,
    usage_date DATE,
    usage_hour SMALLINT,
    user_email TEXT NOT NULL,
    access_point TEXT,
    action TEXT,
    product_surface_area TEXT,
    workflow_name TEXT,
    source TEXT,
    subsurface TEXT,
    cm_id TEXT,
    parent_thread_id TEXT,
    space_name TEXT,
    playbook_name TEXT,
    vault_project_name TEXT,
    review_table_name TEXT,
    file_count INTEGER DEFAULT 0,
    workforce_id TEXT,
    workforce_name TEXT,
    location TEXT,
    date_of_joining DATE,
    designation TEXT,
    team TEXT,
    practice_function TEXT,
    email TEXT,
    reporting_manager_name TEXT,
    synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Single-row sync status for dashboard banner
CREATE TABLE IF NOT EXISTS sync_metadata (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    last_sync TIMESTAMPTZ,
    min_date DATE,
    max_date DATE,
    row_count BIGINT DEFAULT 0,
    last_sync_rows INTEGER DEFAULT 0
);

INSERT INTO sync_metadata (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Indexes for filter + chart queries
CREATE INDEX IF NOT EXISTS idx_usage_events_usage_date ON usage_events (usage_date);
CREATE INDEX IF NOT EXISTS idx_usage_events_user_email ON usage_events (user_email);
CREATE INDEX IF NOT EXISTS idx_usage_events_practice ON usage_events (practice_function);
CREATE INDEX IF NOT EXISTS idx_usage_events_location ON usage_events (location);
CREATE INDEX IF NOT EXISTS idx_usage_events_access ON usage_events (access_point);
CREATE INDEX IF NOT EXISTS idx_usage_events_designation ON usage_events (designation);
CREATE INDEX IF NOT EXISTS idx_usage_events_utc_time ON usage_events (utc_time DESC);

-- Row Level Security
ALTER TABLE hr_employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_metadata ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read hr_employees"
    ON hr_employees FOR SELECT TO authenticated USING (true);

CREATE POLICY "Authenticated users can read usage_events"
    ON usage_events FOR SELECT TO authenticated USING (true);

CREATE POLICY "Authenticated users can read sync_metadata"
    ON sync_metadata FOR SELECT TO authenticated USING (true);

-- Service role (GitHub Actions) bypasses RLS automatically.

GRANT SELECT ON hr_employees TO authenticated;
GRANT SELECT ON usage_events TO authenticated;
GRANT SELECT ON sync_metadata TO authenticated;
