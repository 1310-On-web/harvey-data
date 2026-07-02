-- Raise top-users cap from 500 to 2000 (max workforce size).
-- Run in Supabase SQL Editor after prior migrations.

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
            GROUP BY user_email ORDER BY actions DESC LIMIT 2000
        ) t
    ), '[]'::json);
END;
$$;

GRANT EXECUTE ON FUNCTION get_top_users(TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], DATE, DATE) TO authenticated;

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
        LIMIT 2001
    ) sub;

    RETURN COALESCE(csv_text, '');
END;
$$;

GRANT EXECUTE ON FUNCTION export_top_users_csv(TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], TEXT[], DATE, DATE) TO authenticated;

-- Rebuild cached top users with the new limit (no full cache refresh required).
UPDATE dashboard_cache SET
    top_users = COALESCE((
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
    ), '[]'::json),
    refreshed_at = NOW()
WHERE id = 1;
