-- Timeline chart (daily / monthly / yearly) — run in Supabase SQL Editor
-- Replaces hourly chart data. Then refreshes dashboard cache.

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
BEGIN
    PERFORM set_config('statement_timeout', '120000', true);

    WITH base AS (
        SELECT usage_date, practice_function, location, access_point, designation, user_email, file_count
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
        FROM base GROUP BY 1 ORDER BY value DESC
    ),
    loc AS (
        SELECT COALESCE(location, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM base GROUP BY 1 ORDER BY value DESC
    ),
    platform AS (
        SELECT COALESCE(access_point, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM base GROUP BY 1 ORDER BY value DESC
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
        'location', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM loc),
        'platform', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM platform),
        'designation', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM desg)
    ) INTO v_bundle;

    SELECT json_build_object(
        'practices', COALESCE((
            SELECT json_agg(v ORDER BY v)
            FROM (SELECT DISTINCT practice_function AS v FROM usage_events
                  WHERE practice_function IS NOT NULL AND practice_function <> '') s
        ), '[]'::json),
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
            GROUP BY user_email ORDER BY actions DESC LIMIT 500
        ) t
    ), '[]'::json) INTO v_tops;

    UPDATE dashboard_cache SET
        filter_options = v_opts,
        dashboard_bundle = v_bundle,
        top_users = v_tops,
        refreshed_at = NOW()
    WHERE id = 1;
END;
$$;

DROP FUNCTION IF EXISTS get_dashboard_bundle(TEXT, TEXT, TEXT, TEXT, DATE, DATE);

CREATE OR REPLACE FUNCTION get_dashboard_bundle(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All',
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

    IF p_practice = 'All' AND p_location = 'All' AND p_access = 'All' AND p_designation = 'All'
       AND p_start_date IS NULL AND p_end_date IS NULL THEN
        SELECT dashboard_bundle INTO cached FROM dashboard_cache WHERE id = 1;
        IF cached IS NOT NULL AND (cached::jsonb ? 'timeline') THEN RETURN cached; END IF;
    END IF;

    PERFORM set_config('statement_timeout', '120000', true);

    WITH filtered AS MATERIALIZED (
        SELECT usage_date, practice_function, location, access_point, designation, user_email
        FROM usage_events u
        WHERE (p_practice = 'All' OR u.practice_function = p_practice)
          AND (p_location = 'All' OR u.location = p_location)
          AND (p_access = 'All' OR u.access_point = p_access)
          AND (p_designation = 'All' OR u.designation = p_designation)
          AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
          AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
    ),
    span AS (
        SELECT COALESCE(MAX(usage_date) - MIN(usage_date), 0) AS day_span FROM filtered WHERE usage_date IS NOT NULL
    ),
    kpis AS (
        SELECT COUNT(DISTINCT user_email)::bigint AS active_users,
               COUNT(*)::bigint AS total_actions,
               COUNT(DISTINCT practice_function) FILTER (
                   WHERE practice_function IS NOT NULL AND practice_function <> ''
               )::bigint AS practice_areas
        FROM filtered
    ),
    timeline_grouped AS (
        SELECT
            CASE
                WHEN s.day_span <= 60 THEN date_trunc('day', f.usage_date)::date
                WHEN s.day_span <= 730 THEN date_trunc('month', f.usage_date)::date
                ELSE date_trunc('year', f.usage_date)::date
            END AS bucket,
            COUNT(*) AS cnt
        FROM filtered f
        CROSS JOIN span s
        WHERE f.usage_date IS NOT NULL
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
        FROM filtered GROUP BY 1 ORDER BY value DESC
    ),
    loc AS (
        SELECT COALESCE(location, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered GROUP BY 1 ORDER BY value DESC
    ),
    platform AS (
        SELECT COALESCE(access_point, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered GROUP BY 1 ORDER BY value DESC
    ),
    desg AS (
        SELECT COALESCE(designation, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered GROUP BY 1 ORDER BY value DESC
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
        'location', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM loc),
        'platform', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM platform),
        'designation', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM desg)
    ) INTO result;

    RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_dashboard_bundle(TEXT, TEXT, TEXT, TEXT, DATE, DATE) TO authenticated;

SELECT refresh_dashboard_cache();
