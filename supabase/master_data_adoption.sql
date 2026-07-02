-- Master-data adoption metrics
-- Run in Supabase SQL Editor after practice_multiselect_filters.sql

-- Extend hr_employees for Master-data.xlsx columns
ALTER TABLE hr_employees ADD COLUMN IF NOT EXISTS harvey_status TEXT;
ALTER TABLE hr_employees ADD COLUMN IF NOT EXISTS access_state TEXT;
ALTER TABLE hr_employees ADD COLUMN IF NOT EXISTS phase TEXT;
ALTER TABLE hr_employees ADD COLUMN IF NOT EXISTS low_usage_warning TEXT;
ALTER TABLE hr_employees ADD COLUMN IF NOT EXISTS date_added DATE;
ALTER TABLE hr_employees ADD COLUMN IF NOT EXISTS training_attendance TEXT;
ALTER TABLE hr_employees ADD COLUMN IF NOT EXISTS cohort_training_attendance TEXT;
ALTER TABLE hr_employees ADD COLUMN IF NOT EXISTS notes TEXT;

CREATE INDEX IF NOT EXISTS idx_hr_access_state ON hr_employees (access_state);
CREATE INDEX IF NOT EXISTS idx_hr_team ON hr_employees (team);
CREATE INDEX IF NOT EXISTS idx_hr_practice ON hr_employees (practice_function);

ALTER TABLE dashboard_cache ADD COLUMN IF NOT EXISTS adoption_bundle JSONB;

