-- Fix Team Access Coverage chart data and sort order.
-- Run in Supabase SQL Editor after limit_2000_top_users.sql (if applied).

GRANT EXECUTE ON FUNCTION refresh_dashboard_cache() TO authenticated;

-- Re-run the full get_adoption_bundle block from supabase/master_data_adoption.sql first,
-- then refresh the cached adoption bundle:
SELECT refresh_dashboard_cache();
