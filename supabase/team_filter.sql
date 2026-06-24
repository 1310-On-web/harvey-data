-- Team filter + Top 7 Teams chart — run in Supabase SQL Editor after timeline_chart.sql
-- Replaces practice chart with team (top 7). Adds cascading Team filter support.

CREATE INDEX IF NOT EXISTS idx_usage_events_team ON usage_events (team);

-- ── refresh_dashboard_cache ───────────────────────────────────────────────────

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
        SELECT usage_date, practice_function, team, location, access_point, designation, user_email, file_count
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
    team AS (
        SELECT COALESCE(team, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM base GROUP BY 1 ORDER BY value DESC LIMIT 7
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
        'team', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM team),
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

-- ── get_dashboard_bundle ──────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_dashboard_bundle(TEXT, TEXT, TEXT, TEXT, DATE, DATE);

CREATE OR REPLACE FUNCTION get_dashboard_bundle(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All',
    p_team TEXT DEFAULT 'All',
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

    IF p_practice = 'All' AND p_team = 'All' AND p_location = 'All' AND p_access = 'All' AND p_designation = 'All'
       AND p_start_date IS NULL AND p_end_date IS NULL THEN
        SELECT dashboard_bundle INTO cached FROM dashboard_cache WHERE id = 1;
        IF cached IS NOT NULL AND (cached::jsonb ? 'timeline') THEN RETURN cached; END IF;
    END IF;

    PERFORM set_config('statement_timeout', '120000', true);

    WITH filtered_base AS MATERIALIZED (
        SELECT usage_date, practice_function, team, location, access_point, designation, user_email
        FROM usage_events u
        WHERE (p_practice = 'All' OR u.practice_function = p_practice)
          AND (p_location = 'All' OR u.location = p_location)
          AND (p_access = 'All' OR u.access_point = p_access)
          AND (p_designation = 'All' OR u.designation = p_designation)
          AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
          AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
    ),
    filtered AS MATERIALIZED (
        SELECT * FROM filtered_base
        WHERE (p_team = 'All' OR team = p_team)
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
    team AS (
        SELECT COALESCE(team, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered_base GROUP BY 1 ORDER BY value DESC LIMIT 7
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
        'team', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM team),
        'location', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM loc),
        'platform', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM platform),
        'designation', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM desg)
    ) INTO result;

    RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_dashboard_bundle(TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE) TO authenticated;

-- ── get_top_users ───────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_top_users(TEXT, TEXT, TEXT, TEXT, DATE, DATE);

