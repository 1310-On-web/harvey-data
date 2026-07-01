-- Team / Practice Harvey usage reports
-- Run in Supabase SQL Editor after master_data_adoption.sql

CREATE OR REPLACE FUNCTION map_usage_feature(tool TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN LOWER(TRIM(tool)) LIKE '%follow-up%'
          OR LOWER(TRIM(tool)) LIKE '%follow up%'
          OR LOWER(TRIM(tool)) LIKE '%followup%' THEN 'followups'
        WHEN LOWER(TRIM(tool)) LIKE '%word%'
          OR LOWER(TRIM(tool)) LIKE '%add-in%'
          OR LOWER(TRIM(tool)) LIKE '%add in%' THEN 'word_addin'
        WHEN LOWER(TRIM(tool)) LIKE '%workflow%' THEN 'workflow_runs'
        WHEN LOWER(TRIM(tool)) LIKE '%playbook%' THEN 'playbook_runs'
        WHEN LOWER(TRIM(tool)) LIKE '%review table%'
          OR (LOWER(TRIM(tool)) LIKE '%review%' AND LOWER(TRIM(tool)) NOT LIKE '%workflow%') THEN 'review_table_columns'
        WHEN LOWER(TRIM(tool)) LIKE '%assistant%'
          OR LOWER(TRIM(tool)) LIKE '%thread%' THEN 'assistant_threads'
        ELSE NULL
    END;
$$;

CREATE OR REPLACE FUNCTION get_team_report_bundle(
    p_practice TEXT,
    p_team TEXT DEFAULT NULL,
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
    v_scope TEXT;
BEGIN
    PERFORM require_authenticated();

    IF p_practice IS NULL OR TRIM(p_practice) = '' THEN
        RAISE EXCEPTION 'Practice is required';
    END IF;
    IF p_start_date IS NULL OR p_end_date IS NULL THEN
        RAISE EXCEPTION 'Start date and end date are required';
    END IF;

    PERFORM set_config('statement_timeout', '120000', true);

    v_scope := CASE WHEN p_team IS NULL OR TRIM(p_team) = '' THEN 'practice' ELSE 'team' END;

    WITH hr_base AS (
        SELECT *
        FROM hr_employees h
        WHERE h.practice_function = p_practice
          AND (p_team IS NULL OR TRIM(p_team) = '' OR h.team = p_team)
    ),
    usage_filtered AS (
        SELECT u.*
        FROM usage_events u
        WHERE u.practice_function = p_practice
          AND (p_team IS NULL OR TRIM(p_team) = '' OR u.team = p_team)
          AND u.usage_date >= p_start_date
          AND u.usage_date <= p_end_date
          AND u.user_email IS NOT NULL
    ),
    usage_by_feature AS (
        SELECT
            u.user_email,
            map_usage_feature(TRIM(t.tool)) AS feature_key,
            COUNT(*)::bigint AS cnt
        FROM usage_filtered u
        CROSS JOIN LATERAL unnest(
            string_to_array(COALESCE(u.product_surface_area, ''), ',')
        ) AS t(tool)
        WHERE TRIM(t.tool) <> ''
        GROUP BY 1, 2
    ),
    user_totals AS (
        SELECT
            user_email,
            COUNT(*)::bigint AS total_activity
        FROM usage_filtered
        GROUP BY 1
    ),
    user_features AS (
        SELECT
            ut.user_email,
            ut.total_activity,
            COALESCE(SUM(ubf.cnt) FILTER (WHERE ubf.feature_key = 'assistant_threads'), 0)::bigint AS assistant_threads,
            COALESCE(SUM(ubf.cnt) FILTER (WHERE ubf.feature_key = 'followups'), 0)::bigint AS followups,
            COALESCE(SUM(ubf.cnt) FILTER (WHERE ubf.feature_key = 'workflow_runs'), 0)::bigint AS workflow_runs,
            COALESCE(SUM(ubf.cnt) FILTER (WHERE ubf.feature_key = 'playbook_runs'), 0)::bigint AS playbook_runs,
            COALESCE(SUM(ubf.cnt) FILTER (WHERE ubf.feature_key = 'review_table_columns'), 0)::bigint AS review_table_columns,
            COALESCE(SUM(ubf.cnt) FILTER (WHERE ubf.feature_key = 'word_addin'), 0)::bigint AS word_addin
        FROM user_totals ut
        LEFT JOIN usage_by_feature ubf ON ut.user_email = ubf.user_email
        GROUP BY ut.user_email, ut.total_activity
    ),
    feature_totals AS (
        SELECT
            COALESCE(SUM(cnt) FILTER (WHERE feature_key = 'assistant_threads'), 0)::bigint AS assistant_threads,
            COALESCE(SUM(cnt) FILTER (WHERE feature_key = 'followups'), 0)::bigint AS followups,
            COALESCE(SUM(cnt) FILTER (WHERE feature_key = 'workflow_runs'), 0)::bigint AS workflow_runs,
            COALESCE(SUM(cnt) FILTER (WHERE feature_key = 'playbook_runs'), 0)::bigint AS playbook_runs,
            COALESCE(SUM(cnt) FILTER (WHERE feature_key = 'review_table_columns'), 0)::bigint AS review_table_columns,
            COALESCE(SUM(cnt) FILTER (WHERE feature_key = 'word_addin'), 0)::bigint AS word_addin
        FROM usage_by_feature
        WHERE feature_key IS NOT NULL
    ),
    granted_members AS (
        SELECT
            h.email,
            COALESCE(h.workforce_name, '—') AS name,
            COALESCE(h.designation, '—') AS designation,
            h.email AS user_email,
            COALESCE(h.harvey_status, 'Added') AS status,
            COALESCE(h.team, '—') AS team,
            COALESCE(uf.total_activity, 0)::bigint AS total_activity,
            COALESCE(uf.assistant_threads, 0)::bigint AS assistant_threads,
            COALESCE(uf.followups, 0)::bigint AS followups,
            COALESCE(uf.workflow_runs, 0)::bigint AS workflow_runs,
            COALESCE(uf.playbook_runs, 0)::bigint AS playbook_runs,
            COALESCE(uf.review_table_columns, 0)::bigint AS review_table_columns,
            COALESCE(uf.word_addin, 0)::bigint AS word_addin
        FROM hr_base h
        LEFT JOIN user_features uf ON h.email = uf.user_email
        WHERE h.access_state = 'granted'
    ),
    top_user AS (
        SELECT name, total_activity
        FROM granted_members
        ORDER BY total_activity DESC, name
        LIMIT 1
    ),
    summary AS (
        SELECT
            COUNT(*) FILTER (WHERE access_state <> 'resigned')::bigint AS total_members,
            COUNT(*) FILTER (WHERE access_state = 'granted')::bigint AS with_access,
            COUNT(*) FILTER (WHERE access_state = 'granted' AND COALESCE(uf.total_activity, 0) > 0)::bigint AS used_harvey,
            COUNT(*) FILTER (WHERE access_state = 'granted' AND COALESCE(uf.total_activity, 0) = 0)::bigint AS not_used,
            COALESCE((SELECT SUM(total_activity) FROM user_totals), 0)::bigint AS total_activity,
            COALESCE((SELECT name FROM top_user), '—') AS top_user_name,
            COALESCE((SELECT total_activity FROM top_user), 0)::bigint AS top_user_actions,
            CASE
                WHEN COUNT(*) FILTER (WHERE access_state = 'granted') > 0 THEN
                    ROUND(
                        100.0 * COUNT(*) FILTER (WHERE access_state = 'granted' AND COALESCE(uf.total_activity, 0) > 0)::numeric
                        / COUNT(*) FILTER (WHERE access_state = 'granted')::numeric,
                        1
                    )
                ELSE 0
            END AS adoption_rate,
            COUNT(*) FILTER (WHERE access_state = 'granted' AND COALESCE(uf.total_activity, 0) = 0)::bigint AS inactive_count,
            COUNT(*) FILTER (WHERE access_state = 'pending')::bigint AS access_pending,
            CASE
                WHEN COUNT(*) FILTER (WHERE access_state = 'granted' AND COALESCE(uf.total_activity, 0) > 0) > 0 THEN
                    ROUND(
                        COALESCE((SELECT SUM(total_activity) FROM user_totals), 0)::numeric
                        / COUNT(*) FILTER (WHERE access_state = 'granted' AND COALESCE(uf.total_activity, 0) > 0)::numeric,
                        1
                    )
                ELSE 0
            END AS avg_actions_per_active,
            COUNT(*) FILTER (WHERE access_state = 'revoked')::bigint AS revoked_count,
            COUNT(*) FILTER (WHERE access_state = 'resigned')::bigint AS resigned_count,
            CASE
                WHEN COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending')) > 0 THEN
                    ROUND(
                        100.0 * COUNT(*) FILTER (WHERE access_state = 'granted')::numeric
                        / COUNT(*) FILTER (WHERE access_state IN ('granted', 'pending'))::numeric,
                        1
                    )
                ELSE 0
            END AS access_coverage_pct
        FROM hr_base h
        LEFT JOIN user_features uf ON h.email = uf.user_email
    ),
    without_access AS (
        SELECT
            COALESCE(h.workforce_name, '—') AS name,
            COALESCE(h.designation, '—') AS designation,
            h.email,
            COALESCE(
                h.harvey_status,
                CASE h.access_state
                    WHEN 'pending' THEN 'Did not request for access'
                    WHEN 'revoked' THEN 'Revoked'
                    WHEN 'resigned' THEN 'Resigned'
                    ELSE 'No access'
                END
            ) AS status_note
        FROM hr_base h
        WHERE h.access_state IS DISTINCT FROM 'granted'
        ORDER BY h.workforce_name NULLS LAST, h.email
    ),
    unmapped AS (
        SELECT DISTINCT TRIM(t.tool) AS tool
        FROM usage_filtered u
        CROSS JOIN LATERAL unnest(string_to_array(COALESCE(u.product_surface_area, ''), ',')) AS t(tool)
        WHERE TRIM(t.tool) <> ''
          AND map_usage_feature(TRIM(t.tool)) IS NULL
        ORDER BY 1
        LIMIT 50
    )
    SELECT json_build_object(
        'meta', json_build_object(
            'practice', p_practice,
            'team', p_team,
            'scope', v_scope,
            'start_date', p_start_date,
            'end_date', p_end_date,
            'period_label', to_char(p_start_date, 'DD Mon YYYY') || ' – ' || to_char(p_end_date, 'DD Mon YYYY'),
            'generated_at', to_char(NOW() AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') || ' IST',
            'title', CASE
                WHEN v_scope = 'team' THEN p_team || ' — Summary'
                ELSE p_practice || ' — Summary (All Teams)'
            END,
            'unmapped_features', COALESCE((SELECT json_agg(tool) FROM unmapped), '[]'::json)
        ),
        'summary', (SELECT row_to_json(s) FROM summary s),
        'features', json_build_array(
            json_build_object('key', 'assistant_threads', 'label', 'Assistant Threads', 'count', ft.assistant_threads),
            json_build_object('key', 'followups', 'label', 'Follow-ups Asked', 'count', ft.followups),
            json_build_object('key', 'word_addin', 'label', 'Word Add-in', 'count', ft.word_addin),
            json_build_object('key', 'workflow_runs', 'label', 'Workflow Runs', 'count', ft.workflow_runs),
            json_build_object('key', 'review_table_columns', 'label', 'Review Table Columns', 'count', ft.review_table_columns),
            json_build_object('key', 'playbook_runs', 'label', 'Playbook Runs', 'count', ft.playbook_runs)
        ),
        'members_with_access', COALESCE((
            SELECT json_agg(row_to_json(m) ORDER BY m.total_activity DESC, m.name)
            FROM granted_members m
        ), '[]'::json),
        'members_without_access', COALESCE((
            SELECT json_agg(row_to_json(w))
            FROM without_access w
        ), '[]'::json),
        'disclaimer', 'Note: Total Activity as per Harvey data may also include a combination of multiple activities which are counted only once. Hence, there can be a discrepancy in the total of Threads, Add-Ins etc. and Total Activity.'
    ) INTO result
    FROM feature_totals ft;

    RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_team_report_bundle(TEXT, TEXT, DATE, DATE) TO authenticated;