-- ── get_adoption_bundle ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_adoption_bundle(
    p_practices TEXT[] DEFAULT NULL,
    p_teams TEXT[] DEFAULT NULL,
    p_locations TEXT[] DEFAULT NULL,
    p_designations TEXT[] DEFAULT NULL,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    result JSON;
    cached JSON;
BEGIN
    PERFORM require_authenticated();

    IF (p_practices IS NULL OR cardinality(p_practices) = 0)
       AND (p_teams IS NULL OR cardinality(p_teams) = 0)
       AND (p_locations IS NULL OR cardinality(p_locations) = 0)
       AND (p_designations IS NULL OR cardinality(p_designations) = 0)
       AND p_start_date IS NULL AND p_end_date IS NULL THEN
        SELECT adoption_bundle INTO cached FROM dashboard_cache WHERE id = 1;
        IF cached IS NOT NULL THEN RETURN cached; END IF;
    END IF;

    PERFORM set_config('statement_timeout', '120000', true);

    WITH hr_filtered AS (
        SELECT *
        FROM hr_employees h
        WHERE (p_teams IS NULL OR cardinality(p_teams) = 0 OR h.team = ANY(p_teams))
          AND (p_locations IS NULL OR cardinality(p_locations) = 0 OR h.location = ANY(p_locations))
          AND (p_designations IS NULL OR cardinality(p_designations) = 0 OR h.designation = ANY(p_designations))
          AND (p_practices IS NULL OR cardinality(p_practices) = 0 OR h.practice_function = ANY(p_practices))
    ),
    active_in_period AS (
        SELECT DISTINCT u.user_email
        FROM usage_events u
        WHERE u.user_email IS NOT NULL
          AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
          AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
    ),
    ever_used AS (
        SELECT DISTINCT u.user_email
        FROM usage_events u
        WHERE u.user_email IS NOT NULL
    ),
    hr_enriched AS (
        SELECT
            h.*,
            (a.user_email IS NOT NULL) AS is_active,
            (e.user_email IS NOT NULL) AS has_ever_used
        FROM hr_filtered h
        LEFT JOIN active_in_period a ON h.email = a.user_email
        LEFT JOIN ever_used e ON h.email = e.user_email
    ),
    period_actions AS (
        SELECT COUNT(*)::bigint AS total_actions
        FROM usage_events u
        WHERE u.user_email IN (SELECT email FROM hr_enriched WHERE access_state = 'granted' AND is_active)
          AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
          AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
    ),
    kpis AS (
        SELECT
            COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending'))::bigint AS total_workforce,
            COUNT(*) FILTER (WHERE access_state = 'granted')::bigint AS access_granted,
            COUNT(*) FILTER (WHERE access_state = 'pending')::bigint AS access_pending,
            COUNT(*) FILTER (WHERE access_state = 'granted' AND is_active)::bigint AS active_users,
            COUNT(*) FILTER (WHERE access_state = 'granted' AND NOT is_active)::bigint AS inactive_users,
            COUNT(*) FILTER (WHERE access_state = 'revoked')::bigint AS revoked_count,
            COUNT(*) FILTER (WHERE access_state = 'resigned')::bigint AS resigned_count,
            COUNT(*) FILTER (WHERE access_state = 'granted' AND NOT has_ever_used)::bigint AS never_used_lifetime,
            CASE
                WHEN COUNT(*) FILTER (WHERE access_state = 'granted') > 0 THEN
                    ROUND(
                        100.0 * COUNT(*) FILTER (WHERE access_state = 'granted' AND is_active)::numeric
                        / COUNT(*) FILTER (WHERE access_state = 'granted')::numeric,
                        1
                    )
                ELSE 0
            END AS adoption_rate,
            CASE
                WHEN COUNT(*) FILTER (WHERE access_state = 'granted' AND is_active) > 0 THEN
                    ROUND(
                        (SELECT total_actions FROM period_actions)::numeric
                        / COUNT(*) FILTER (WHERE access_state = 'granted' AND is_active)::numeric,
                        1
                    )
                ELSE 0
            END AS avg_actions_per_active
        FROM hr_enriched
    ),
    team_access AS (
        SELECT
            COALESCE(team, 'Unknown') AS label,
            ROUND(
                100.0 * COUNT(*) FILTER (WHERE access_state = 'granted')::numeric
                / NULLIF(COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending'))::numeric, 0),
                1
            ) AS value
        FROM hr_enriched
        WHERE access_state IN ('granted', 'pending')
          AND team IS NOT NULL AND team <> ''
        GROUP BY 1
        HAVING COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending')) > 0
          AND ROUND(
                100.0 * COUNT(*) FILTER (WHERE access_state = 'granted')::numeric
                / NULLIF(COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending'))::numeric, 0),
                1
              ) > 0
        ORDER BY value DESC, label
        LIMIT 15
    ),
    team_adoption AS (
        SELECT
            COALESCE(team, 'Unknown') AS label,
            ROUND(
                100.0 * COUNT(*) FILTER (WHERE access_state = 'granted' AND is_active)::numeric
                / NULLIF(COUNT(*) FILTER (WHERE access_state = 'granted')::numeric, 0),
                1
            ) AS value
        FROM hr_enriched
        WHERE access_state = 'granted'
          AND team IS NOT NULL AND team <> ''
        GROUP BY 1
        HAVING COUNT(*) FILTER (WHERE access_state = 'granted') > 0
        ORDER BY value DESC, label
        LIMIT 15
    ),
    practice_access AS (
        SELECT
            COALESCE(practice_function, 'Unknown') AS label,
            ROUND(
                100.0 * COUNT(*) FILTER (WHERE access_state = 'granted')::numeric
                / NULLIF(COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending'))::numeric, 0),
                1
            ) AS value
        FROM hr_enriched
        WHERE access_state IN ('granted', 'pending')
          AND practice_function IS NOT NULL AND practice_function <> ''
        GROUP BY 1
        HAVING COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending')) > 0
          AND ROUND(
                100.0 * COUNT(*) FILTER (WHERE access_state = 'granted')::numeric
                / NULLIF(COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending'))::numeric, 0),
                1
              ) > 0
        ORDER BY value DESC, label
        LIMIT 15
    ),
    funnel AS (
        SELECT label, value FROM (
            SELECT 'Access Pending' AS label,
                   COUNT(*) FILTER (WHERE access_state = 'pending')::bigint AS value,
                   1 AS sort_order
            FROM hr_enriched
            UNION ALL
            SELECT 'Active (with access)',
                   COUNT(*) FILTER (WHERE access_state = 'granted' AND is_active)::bigint,
                   2
            FROM hr_enriched
            UNION ALL
            SELECT 'Inactive (with access)',
                   COUNT(*) FILTER (WHERE access_state = 'granted' AND NOT is_active)::bigint,
                   3
            FROM hr_enriched
            UNION ALL
            SELECT 'Revoked',
                   COUNT(*) FILTER (WHERE access_state = 'revoked')::bigint,
                   4
            FROM hr_enriched
            UNION ALL
            SELECT 'Resigned',
                   COUNT(*) FILTER (WHERE access_state = 'resigned')::bigint,
                   5
            FROM hr_enriched
        ) f
        WHERE value > 0
        ORDER BY sort_order
    ),
    inactive_users AS (
        SELECT
            COALESCE(workforce_name, '—') AS name,
            email,
            COALESCE(team, '—') AS team,
            COALESCE(designation, '—') AS designation,
            COALESCE(location, '—') AS location,
            date_added,
            low_usage_warning
        FROM hr_enriched
        WHERE access_state = 'granted' AND NOT is_active
        ORDER BY workforce_name NULLS LAST, email
        LIMIT 500
    ),
    pending_access AS (
        SELECT
            COALESCE(workforce_name, '—') AS name,
            email,
            COALESCE(team, '—') AS team,
            COALESCE(practice_function, '—') AS practice,
            COALESCE(designation, '—') AS designation
        FROM hr_enriched
        WHERE access_state = 'pending'
        ORDER BY workforce_name NULLS LAST, email
        LIMIT 500
    ),
    revoked_users AS (
        SELECT
            COALESCE(workforce_name, '—') AS name,
            email,
            COALESCE(team, '—') AS team,
            COALESCE(harvey_status, '—') AS status
        FROM hr_enriched
        WHERE access_state = 'revoked'
        ORDER BY workforce_name NULLS LAST, email
        LIMIT 200
    )
    SELECT json_build_object(
        'kpis', (SELECT row_to_json(k) FROM kpis k),
        'team_access_coverage', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM team_access),
        'team_adoption_rate', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM team_adoption),
        'practice_access_coverage', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM practice_access),
        'access_funnel', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM funnel),
        'inactive_users', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM inactive_users t),
        'pending_access', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM pending_access t),
        'revoked_users', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM revoked_users t)
    ) INTO result;

    RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_adoption_bundle(TEXT[], TEXT[], TEXT[], TEXT[], DATE, DATE) TO authenticated;