CREATE OR REPLACE FUNCTION get_top_users(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All',
    p_team TEXT DEFAULT 'All',
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE cached JSON;
BEGIN
    PERFORM require_authenticated();

    IF p_practice = 'All' AND p_team = 'All' AND p_location = 'All' AND p_access = 'All' AND p_designation = 'All'
       AND p_start_date IS NULL AND p_end_date IS NULL THEN
        SELECT top_users INTO cached FROM dashboard_cache WHERE id = 1;
        IF cached IS NOT NULL THEN RETURN cached; END IF;
    END IF;

    PERFORM set_config('statement_timeout', '120000', true);

    RETURN COALESCE((
        SELECT json_agg(row_to_json(t) ORDER BY t.actions DESC)
        FROM (
            SELECT user_email AS user,
                COALESCE(MAX(workforce_name), '—') AS name,
                COALESCE(MAX(designation), '—') AS designation,
                COALESCE(MAX(location), '—') AS location,
                COUNT(*)::bigint AS actions,
                COALESCE(SUM(file_count), 0)::bigint AS files
            FROM usage_events u
            WHERE (p_practice = 'All' OR u.practice_function = p_practice)
              AND (p_team = 'All' OR u.team = p_team)
              AND (p_location = 'All' OR u.location = p_location)
              AND (p_access = 'All' OR u.access_point = p_access)
              AND (p_designation = 'All' OR u.designation = p_designation)
              AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
              AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
              AND user_email IS NOT NULL
            GROUP BY user_email ORDER BY actions DESC LIMIT 500
        ) t
    ), '[]'::json);
END;
$$;

GRANT EXECUTE ON FUNCTION get_top_users(TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE) TO authenticated;

-- ── get_usage_page ────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_usage_page(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER, DATE, DATE);

CREATE OR REPLACE FUNCTION get_usage_page(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All',
    p_team TEXT DEFAULT 'All',
    p_search TEXT DEFAULT '',
    p_sort_key TEXT DEFAULT 'utc_time',
    p_sort_asc BOOLEAN DEFAULT FALSE,
    p_page INTEGER DEFAULT 1,
    p_page_size INTEGER DEFAULT 20,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    total_count BIGINT;
    rows_json JSON;
    offset_val INTEGER;
    search_lower TEXT;
    sort_col TEXT;
    sort_dir TEXT;
BEGIN
    PERFORM require_authenticated();
    PERFORM set_config('statement_timeout', '120000', true);

    search_lower := LOWER(TRIM(COALESCE(p_search, '')));
    offset_val := GREATEST(p_page - 1, 0) * p_page_size;

    sort_col := CASE p_sort_key
        WHEN 'user' THEN 'user_email'
        WHEN 'Workforce Name' THEN 'workforce_name'
        WHEN 'Practice/ Function' THEN 'practice_function'
        WHEN 'Location' THEN 'location'
        WHEN 'access_point' THEN 'access_point'
        WHEN 'product_surface_area' THEN 'product_surface_area'
        WHEN 'file_count' THEN 'file_count'
        ELSE 'utc_time'
    END;
    sort_dir := CASE WHEN p_sort_asc THEN 'ASC' ELSE 'DESC' END;

    SELECT COUNT(*) INTO total_count
    FROM usage_events u
    WHERE (p_practice = 'All' OR u.practice_function = p_practice)
      AND (p_team = 'All' OR u.team = p_team)
      AND (p_location = 'All' OR u.location = p_location)
      AND (p_access = 'All' OR u.access_point = p_access)
      AND (p_designation = 'All' OR u.designation = p_designation)
      AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
      AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
      AND (search_lower = '' OR
           LOWER(COALESCE(u.user_email, '')) LIKE '%' || search_lower || '%' OR
           LOWER(COALESCE(u.workforce_name, '')) LIKE '%' || search_lower || '%' OR
           LOWER(COALESCE(u.practice_function, '')) LIKE '%' || search_lower || '%' OR
           LOWER(COALESCE(u.location, '')) LIKE '%' || search_lower || '%' OR
           LOWER(COALESCE(u.access_point, '')) LIKE '%' || search_lower || '%' OR
           LOWER(COALESCE(u.product_surface_area, '')) LIKE '%' || search_lower || '%');

    EXECUTE format(
        $q$
        SELECT COALESCE(json_agg(row_to_json(p)), '[]'::json)
        FROM (
            SELECT utc_time, user_email, workforce_name, practice_function,
                   location, access_point, product_surface_area, file_count
            FROM usage_events u
            WHERE ($1 = 'All' OR u.practice_function = $1)
              AND ($10 = 'All' OR u.team = $10)
              AND ($2 = 'All' OR u.location = $2)
              AND ($3 = 'All' OR u.access_point = $3)
              AND ($4 = 'All' OR u.designation = $4)
              AND ($8 IS NULL OR u.usage_date >= $8)
              AND ($9 IS NULL OR u.usage_date <= $9)
              AND ($5 = '' OR
                   LOWER(COALESCE(u.user_email, '')) LIKE '%%' || $5 || '%%' OR
                   LOWER(COALESCE(u.workforce_name, '')) LIKE '%%' || $5 || '%%' OR
                   LOWER(COALESCE(u.practice_function, '')) LIKE '%%' || $5 || '%%' OR
                   LOWER(COALESCE(u.location, '')) LIKE '%%' || $5 || '%%' OR
                   LOWER(COALESCE(u.access_point, '')) LIKE '%%' || $5 || '%%' OR
                   LOWER(COALESCE(u.product_surface_area, '')) LIKE '%%' || $5 || '%%')
            ORDER BY %I %s NULLS LAST
            LIMIT $6 OFFSET $7
        ) p
        $q$, sort_col, sort_dir
    ) INTO rows_json
    USING p_practice, p_location, p_access, p_designation, search_lower,
          p_page_size, offset_val, p_start_date, p_end_date, p_team;

    RETURN json_build_object('total', total_count, 'rows', rows_json);
END;
$$;

GRANT EXECUTE ON FUNCTION get_usage_page(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER, DATE, DATE) TO authenticated;

-- ── export_usage_csv ──────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS export_usage_csv(TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE);

CREATE OR REPLACE FUNCTION export_usage_csv(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All',
    p_team TEXT DEFAULT 'All',
    p_search TEXT DEFAULT '',
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    csv_text TEXT;
    search_lower TEXT;
BEGIN
    PERFORM require_authenticated();
    PERFORM set_config('statement_timeout', '120000', true);

    search_lower := LOWER(TRIM(COALESCE(p_search, '')));

    SELECT string_agg(line, E'\n' ORDER BY sort_key)
    INTO csv_text
    FROM (
        SELECT 0 AS sort_key,
            'utc_time,user_email,workforce_name,practice_function,location,access_point,product_surface_area,file_count,action,usage_date' AS line
        UNION ALL
        SELECT 1 AS sort_key,
            concat_ws(',',
                COALESCE(to_char(utc_time, 'YYYY-MM-DD HH24:MI:SS'), ''),
                COALESCE(user_email, ''),
                COALESCE(replace(workforce_name, ',', ' '), ''),
                COALESCE(replace(practice_function, ',', ' '), ''),
                COALESCE(replace(location, ',', ' '), ''),
                COALESCE(access_point, ''),
                COALESCE(replace(product_surface_area, ',', ' '), ''),
                COALESCE(file_count::text, '0'),
                COALESCE(action, ''),
                COALESCE(to_char(usage_date, 'YYYY-MM-DD'), '')
            ) AS line
        FROM usage_events u
        WHERE (p_practice = 'All' OR u.practice_function = p_practice)
          AND (p_team = 'All' OR u.team = p_team)
          AND (p_location = 'All' OR u.location = p_location)
          AND (p_access = 'All' OR u.access_point = p_access)
          AND (p_designation = 'All' OR u.designation = p_designation)
          AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
          AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
          AND (search_lower = '' OR
               LOWER(COALESCE(u.user_email, '')) LIKE '%' || search_lower || '%' OR
               LOWER(COALESCE(u.workforce_name, '')) LIKE '%' || search_lower || '%' OR
               LOWER(COALESCE(u.practice_function, '')) LIKE '%' || search_lower || '%' OR
               LOWER(COALESCE(u.location, '')) LIKE '%' || search_lower || '%' OR
               LOWER(COALESCE(u.access_point, '')) LIKE '%' || search_lower || '%' OR
               LOWER(COALESCE(u.product_surface_area, '')) LIKE '%' || search_lower || '%')
        LIMIT 100000
    ) sub;

    RETURN COALESCE(csv_text, '');
END;
$$;

GRANT EXECUTE ON FUNCTION export_usage_csv(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE) TO authenticated;

-- ── export_top_users_csv ──────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS export_top_users_csv(TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS export_top_users_csv(TEXT, TEXT, TEXT, TEXT, DATE, DATE);

CREATE OR REPLACE FUNCTION export_top_users_csv(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All',
    p_team TEXT DEFAULT 'All',
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    csv_text TEXT;
BEGIN
    PERFORM require_authenticated();
    PERFORM set_config('statement_timeout', '120000', true);

    WITH ranked AS (
        SELECT
            user_email,
            COALESCE(MAX(workforce_name), '—') AS workforce_name,
            COALESCE(MAX(designation), '—') AS designation,
            COALESCE(MAX(location), '—') AS location,
            COUNT(*)::bigint AS actions,
            COALESCE(SUM(file_count), 0)::bigint AS files,
            ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_val
        FROM usage_events u
        WHERE (p_practice = 'All' OR u.practice_function = p_practice)
          AND (p_team = 'All' OR u.team = p_team)
          AND (p_location = 'All' OR u.location = p_location)
          AND (p_access = 'All' OR u.access_point = p_access)
          AND (p_designation = 'All' OR u.designation = p_designation)
          AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
          AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
          AND user_email IS NOT NULL
        GROUP BY user_email
    )
    SELECT string_agg(line, E'\n' ORDER BY sort_key, rank_val)
    INTO csv_text
    FROM (
        SELECT 0 AS sort_key, 0 AS rank_val,
            'Rank,User Email,Workforce Name,Designation,Location,Actions,Files' AS line
        UNION ALL
        SELECT
            1 AS sort_key,
            rank_val,
            concat_ws(',',
                rank_val::text,
                COALESCE(user_email, ''),
                COALESCE(replace(workforce_name, ',', ' '), ''),
                COALESCE(replace(designation, ',', ' '), ''),
                COALESCE(replace(location, ',', ' '), ''),
                actions::text,
                files::text
            ) AS line
        FROM ranked
        LIMIT 501
    ) sub;

    RETURN COALESCE(csv_text, '');
END;
$$;

GRANT EXECUTE ON FUNCTION export_top_users_csv(TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE) TO authenticated;

SELECT refresh_dashboard_cache();
