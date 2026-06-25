# Harvey Usage Data Alignment — Context for Agents & Dashboard

> **Purpose:** This document explains why Harvey API exports and Harvey UI (“Export Analysis”) exports previously disagreed, what was changed to fix it, and how to verify alignment. Add this file to the dashboard project (`WebAPP-Harvey`) so future agents and developers have full context without re-investigating.

---

## 1. Problem Summary

Khaitan & Co tracks Harvey AI usage from **two sources**:

| Source | How it is obtained | Typical file |
|--------|-------------------|--------------|
| **API export** | Python script calls `GET /api/v2/history/usage`, merges HR data | `harvey_usage_enriched_YYYY-MM-DD_to_YYYY-MM-DD.csv` |
| **UI export** | Harvey admin portal → Export Analysis | `harvey-usage-start_YYYY-MM-DD_end_YYYY-MM-DD.xlsx` |

In **June 2026**, April 2026 data was compared and showed a mismatch:

| Metric | API (before fix) | Harvey UI |
|--------|------------------|-----------|
| Row count | 27,614 | 27,520 |
| Only in API | 122 | — |
| Only in UI | — | 28 |
| Shared records with identical fields | 27,492 | 27,492 |

**Important:** The 27,492 overlapping records were **100% identical** on all Harvey fields (`user`, `action`, `utc_time`, `unique_usage_id`, etc.). Neither source had corrupt or wrong event data.

---

## 2. Root Cause — Timezone Month Boundaries (UTC vs IST)

The discrepancy was **not bad data**. It was a **date-range definition mismatch**.

### Harvey UI Export Analysis

Uses **IST (Asia/Kolkata, UTC+5:30) calendar boundaries**.

Example for “April 2026”:

- **Local start:** 2026-04-01 00:00:00 IST  
- **Local end (exclusive):** 2026-05-01 00:00:00 IST  
- **Equivalent UTC window:** 2026-03-31 18:30 UTC → 2026-04-30 18:30 UTC  

### Original API Script (before fix)

Used **UTC midnight boundaries** via `--start` / `--end` date strings:

- **Start:** 2026-04-01 00:00:00 UTC  
- **End (exclusive):** 2026-05-01 00:00:00 UTC  

### What that caused

| Records | UTC time | IST date | In UI “April”? | In old API “April”? |
|---------|----------|----------|----------------|---------------------|
| 28 UI-only rows | 2026-03-31 18:30 – 20:53 | 2026-04-01 | Yes | No (before API start) |
| 122 API-only rows | 2026-04-30 18:30 – 23:47 | 2026-05-01 | No | Yes (before API end) |

**Net difference:** 122 − 28 = **94 rows** (matches daily net diff).

### Secondary note — daily totals in comparison reports

Even after a perfect row-level match, **day-by-day counts** can look different in comparison CSVs because:

- API enriched CSV uses **`usage_date` derived in IST** (after fix).
- UI xlsx has **UTC Time** column; naive daily grouping by UTC date differs from IST `usage_date` at month edges.

**Row-level comparison on `unique_usage_id` is the correct validation method.** Net daily diff should still be **0** when aligned.

---

## 3. Solution — Align API Export to Harvey UI

Script updated: **`harvey_usage_export.py`** (in `check_data_discrepancy/`; should be synced to `WebAPP-Harvey/` if used for dashboard ingestion).

### 3.1 Key behavioural changes

| Change | Before | After |
|--------|--------|-------|
| Default timezone | UTC midnight | **`Asia/Kolkata` (IST)** |
| `--start` / `--end` meaning | UTC calendar dates | **Local (IST) calendar dates**; `--end` is exclusive |
| API fetch timestamps | Parsed as UTC midnight | **Converted from local timezone to UTC** before calling Harvey API |
| `usage_date` / `usage_hour` columns | Derived from UTC | **Derived from IST** |
| New flag | — | **`--month YYYY-MM`** for full calendar month |
| New flag | — | **`--timezone`** (default `Asia/Kolkata`; use `UTC` for legacy behaviour) |
| `.env` loading | Script directory only | Script dir **+ parent directory** |

### 3.2 How local dates map to UTC for the Harvey API

Harvey API parameters `start_time` / `end_time` are **Unix epochs in UTC**.

For IST range `[local_start, local_end)`:

```
start_time = local_start.astimezone(UTC)
end_time   = local_end.astimezone(UTC)   # exclusive
```

**Example — April 2026 (IST):**

```
Local:  2026-04-01 00:00 IST  →  2026-05-01 00:00 IST (exclusive)
UTC:    2026-03-31 18:30 UTC  →  2026-04-30 18:30 UTC (exclusive)
```

**Example — 1 Jan 2026 to 24 Jun 2026 inclusive (IST):**

```
--start 2026-01-01 --end 2026-06-25
Local:  2026-01-01 00:00 IST  →  2026-06-25 00:00 IST (exclusive)
UTC:    2025-12-31 18:30 UTC  →  2026-06-24 18:30 UTC (exclusive)
```

### 3.3 Comparison tooling added

**`compare_usage.py`** — validates API CSV vs UI xlsx:

- Join key: **`unique_usage_id`**
- Compares Harvey core fields: `user`, `action`, `product_surface_area`, `access_point`, `source`, `workflow_name`, `utc_time`
- Ignores HR-only columns present only in enriched CSV (`Workforce Name`, `Team`, etc.)
- Writes discrepancy CSVs when mismatches exist
- Exit code **0** = exact match; **1** = discrepancies remain

---

## 4. Verification Results (after fix)

### 4.1 April 2026

| Check | API (IST-aligned) | Harvey UI |
|-------|-------------------|-----------|
| Rows | 27,520 | 27,520 |
| Unique `unique_usage_id` | 27,520 | 27,520 |
| Only in API | 0 | — |
| Only in UI | 0 | — |
| Field mismatches | 0 | 0 |
| Unique users | 221 | 221 |

**Result: PASS — exact match**

Files:

- API: `harvey_usage_enriched_2026-04-01_to_2026-04-30.csv`
- UI: `harvey-usage-start_2026-04-01_end_2026-04-30.xlsx`

### 4.2 January 1 – June 24, 2026

| Check | API (IST-aligned) | Harvey UI |
|-------|-------------------|-----------|
| Rows | 197,429 | 197,429 |
| Unique `unique_usage_id` | 197,429 | 197,429 |
| Only in API | 0 | — |
| Only in UI | 0 | — |
| Field mismatches | 0 | 0 |
| `utc_time` exact match | 197,429 / 197,429 | — |
| Unique users | 686 | 686 |
| UTC time range | 2026-01-02 06:54:11 → 2026-06-24 18:29:27 | Same |

**Result: PASS — exact match**

Files:

- API: `harvey_usage_enriched_2026-01-01_to_2026-06-24.csv` (~139 MB, HR-enriched)
- UI: `harvey-usage-start_2026-01-01_end_2026-06-24.xlsx`

HR merge on full-range export: **194,686 matched**, **2,743 unmatched** (see `unmatched_emails.csv`).

---

## 5. Which Source Is Authoritative?

| Need | Recommended source |
|------|-------------------|
| Match Harvey admin Export Analysis | UI export **or** IST-aligned API export |
| Dashboard / Power BI / Supabase pipeline | **IST-aligned API export** (more columns, HR merge, `file_ids`, automatable) |
| Event-level audit / re-fetch | Harvey API (`/api/v2/history/usage`) |
| Billing month in India | **IST calendar month** (same as Harvey UI) |

**After the fix, both sources contain the same Harvey events when the same IST date range is used.** Prefer API export for the dashboard because it includes HR enrichment and integrates with existing scripts.

---

## 6. Commands — Export & Compare

Working directory:

```
check_data_discrepancy/
```

Requires `HARVEY_TOKEN` in `.env` (script dir or parent `Usages_Data_Harvey/.env`).

### Export one calendar month (IST, matches UI)

```powershell
py -3 harvey_usage_export.py --month 2026-04 --archive --output harvey_usage_enriched_2026-04-01_to_2026-04-30.csv
```

### Export custom IST date range

```powershell
# Inclusive start, exclusive end (local IST dates)
py -3 harvey_usage_export.py --start 2026-01-01 --end 2026-06-25 --output harvey_usage_enriched_2026-01-01_to_2026-06-24.csv
```

### Compare API CSV vs UI xlsx

```powershell
py -3 compare_usage.py `
  --api harvey_usage_enriched_2026-01-01_to_2026-06-24.csv `
  --ui harvey-usage-start_2026-01-01_end_2026-06-24.xlsx
```