-- ── get_adoption_filter_options ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_adoption_filter_options()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM require_authenticated();

    RETURN json_build_object(
        'practices', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (SELECT DISTINCT practice_function AS v FROM hr_employees
                  WHERE practice_function IS NOT NULL AND practice_function <> '') s
        ), '[]'::json),
        'teams_by_practice', COALESCE((
            SELECT json_object_agg(practice_function, teams)
            FROM (
                SELECT practice_function,
                       json_agg(team ORDER BY team) AS teams
                FROM (
                    SELECT DISTINCT practice_function, team
                    FROM hr_employees
                    WHERE practice_function IS NOT NULL AND practice_function <> ''
                      AND team IS NOT NULL AND team <> ''
                ) s
                GROUP BY practice_function
            ) g
        ), '{}'::json),
        'locations', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (SELECT DISTINCT location AS v FROM hr_employees
                  WHERE location IS NOT NULL AND location <> '') s
        ), '[]'::json),
        'designations', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (SELECT DISTINCT designation AS v FROM hr_employees
                  WHERE designation IS NOT NULL AND designation <> '') s
        ), '[]'::json)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_adoption_filter_options() TO authenticated;

-- ── refresh_dashboard_cache (extend with adoption bundle) ───────────────────

CREATE OR REPLACE FUNCTION refresh_dashboard_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_bundle JSON;
    v_opts JSON;
    v_tops JSON;
    v_adoption JSON;
