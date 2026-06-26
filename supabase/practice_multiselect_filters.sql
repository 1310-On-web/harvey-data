-- Practice chart + multi-select array filters + product filter
-- Run in Supabase SQL Editor after tools_chart.sql

-- Drop legacy TEXT-param functions
DROP FUNCTION IF EXISTS get_dashboard_bundle(TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE);
DROP FUNCTION IF EXISTS get_top_users(TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE);
DROP FUNCTION IF EXISTS get_usage_page(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER, DATE, DATE);
DROP FUNCTION IF EXISTS export_usage_csv(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE);
DROP FUNCTION IF EXISTS export_top_users_csv(TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE);

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

CREATE OR REPLACE FUNCTION get_dashboard_bundle(
    p_practices TEXT[] DEFAULT NULL,
    p_locations TEXT[] DEFAULT NULL,
    p_accesses TEXT[] DEFAULT NULL,
    p_designations TEXT[] DEFAULT NULL,
    p_teams TEXT[] DEFAULT NULL,
    p_products TEXT[] DEFAULT NULL,
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
       AND (p_accesses IS NULL OR cardinality(p_accesses) = 0)
       AND (p_designations IS NULL OR cardinality(p_designations) = 0)
       AND (p_products IS NULL OR cardinality(p_products) = 0)
       AND p_start_date IS NULL AND p_end_date IS NULL THEN
        SELECT dashboard_bundle INTO cached FROM dashboard_cache WHERE id = 1;
        IF cached IS NOT NULL AND (cached::jsonb ? 'practice') THEN RETURN cached; END IF;
    END IF;

    PERFORM set_config('statement_timeout', '120000', true);

    WITH filtered_no_practice AS MATERIALIZED (
        SELECT usage_date, practice_function, team, location, access_point, designation,
               user_email, product_surface_area
        FROM usage_events u
        WHERE (p_teams IS NULL OR cardinality(p_teams) = 0 OR u.team = ANY(p_teams))
          AND (p_locations IS NULL OR cardinality(p_locations) = 0 OR u.location = ANY(p_locations))
          AND (p_accesses IS NULL OR cardinality(p_accesses) = 0 OR u.access_point = ANY(p_accesses))
          AND (p_designations IS NULL OR cardinality(p_designations) = 0 OR u.designation = ANY(p_designations))
          AND (p_products IS NULL OR cardinality(p_products) = 0 OR EXISTS (
              SELECT 1 FROM unnest(string_to_array(u.product_surface_area, ',')) AS t(p)
              WHERE TRIM(t.p) = ANY(p_products)
          ))
          AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
          AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
    ),
    filtered_base AS MATERIALIZED (
        SELECT * FROM filtered_no_practice
        WHERE (p_practices IS NULL OR cardinality(p_practices) = 0 OR practice_function = ANY(p_practices))
    ),
    filtered AS MATERIALIZED (
        SELECT * FROM filtered_base
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
        FROM filtered_base GROUP BY 1 ORDER BY value DESC LIMIT 7
    ),
    team AS (
        SELECT COALESCE(team, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered_base GROUP BY 1 ORDER BY value DESC LIMIT 7
    ),
    loc AS (
        SELECT COALESCE(location, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered GROUP BY 1 ORDER BY value DESC
    ),
    tool_counts AS (
        SELECT TRIM(t.tool) AS label, COUNT(*)::bigint AS value
        FROM filtered f
        CROSS JOIN LATERAL unnest(
            string_to_array(COALESCE(f.product_surface_area, ''), ',')
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
        'team', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM team),
        'location', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM loc),
        'tools', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)
            ORDER BY CASE WHEN label = 'Other' THEN 1 ELSE 0 END, value DESC), '[]'::json) FROM tools),
        'designation', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM desg)
    ) INTO result;

    RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_dashboard_bundle(TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION get_top_users(
    p_practices TEXT[] DEFAULT NULL,
    p_locations TEXT[] DEFAULT NULL,
    p_accesses TEXT[] DEFAULT NULL,
    p_designations TEXT[] DEFAULT NULL,
    p_teams TEXT[] DEFAULT NULL,
    p_products TEXT[] DEFAULT NULL,
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

    IF (p_practices IS NULL OR cardinality(p_practices) = 0)
       AND (p_teams IS NULL OR cardinality(p_teams) = 0)
       AND (p_locations IS NULL OR cardinality(p_locations) = 0)
       AND (p_accesses IS NULL OR cardinality(p_accesses) = 0)
       AND (p_designations IS NULL OR cardinality(p_designations) = 0)
       AND (p_products IS NULL OR cardinality(p_products) = 0)
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
            WHERE (p_practices IS NULL OR cardinality(p_practices) = 0 OR u.practice_function = ANY(p_practices))
              AND (p_teams IS NULL OR cardinality(p_teams) = 0 OR u.team = ANY(p_teams))
              AND (p_locations IS NULL OR cardinality(p_locations) = 0 OR u.location = ANY(p_locations))
              AND (p_accesses IS NULL OR cardinality(p_accesses) = 0 OR u.access_point = ANY(p_accesses))
              AND (p_designations IS NULL OR cardinality(p_designations) = 0 OR u.designation = ANY(p_designations))
              AND (p_products IS NULL OR cardinality(p_products) = 0 OR EXISTS (
                  SELECT 1 FROM unnest(string_to_array(u.product_surface_area, ',')) AS t(p)
                  WHERE TRIM(t.p) = ANY(p_products)
              ))
              AND (p_start_date IS NULL OR u.usage_date >= p_start_date)
              AND (p_end_date IS NULL OR u.usage_date <= p_end_date)
              AND user_email IS NOT NULL
            GROUP BY user_email ORDER BY actions DESC LIMIT 500
        ) t
    ), '[]'::json);