Expected output line:

```
PASS: Exact match — same records and counts in both sources.
```

### Legacy UTC behaviour (not recommended for UI parity)

```powershell
py -3 harvey_usage_export.py --start 2026-04-01 --end 2026-05-01 --timezone UTC
```

---

## 7. File Naming Conventions

| Pattern | Meaning |
|---------|---------|
| `harvey_usage_enriched_2026-04-01_to_2026-04-30.csv` | API + HR enriched export; dates are **IST inclusive range labels** |
| `harvey-usage-start_2026-04-01_end_2026-04-30.xlsx` | Harvey UI Export Analysis download |
| `unmatched_emails.csv` | API rows where `user` email did not match HR Active List |
| `discrepancy_*.csv` | Output from `compare_usage.py` when investigating mismatches |

---

## 8. API Export Schema (enriched CSV)

Harvey fields (align with UI):

- `utc_time`, `user`, `unique_usage_id`, `access_point`, `action`, `product_surface_area`, `workflow_name`, `source`, `subsurface`, `cm_id`, `parent_thread_id`, `space_name`, `playbook_name`, `vault_project_name`, `review_table_name`, `file_count`, `file_ids`

Derived fields:

- `usage_date` — **IST calendar date** (after fix)
- `usage_hour` — **IST hour** (after fix)

HR fields (API only, left join on email):

- `Workforce Id`, `Workforce Name`, `Location`, `Date of Joining`, `Designation`, `Team`, `Practice/ Function`, `Email`, `Reporting Manager Name`

---

## 9. Harvey API Constraints (unchanged)

- Base URL: `https://eu.api.harvey.ai`
- Endpoint: `/api/v2/history/usage`
- Max range per request: **30 days** (script chunks automatically)
- `end_time` parameter is **exclusive**
- Rate limiting (HTTP 429) handled with retries

---

## 10. Dashboard Project Implications

For **`WebAPP-Harvey`** / Supabase / Power BI:

1. **Use IST-aligned exports** for all new data pulls so totals match Harvey UI.
2. **Filter and group by `usage_date`** (IST) in dashboards, not raw UTC date of `utc_time`, for consistency with business reporting.
3. **`unique_usage_id`** is the primary key for deduplication and UI/API reconciliation.
4. If totals disagree with Harvey UI, first check:
   - Was export run with `--timezone Asia/Kolkata` (default)?
   - Does `--end` use the day **after** the last inclusive day?
   - Are you comparing row counts via `unique_usage_id`, not UTC-day aggregates?
5. Sync updated `harvey_usage_export.py` into the dashboard repo if it still uses the old UTC-only version.

---

## 11. Timeline of Work (June 2026)

1. Compared April 2026 API CSV vs UI xlsx → found 122 / 28 row edge mismatch.
2. Identified root cause: UTC vs IST month boundaries; shared records were identical.
3. Updated `harvey_usage_export.py` with IST timezone support and `--month`.
4. Re-exported April 2026 → **exact match** with UI (27,520 rows).
5. Exported Jan 1 – Jun 24, 2026 → 197,429 rows.
6. Compared full-range API vs UI export → **exact match** (197,429 rows, 686 users).
7. Added/fixed `compare_usage.py` for repeatable validation.

---

## 12. Quick FAQ for Agents

**Q: Why did API show more rows than UI for April before the fix?**  
A: API included 122 events on UTC Apr 30 evening that fall on IST May 1.

**Q: Why did UI show rows API did not have?**  
A: UI included 28 events on UTC Mar 31 evening that fall on IST Apr 1; old API started at Apr 1 UTC.

**Q: Is Harvey UI or API more reliable?**  
A: Same underlying events. Use IST-aligned API export for automation; UI export is the reference for what Harvey’s portal displays.

**Q: How do I confirm two files match?**  
A: Run `compare_usage.py` on `unique_usage_id`. PASS = zero rows only in one source and zero field mismatches.

**Q: Why do daily comparison CSVs show diffs but PASS still succeeds?**  
A: Daily grouping uses different date columns (IST `usage_date` vs UTC). Row-level ID comparison is authoritative.

---

*Last updated: 2026-06-25. Verified against Harvey EU API and Export Analysis UI exports for Khaitan & Co.*