BEGIN
    PERFORM set_config('statement_timeout', '120000', true);

    WITH base AS (
        SELECT usage_date, practice_function, team, location, access_point, designation,
               user_email, file_count, product_surface_area
        FROM usage_events
    ),
    span AS (
        SELECT COALESCE(MAX(usage_date) - MIN(usage_date), 0) AS day_span FROM base WHERE usage_date IS NOT NULL
    ),
    kpis AS (
        SELECT COUNT(DISTINCT user_email)::bigint AS active_users,
               COUNT(*)::bigint AS total_actions,
               COUNT(DISTINCT practice_function) FILTER (
                   WHERE practice_function IS NOT NULL AND practice_function <> ''
               )::bigint AS practice_areas
        FROM base
    ),
    timeline_grouped AS (
        SELECT
            CASE
                WHEN s.day_span <= 60 THEN date_trunc('day', b.usage_date)::date
                WHEN s.day_span <= 730 THEN date_trunc('month', b.usage_date)::date
                ELSE date_trunc('year', b.usage_date)::date
            END AS bucket,
            COUNT(*) AS cnt
        FROM base b
        CROSS JOIN span s
        WHERE b.usage_date IS NOT NULL
        GROUP BY 1
        ORDER BY 1
    ),
    timeline AS (
        SELECT
            CASE
                WHEN (SELECT day_span FROM span) <= 60 THEN to_char(bucket, 'YYYY-MM-DD')
                WHEN (SELECT day_span FROM span) <= 730 THEN to_char(bucket, 'Mon YYYY')
                ELSE to_char(bucket, 'YYYY')
            END AS label,
            cnt::bigint AS value
        FROM timeline_grouped
    ),
    practice AS (
        SELECT COALESCE(practice_function, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM base GROUP BY 1 ORDER BY value DESC LIMIT 7
    ),
    team AS (
        SELECT COALESCE(team, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM base GROUP BY 1 ORDER BY value DESC LIMIT 7
    ),
    loc AS (
        SELECT COALESCE(location, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM base GROUP BY 1 ORDER BY value DESC
    ),
    tool_counts AS (
        SELECT TRIM(t.tool) AS label, COUNT(*)::bigint AS value
        FROM base b
        CROSS JOIN LATERAL unnest(
            string_to_array(COALESCE(b.product_surface_area, ''), ',')
        ) AS t(tool)
        WHERE TRIM(t.tool) <> ''
        GROUP BY 1
    ),
    ranked_tools AS (
        SELECT label, value, ROW_NUMBER() OVER (ORDER BY value DESC) AS rn
        FROM tool_counts
    ),
    tools AS (
        SELECT label, value FROM ranked_tools WHERE rn <= 8
        UNION ALL
        SELECT 'Other', SUM(value)::bigint
        FROM ranked_tools
        WHERE rn > 8
        HAVING SUM(value) > 0
    ),
    desg AS (
        SELECT COALESCE(designation, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM base GROUP BY 1 ORDER BY value DESC
    )
    SELECT json_build_object(
        'kpis', (SELECT row_to_json(k) FROM kpis k),
        'timeline', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM timeline),
        'timeline_granularity', (
            CASE
                WHEN (SELECT day_span FROM span) <= 60 THEN 'daily'
                WHEN (SELECT day_span FROM span) <= 730 THEN 'monthly'
                ELSE 'yearly'
            END
        ),
        'practice', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM practice),
        'team', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM team),
        'location', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM loc),
        'tools', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)
            ORDER BY CASE WHEN label = 'Other' THEN 1 ELSE 0 END, value DESC), '[]'::json) FROM tools),
        'designation', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM desg)
    ) INTO v_bundle;

    SELECT json_build_object(
        'practices', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (SELECT DISTINCT practice_function AS v FROM usage_events
                  WHERE practice_function IS NOT NULL AND practice_function <> '') s
        ), '[]'::json),
        'teams_by_practice', COALESCE((
            SELECT json_object_agg(practice_function, teams)
            FROM (
                SELECT practice_function,
                       json_agg(team ORDER BY team) AS teams
                FROM (
                    SELECT DISTINCT practice_function, team
                    FROM usage_events
                    WHERE practice_function IS NOT NULL AND practice_function <> ''
                      AND team IS NOT NULL AND team <> ''
                ) s
                GROUP BY practice_function
            ) g
        ), '{}'::json),
        'locations', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (SELECT DISTINCT location AS v FROM usage_events
                  WHERE location IS NOT NULL AND location <> '') s
        ), '[]'::json),
        'accesses', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (SELECT DISTINCT access_point AS v FROM usage_events
                  WHERE access_point IS NOT NULL AND access_point <> '') s
        ), '[]'::json),
        'designations', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (SELECT DISTINCT designation AS v FROM usage_events
                  WHERE designation IS NOT NULL AND designation <> '') s
        ), '[]'::json),
        'products', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (
                SELECT DISTINCT TRIM(t.tool) AS v
                FROM usage_events u
                CROSS JOIN LATERAL unnest(string_to_array(COALESCE(u.product_surface_area, ''), ',')) AS t(tool)
                WHERE TRIM(t.tool) <> ''
            ) s
        ), '[]'::json)
    ) INTO v_opts;

    SELECT COALESCE((
        SELECT json_agg(row_to_json(t) ORDER BY t.actions DESC)
        FROM (
            SELECT user_email AS user,
                COALESCE(MAX(workforce_name), '—') AS name,
                COALESCE(MAX(designation), '—') AS designation,
                COALESCE(MAX(location), '—') AS location,
                COUNT(*)::bigint AS actions,
                COALESCE(SUM(file_count), 0)::bigint AS files
            FROM usage_events WHERE user_email IS NOT NULL
            GROUP BY user_email ORDER BY actions DESC LIMIT 2000
        ) t
    ), '[]'::json) INTO v_tops;

    v_adoption := get_adoption_bundle(NULL, NULL, NULL, NULL, NULL, NULL);

    UPDATE dashboard_cache SET
        filter_options = v_opts,
        dashboard_bundle = v_bundle,
        top_users = v_tops,
        adoption_bundle = v_adoption,
        refreshed_at = NOW()
    WHERE id = 1;
END;
$$;