END;
$$;

GRANT EXECUTE ON FUNCTION get_top_users(TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION get_usage_page(
    p_practices TEXT[] DEFAULT NULL,
    p_locations TEXT[] DEFAULT NULL,
    p_accesses TEXT[] DEFAULT NULL,
    p_designations TEXT[] DEFAULT NULL,
    p_teams TEXT[] DEFAULT NULL,
    p_products TEXT[] DEFAULT NULL,
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
    WHERE (p_practices IS NULL OR cardinality(p_practices) = 0 OR u.practice_function = ANY(p_practices))
      AND (p_teams IS NULL OR cardinality(p_teams) = 0 OR u.team = ANY(p_teams))
      AND (p_locations IS NULL OR cardinality(p_locations) = 0 OR u.location = ANY(p_locations))
      AND (p_accesses IS NULL OR cardinality(p_accesses) = 0 OR u.access_point = ANY(p_accesses))
      AND (p_designations IS NULL OR cardinality(p_designations) = 0 OR u.designation = ANY(p_designations))
      AND (p_products IS NULL OR cardinality(p_products) = 0 OR EXISTS (
          SELECT 1 FROM unnest(string_to_array(u.product_surface_area, ',')) AS t(p)
          WHERE TRIM(t.p) = ANY(p_products)
      ))
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
            WHERE ($1 IS NULL OR cardinality($1) = 0 OR u.practice_function = ANY($1))
              AND ($2 IS NULL OR cardinality($2) = 0 OR u.location = ANY($2))
              AND ($3 IS NULL OR cardinality($3) = 0 OR u.access_point = ANY($3))
              AND ($4 IS NULL OR cardinality($4) = 0 OR u.designation = ANY($4))
              AND ($5 IS NULL OR cardinality($5) = 0 OR u.team = ANY($5))
              AND ($6 IS NULL OR cardinality($6) = 0 OR EXISTS (
                  SELECT 1 FROM unnest(string_to_array(u.product_surface_area, ',')) AS t(p)
                  WHERE TRIM(t.p) = ANY($6)
              ))
              AND ($7 IS NULL OR u.usage_date >= $7)
              AND ($8 IS NULL OR u.usage_date <= $8)
              AND ($9 = '' OR
                   LOWER(COALESCE(u.user_email, '')) LIKE '%%' || $9 || '%%' OR
                   LOWER(COALESCE(u.workforce_name, '')) LIKE '%%' || $9 || '%%' OR
                   LOWER(COALESCE(u.practice_function, '')) LIKE '%%' || $9 || '%%' OR
                   LOWER(COALESCE(u.location, '')) LIKE '%%' || $9 || '%%' OR
                   LOWER(COALESCE(u.access_point, '')) LIKE '%%' || $9 || '%%' OR
                   LOWER(COALESCE(u.product_surface_area, '')) LIKE '%%' || $9 || '%%')
            ORDER BY %I %s NULLS LAST
            LIMIT $10 OFFSET $11
        ) p
        $q$, sort_col, sort_dir
    ) INTO rows_json
    USING p_practices, p_locations, p_accesses, p_designations, p_teams, p_products,
          p_start_date, p_end_date, search_lower, p_page_size, offset_val;

    RETURN json_build_object('total', total_count, 'rows', rows_json);
