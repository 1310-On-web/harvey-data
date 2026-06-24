-- Harvey Usage Dashboard — RPC functions
-- Run after schema.sql in Supabase SQL Editor.

CREATE OR REPLACE FUNCTION require_authenticated()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION get_filter_options()
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
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_sync_info()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    meta sync_metadata%ROWTYPE;
BEGIN
    PERFORM require_authenticated();
    SELECT * INTO meta FROM sync_metadata WHERE id = 1;
    RETURN json_build_object(
        'last_sync', meta.last_sync,
        'min_date', meta.min_date,
        'max_date', meta.max_date,
        'row_count', meta.row_count,
        'last_sync_rows', meta.last_sync_rows
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_dashboard_bundle(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    result JSON;
BEGIN
    PERFORM require_authenticated();

    WITH filtered AS (
        SELECT *
        FROM usage_events u
        WHERE (p_practice = 'All' OR u.practice_function = p_practice)
          AND (p_location = 'All' OR u.location = p_location)
          AND (p_access = 'All' OR u.access_point = p_access)
          AND (p_designation = 'All' OR u.designation = p_designation)
    ),
    kpis AS (
        SELECT
            COUNT(DISTINCT user_email)::bigint AS active_users,
            COUNT(*)::bigint AS total_actions,
            COUNT(DISTINCT practice_function) FILTER (
                WHERE practice_function IS NOT NULL AND practice_function <> ''
            )::bigint AS practice_areas
        FROM filtered
    ),
    hourly AS (
        SELECT h.hour, COALESCE(f.cnt, 0)::bigint AS cnt
        FROM generate_series(0, 23) AS h(hour)
        LEFT JOIN (
            SELECT usage_hour AS hour, COUNT(*) AS cnt
            FROM filtered
            WHERE usage_hour IS NOT NULL
            GROUP BY usage_hour
        ) f ON f.hour = h.hour
        ORDER BY h.hour
    ),
    practice AS (
        SELECT COALESCE(practice_function, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered
        GROUP BY 1
        ORDER BY value DESC
    ),
    loc AS (
        SELECT COALESCE(location, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered
        GROUP BY 1
        ORDER BY value DESC
    ),
    platform AS (
        SELECT COALESCE(access_point, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered
        GROUP BY 1
        ORDER BY value DESC
    ),
    desg AS (
        SELECT COALESCE(designation, 'Unknown') AS label, COUNT(*)::bigint AS value
        FROM filtered
        GROUP BY 1
        ORDER BY value DESC
    )
    SELECT json_build_object(
        'kpis', (SELECT row_to_json(k) FROM kpis k),
        'hourly', (SELECT COALESCE(json_agg(json_build_object('hour', hour, 'cnt', cnt)), '[]'::json) FROM hourly),
        'practice', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM practice),
        'location', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM loc),
        'platform', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM platform),
        'designation', (SELECT COALESCE(json_agg(json_build_object('label', label, 'value', value)), '[]'::json) FROM desg)
    ) INTO result;

    RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION get_usage_page(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All',
    p_search TEXT DEFAULT '',
    p_sort_key TEXT DEFAULT 'utc_time',
    p_sort_asc BOOLEAN DEFAULT FALSE,
    p_page INTEGER DEFAULT 1,
    p_page_size INTEGER DEFAULT 20
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
BEGIN
    PERFORM require_authenticated();

    search_lower := LOWER(TRIM(COALESCE(p_search, '')));
    offset_val := GREATEST(p_page - 1, 0) * p_page_size;

    WITH filtered AS (
        SELECT *
        FROM usage_events u
        WHERE (p_practice = 'All' OR u.practice_function = p_practice)
          AND (p_location = 'All' OR u.location = p_location)
          AND (p_access = 'All' OR u.access_point = p_access)
          AND (p_designation = 'All' OR u.designation = p_designation)
          AND (
              search_lower = '' OR
              LOWER(COALESCE(u.user_email, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.workforce_name, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.practice_function, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.location, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.access_point, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.product_surface_area, '')) LIKE '%' || search_lower || '%'
          )
    ),
    counted AS (
        SELECT COUNT(*) AS cnt FROM filtered
    ),
    sorted AS (
        SELECT
            utc_time,
            user_email,
            workforce_name,
            practice_function,
            location,
            access_point,
            product_surface_area,
            file_count
        FROM filtered
        ORDER BY
            CASE WHEN p_sort_key = 'utc_time' AND p_sort_asc THEN utc_time END ASC NULLS LAST,
            CASE WHEN p_sort_key = 'utc_time' AND NOT p_sort_asc THEN utc_time END DESC NULLS LAST,
            CASE WHEN p_sort_key = 'user' AND p_sort_asc THEN user_email END ASC NULLS LAST,
            CASE WHEN p_sort_key = 'user' AND NOT p_sort_asc THEN user_email END DESC NULLS LAST,
            CASE WHEN p_sort_key = 'Workforce Name' AND p_sort_asc THEN workforce_name END ASC NULLS LAST,
            CASE WHEN p_sort_key = 'Workforce Name' AND NOT p_sort_asc THEN workforce_name END DESC NULLS LAST,
            CASE WHEN p_sort_key = 'Practice/ Function' AND p_sort_asc THEN practice_function END ASC NULLS LAST,
            CASE WHEN p_sort_key = 'Practice/ Function' AND NOT p_sort_asc THEN practice_function END DESC NULLS LAST,
            CASE WHEN p_sort_key = 'Location' AND p_sort_asc THEN location END ASC NULLS LAST,
            CASE WHEN p_sort_key = 'Location' AND NOT p_sort_asc THEN location END DESC NULLS LAST,
            CASE WHEN p_sort_key = 'access_point' AND p_sort_asc THEN access_point END ASC NULLS LAST,
            CASE WHEN p_sort_key = 'access_point' AND NOT p_sort_asc THEN access_point END DESC NULLS LAST,
            CASE WHEN p_sort_key = 'product_surface_area' AND p_sort_asc THEN product_surface_area END ASC NULLS LAST,
            CASE WHEN p_sort_key = 'product_surface_area' AND NOT p_sort_asc THEN product_surface_area END DESC NULLS LAST,
            CASE WHEN p_sort_key = 'file_count' AND p_sort_asc THEN file_count END ASC NULLS LAST,
            CASE WHEN p_sort_key = 'file_count' AND NOT p_sort_asc THEN file_count END DESC NULLS LAST,
            utc_time DESC
        LIMIT p_page_size OFFSET offset_val
    )
    SELECT
        (SELECT cnt FROM counted),
        (SELECT COALESCE(json_agg(row_to_json(s)), '[]'::json) FROM sorted s)
    INTO total_count, rows_json;

    RETURN json_build_object('total', total_count, 'rows', rows_json);
END;
$$;

CREATE OR REPLACE FUNCTION get_top_users(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM require_authenticated();

    RETURN COALESCE((
        SELECT json_agg(row_to_json(t) ORDER BY t.actions DESC)
        FROM (
            SELECT
                user_email AS user,
                COALESCE(MAX(workforce_name), '—') AS name,
                COALESCE(MAX(designation), '—') AS designation,
                COALESCE(MAX(location), '—') AS location,
                COUNT(*)::bigint AS actions,
                COALESCE(SUM(file_count), 0)::bigint AS files
            FROM usage_events u
            WHERE (p_practice = 'All' OR u.practice_function = p_practice)
              AND (p_location = 'All' OR u.location = p_location)
              AND (p_access = 'All' OR u.access_point = p_access)
              AND (p_designation = 'All' OR u.designation = p_designation)
              AND user_email IS NOT NULL
            GROUP BY user_email
            ORDER BY actions DESC
        ) t
    ), '[]'::json);
END;
$$;

CREATE OR REPLACE FUNCTION export_usage_csv(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All',
    p_search TEXT DEFAULT ''
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

    search_lower := LOWER(TRIM(COALESCE(p_search, '')));

    SELECT string_agg(line, E'\n' ORDER BY sort_key)
    INTO csv_text
    FROM (
        SELECT
            0 AS sort_key,
            'utc_time,user_email,workforce_name,practice_function,location,access_point,product_surface_area,file_count,action,usage_date' AS line
        UNION ALL
        SELECT
            1 AS sort_key,
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
          AND (p_location = 'All' OR u.location = p_location)
          AND (p_access = 'All' OR u.access_point = p_access)
          AND (p_designation = 'All' OR u.designation = p_designation)
          AND (
              search_lower = '' OR
              LOWER(COALESCE(u.user_email, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.workforce_name, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.practice_function, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.location, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.access_point, '')) LIKE '%' || search_lower || '%' OR
              LOWER(COALESCE(u.product_surface_area, '')) LIKE '%' || search_lower || '%'
          )
        LIMIT 100000
    ) sub;

    RETURN COALESCE(csv_text, '');
END;
$$;

CREATE OR REPLACE FUNCTION export_top_users_csv(
    p_practice TEXT DEFAULT 'All',
    p_location TEXT DEFAULT 'All',
    p_access TEXT DEFAULT 'All',
    p_designation TEXT DEFAULT 'All'
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
          AND (p_location = 'All' OR u.location = p_location)
          AND (p_access = 'All' OR u.access_point = p_access)
          AND (p_designation = 'All' OR u.designation = p_designation)
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
            rank_val::integer,
            concat_ws(',',
                rank_val::text,
                COALESCE(user_email, ''),
                replace(workforce_name, ',', ' '),
                replace(designation, ',', ' '),
                replace(location, ',', ' '),
                actions::text,
                files::text
            ) AS line
        FROM ranked
    ) sub;

    RETURN COALESCE(csv_text, '');
END;
$$;

GRANT EXECUTE ON FUNCTION get_filter_options() TO authenticated;
GRANT EXECUTE ON FUNCTION get_sync_info() TO authenticated;
GRANT EXECUTE ON FUNCTION get_dashboard_bundle(TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_usage_page(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_top_users(TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION export_usage_csv(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION export_top_users_csv(TEXT, TEXT, TEXT, TEXT) TO authenticated;
