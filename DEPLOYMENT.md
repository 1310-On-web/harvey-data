# Harvey Usage Dashboard — Deployment Guide

This guide walks through going live with the free stack: **Supabase + GitHub Actions + GitHub Pages**.

## Architecture

- **Supabase** — PostgreSQL database + auth (magic link for invited users)
- **GitHub Actions** — daily Harvey API sync at ~6:30 AM IST
- **GitHub Pages** — hosts the HTML dashboard

---

## Step 1: Create Supabase project

1. Sign up at [supabase.com](https://supabase.com) (free tier, no IT needed).
2. Create a new project and note:
   - **Project URL** → `SUPABASE_URL`
   - **anon public key** → `SUPABASE_ANON_KEY` (safe for browser with RLS)
   - **service_role key** → `SUPABASE_SERVICE_ROLE_KEY` (server only, never in HTML)

3. Open **SQL Editor** and run in order:
   - [`supabase/schema.sql`](supabase/schema.sql)
   - [`supabase/functions.sql`](supabase/functions.sql)
   - Remaining migrations in order (see `supabase/` folder), ending with [`supabase/master_data_adoption.sql`](supabase/master_data_adoption.sql) and [`supabase/team_report.sql`](supabase/team_report.sql)

---

## Step 2: Configure Supabase Auth

1. **Authentication → Providers → Email** — enable Email provider.
2. **Authentication → Settings** — disable “Enable sign ups” (invite-only).
3. **Authentication → URL Configuration** — add your GitHub Pages URL:
   - `https://YOUR_USERNAME.github.io/YOUR_REPO/`
   - Also add `http://localhost:5500` (or similar) for local testing.
4. **Authentication → Users → Invite** — invite each team member (5–20 emails).

---

## Step 3: Local setup and data import

```powershell
cd WebAPP-Harvey
py -3 -m pip install -r requirements.txt
```

Add to `.env`:

```
HARVEY_TOKEN=your_harvey_token
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key
```

### Import Master-data (once, then monthly)

Place `Master-data.xlsx` in this folder (close Excel before importing), then:

```powershell
py -3 scripts/import_hr_excel.py --hr-file "Master-data.xlsx"
```

The import upserts `hr_employees` with access state (`granted`, `pending`, `revoked`, `resigned`) and refreshes the dashboard cache. The **Adoption** tab compares this master list against Harvey usage.

### Export usage data (IST-aligned, matches Harvey UI)

All date ranges use **IST (Asia/Kolkata)** calendar boundaries by default — the same as Harvey admin Export Analysis. See [`HARVEY_USAGE_DATA_ALIGNMENT.md`](HARVEY_USAGE_DATA_ALIGNMENT.md) for background.

```powershell
# Full calendar month
py -3 harvey_usage_export.py --month 2026-04 --archive --output harvey_usage_enriched_2026-04-01_to_2026-04-30.csv

# Custom range (inclusive start, exclusive end — end = day after last inclusive day)
py -3 harvey_usage_export.py --start 2026-01-01 --end 2026-06-25 --output harvey_usage_enriched_2026-01-01_to_2026-06-24.csv --archive
```

Validate against a Harvey UI xlsx export:

```powershell
py -3 compare_usage.py --api harvey_usage_enriched_2026-04-01_to_2026-04-30.csv --ui harvey-usage-start_2026-04-01_end_2026-04-30.xlsx
```

### Bulk import existing CSV (one-time or re-import after IST fix)

```powershell
py -3 scripts/bulk_import_csv.py --csv harvey_usage_enriched_2026-01-01_to_2026-06-24.csv
```

This may take 10–20 minutes for ~197k rows. Re-import upserts on `unique_usage_id` — no truncate needed.

### Test daily sync locally

```powershell
py -3 harvey_usage_sync.py
```

Daily sync fetches **IST yesterday** with the correct UTC API window.

---

## Step 4: Push to GitHub

1. Create a **private** repository on GitHub.
2. Push this folder (CSV and `.env` are gitignored).
3. Add **Repository secrets** (Settings → Secrets → Actions):

| Secret | Value |
|--------|-------|
| `HARVEY_TOKEN` | Harvey API bearer token |
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key (daily sync) |
| `SUPABASE_ANON_KEY` | Anon public key (dashboard) |

---

## Step 5: Enable GitHub Pages

1. **Settings → Pages → Build and deployment**
2. Source: **GitHub Actions** (not “Deploy from branch”).
3. Push to `main` — the `deploy-pages.yml` workflow builds and deploys automatically.
4. Your dashboard URL: `https://YOUR_USERNAME.github.io/YOUR_REPO/`

---

## Step 6: Verify

1. Open the Pages URL — you should see the login screen.
2. Sign in with an invited email (magic link).
3. Confirm KPIs, charts, and table load.
4. Check **Actions → Daily Harvey Usage Sync** runs daily (or trigger manually).

---

## Local dashboard testing

For local dev without GitHub Pages deploy:

```powershell
copy config.js.example config.js
# Edit config.js with your Supabase URL and anon key
py -3 -m http.server 5500
```

Open `http://localhost:5500/dashboard_redesigned.html` and add that URL to Supabase Auth redirect URLs.

---

## Monthly Master-data refresh

When HR sends an updated `Master-data.xlsx`:

```powershell
py -3 scripts/import_hr_excel.py --hr-file "Master-data.xlsx"
```

Future daily syncs will join against the updated `hr_employees` table. Re-open the dashboard **Adoption** tab to see updated access and inactive-user metrics.

### Team / Practice reports

After running [`supabase/team_report.sql`](supabase/team_report.sql) in the Supabase SQL Editor:

1. Open the dashboard **Reports** tab.
2. Choose **Team report** (single team) or **Practice report** (all teams in a practice).
3. Select practice, team (if applicable), and date range — or use presets (10 days, 30 days, 3 months).
4. Click **Generate Report**, then **Download Excel** or **Download PDF**.

Reports match the layout of `Report-Template.xlsx` and include adoption metrics for leadership.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| “Authentication required” on dashboard | User must be invited in Supabase Auth |
| Magic link redirect fails | Add exact Pages URL to Supabase redirect URLs |
| Daily sync fails | Check `HARVEY_TOKEN` secret; view Actions logs |
| Empty dashboard | Run bulk import; verify `sync_metadata.max_date` in Supabase |
| HR merge shows unmatched | Re-run `import_hr_excel.py` with latest Master-data.xlsx |
| Adoption tab empty or errors | Run `supabase/master_data_adoption.sql` in SQL Editor, then re-import Master-data |
| Reports tab fails to generate | Run `supabase/team_report.sql` in SQL Editor |
| Dashboard totals differ from Harvey UI | Ensure exports use IST (default). Re-export and bulk re-import. See [`HARVEY_USAGE_DATA_ALIGNMENT.md`](HARVEY_USAGE_DATA_ALIGNMENT.md) |
| Month-edge daily counts look wrong | Filter/group by `usage_date` (IST), not UTC date of `utc_time` |

---

## Files reference

| File | Purpose |
|------|---------|
| `harvey_usage_sync.py` | Daily IST sync to Supabase (GitHub Actions) |
| `harvey_usage_export.py` | IST-aligned CSV export + HR merge |
| `compare_usage.py` | Validate API CSV vs Harvey UI xlsx |
| `HARVEY_USAGE_DATA_ALIGNMENT.md` | UTC vs IST alignment context and verification |
| `scripts/bulk_import_csv.py` | CSV → Supabase bulk upsert |
| `scripts/import_hr_excel.py` | Master-data Excel → Supabase `hr_employees` |
| `supabase/master_data_adoption.sql` | Adoption RPCs + extended `hr_employees` columns |
| `supabase/team_report.sql` | Team/practice report RPC (`get_team_report_bundle`) |
| `index.html` | GitHub Pages entry point |
| `dashboard_redesigned.html` | Same dashboard (local dev) |
| `.github/workflows/daily-sync.yml` | Cron: fetch IST yesterday (5×/day for retries) |
| `.github/workflows/deploy-pages.yml` | Deploy dashboard to GitHub Pages |