END;
$$;

GRANT EXECUTE ON FUNCTION get_usage_page(TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT, TEXT, BOOLEAN, INTEGER, INTEGER, DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION export_usage_csv(
    p_practices TEXT[] DEFAULT NULL,
    p_locations TEXT[] DEFAULT NULL,
    p_accesses TEXT[] DEFAULT NULL,
    p_designations TEXT[] DEFAULT NULL,
    p_teams TEXT[] DEFAULT NULL,
    p_products TEXT[] DEFAULT NULL,
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
        WHERE (p_practices IS NULL OR cardinality(p_practices) = 0 OR u.practice_function = ANY(p_practices))
          AND (p_teams IS NULL OR cardinality(p_teams) = 0 OR u.team = ANY(p_teams))
          AND (p_locations IS NULL OR cardinality(p_locations) = 0 OR u.location = ANY(p_locations))
          AND (p_accesses IS NULL OR cardinality(p_accesses) = 0 OR u.access_point = ANY(p_accesses))
          AND (p_designations IS NULL OR cardinality(p_designations) = 0 OR u.designation = ANY(p_designations))
          AND (p_products IS NULL OR cardinality(p_products) = 0 OR EXISTS (
              SELECT 1 FROM unnest(string_to_array(u.product_surface_area, ',')) AS t(p)
              WHERE TRIM(t.p) = ANY(p_products)
          ))
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

GRANT EXECUTE ON FUNCTION export_usage_csv(TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT, DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION export_top_users_csv(
    p_practices TEXT[] DEFAULT NULL,
    p_locations TEXT[] DEFAULT NULL,
    p_accesses TEXT[] DEFAULT NULL,
    p_designations TEXT[] DEFAULT NULL,
    p_teams TEXT[] DEFAULT NULL,
    p_products TEXT[] DEFAULT NULL,
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
        WHERE (p_practices IS NULL OR cardinality(p_practices) = 0 OR u.practice_function = ANY(p_practices))
          AND (p_teams IS NULL OR cardinality(p_teams) = 0 OR u.team = ANY(p_teams))
          AND (p_locations IS NULL OR cardinality(p_locations) = 0 OR u.location = ANY(p_locations))
          AND (p_accesses IS NULL OR cardinality(p_accesses) = 0 OR u.access_point = ANY(p_accesses))
          AND (p_designations IS NULL OR cardinality(p_designations) = 0 OR u.designation = ANY(p_designations))
          AND (p_products IS NULL OR cardinality(p_products) = 0 OR EXISTS (
              SELECT 1 FROM unnest(string_to_array(u.product_surface_area, ',')) AS t(p)
              WHERE TRIM(t.p) = ANY(p_products)
          ))
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

GRANT EXECUTE ON FUNCTION export_top_users_csv(TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], DATE, DATE) TO authenticated;

SELECT refresh_dashboard_cache();
