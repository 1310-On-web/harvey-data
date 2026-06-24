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

### Import HR master data (once, then monthly)

Place `Active List_15 June 26.xlsx` in this folder, then:

```powershell
py -3 scripts/import_hr_excel.py --hr-file "Active List_15 June 26.xlsx"
```

### Bulk import existing CSV (one-time)

```powershell
py -3 scripts/bulk_import_csv.py --csv harvey_usage_enriched.csv
```

This may take 10–20 minutes for ~193k rows.

### Test daily sync locally

```powershell
py -3 harvey_usage_sync.py
```

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

## Monthly HR refresh

When HR sends an updated Active List:

```powershell
py -3 scripts/import_hr_excel.py --hr-file "Active List_NEW_DATE.xlsx"
```

Future daily syncs will join against the updated `hr_employees` table.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| “Authentication required” on dashboard | User must be invited in Supabase Auth |
| Magic link redirect fails | Add exact Pages URL to Supabase redirect URLs |
| Daily sync fails | Check `HARVEY_TOKEN` secret; view Actions logs |
| Empty dashboard | Run bulk import; verify `sync_metadata.max_date` in Supabase |
| HR merge shows unmatched | Re-run `import_hr_excel.py` with latest Active List |

---

## Files reference

| File | Purpose |
|------|---------|
| `harvey_usage_sync.py` | Daily sync to Supabase (GitHub Actions) |
| `harvey_usage_export.py` | Local CSV export (unchanged) |
| `scripts/bulk_import_csv.py` | One-time CSV → Supabase migration |
| `scripts/import_hr_excel.py` | HR Excel → Supabase |
| `index.html` | GitHub Pages entry point |
| `dashboard_redesigned.html` | Same dashboard (local dev) |
| `.github/workflows/daily-sync.yml` | Cron: fetch yesterday once/day |
| `.github/workflows/deploy-pages.yml` | Deploy dashboard to GitHub Pages |
