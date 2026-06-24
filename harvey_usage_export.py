"""
Export Harvey usage from API, merge with HR Active List, write enriched CSV.

Usage:
    py -3 harvey_usage_export.py
        Daily run (no args): fetch yesterday and append to the output CSV.

    py -3 harvey_usage_export.py --date 2026-06-23
        Fetch one day and append to the output CSV.

    py -3 harvey_usage_export.py --start 2026-05-01 --end 2026-06-01
    py -3 harvey_usage_export.py --start 2026-04-01 --end 2026-05-01 --append
    py -3 harvey_usage_export.py --start 2026-06-01 --end 2026-06-24 --output harvey_usage_enriched.csv --archive

Harvey API end_time is exclusive — use the first day of the month AFTER your range
(e.g. --end 2026-06-01 to include all of May 2026).

Use --append with --start/--end to merge a new date range into an existing output CSV
(deduped on unique_usage_id) instead of overwriting it — useful for adding prior months.
"""

import argparse
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd
import requests
import urllib3
from dotenv import load_dotenv

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

BASE_URL = "https://eu.api.harvey.ai"
INCLUDE_FILE_IDS = True
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_HR_FILE = "Active List_15 June 26.xlsx"
DEFAULT_OUTPUT = "harvey_usage_enriched.csv"
UNMATCHED_FILE = "unmatched_emails.csv"
MAX_RANGE_DAYS = 30  # Harvey API: time range must be within 30 days


def parse_args():
    parser = argparse.ArgumentParser(description="Export Harvey usage enriched with HR data")
    parser.add_argument(
        "--date",
        help="Single day YYYY-MM-DD (inclusive); appends to output CSV",
    )
    parser.add_argument("--start", help="Start date YYYY-MM-DD (inclusive); requires --end")
    parser.add_argument("--end", help="End date YYYY-MM-DD (exclusive, API); requires --start")
    parser.add_argument(
        "--hr-file",
        default=DEFAULT_HR_FILE,
        help=f"HR Active List xlsx (default: {DEFAULT_HR_FILE})",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"Output CSV path (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--archive",
        action="store_true",
        help="Also save dated copy harvey_usage_enriched_START_to_END.csv (new chunk only)",
    )
    parser.add_argument(
        "--append",
        action="store_true",
        help="With --start/--end: merge into existing output instead of overwriting",
    )
    return parser.parse_args()


def resolve_date_range(args) -> tuple[str, str, bool]:
    """Return (start, end_exclusive, append). Default: yesterday, append=True."""
    if args.date:
        if args.start or args.end:
            raise SystemExit("Use either --date or --start/--end, not both.")
        day = datetime.strptime(args.date, "%Y-%m-%d").date()
        start = day.strftime("%Y-%m-%d")
        end = (day + timedelta(days=1)).strftime("%Y-%m-%d")
        return start, end, True

    if args.start or args.end:
        if not args.start or not args.end:
            raise SystemExit("--start and --end must be used together.")
        return args.start, args.end, args.append

    yesterday = datetime.now(timezone.utc).date() - timedelta(days=1)
    start = yesterday.strftime("%Y-%m-%d")
    end = (yesterday + timedelta(days=1)).strftime("%Y-%m-%d")
    return start, end, True


def to_epoch(date_string: str) -> int:
    dt = datetime.strptime(date_string, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def archive_path(start: str, end: str) -> str:
    end_inclusive = (datetime.strptime(end, "%Y-%m-%d") - timedelta(days=1)).strftime("%Y-%m-%d")
    return f"harvey_usage_enriched_{start}_to_{end_inclusive}.csv"


def fetch_usage(headers: dict, start_time: int, end_time: int) -> dict:
    url = f"{BASE_URL}/api/v2/history/usage"
    params = {
        "start_time": start_time,
        "end_time": end_time,
        "include_file_ids": INCLUDE_FILE_IDS,
    }

    for attempt in range(5):
        try:
            response = requests.get(
                url,
                headers=headers,
                params=params,
                timeout=120,
                verify=False,
            )
            print(f"Status: {response.status_code}")

            if response.status_code == 429:
                retry_after = int(response.headers.get("Retry-After", "60"))
                print(f"Rate limited. Waiting {retry_after} seconds...")
                time.sleep(retry_after)
                continue

            if response.status_code != 200:
                print(response.text)

            response.raise_for_status()
            return response.json()

        except requests.exceptions.Timeout:
            print(f"Timeout ({attempt + 1}/5)")
            time.sleep(10)

        except requests.exceptions.RequestException as e:
            print(f"Request failed: {e}")
            raise

    raise Exception("Maximum retries exceeded")


def fetch_usage_range(headers: dict, start_date: str, end_date: str) -> list:
    """Fetch all events between start (inclusive) and end (exclusive), chunking by MAX_RANGE_DAYS."""
    start_dt = datetime.strptime(start_date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    end_dt = datetime.strptime(end_date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    all_events: list = []
    seen_ids: set = set()
    chunk_start = start_dt

    while chunk_start < end_dt:
        chunk_end = min(chunk_start + timedelta(days=MAX_RANGE_DAYS), end_dt)
        label = f"{chunk_start.date()} -> {chunk_end.date()}"
        print(f"  Chunk: {label}")
        data = fetch_usage(headers, int(chunk_start.timestamp()), int(chunk_end.timestamp()))
        for event in data.get("events", []):
            uid = event.get("unique_usage_id")
            if uid and uid in seen_ids:
                continue
            if uid:
                seen_ids.add(uid)
            all_events.append(event)
        chunk_start = chunk_end

    return all_events


def flatten_event(event: dict) -> dict:
    file_ids = event.get("file_ids", [])
    utc_time = event.get("utc_time", "")
    usage_date = ""
    usage_hour = ""

    try:
        dt = pd.to_datetime(utc_time)
        usage_date = dt.date()
        usage_hour = dt.hour
    except Exception:
        pass

    return {
        "utc_time": utc_time,
        "usage_date": usage_date,
        "usage_hour": usage_hour,
        "user": event.get("user"),
        "unique_usage_id": event.get("unique_usage_id"),
        "access_point": event.get("access_point"),
        "action": event.get("action"),
        "product_surface_area": event.get("product_surface_area"),
        "workflow_name": event.get("workflow_name"),
        "source": event.get("source"),
        "subsurface": event.get("subsurface"),
        "cm_id": event.get("cm_id"),
        "parent_thread_id": event.get("parent_thread_id"),
        "space_name": event.get("space_name"),
        "playbook_name": event.get("playbook_name"),
        "vault_project_name": event.get("vault_project_name"),
        "review_table_name": event.get("review_table_name"),
        "file_count": len(file_ids),
        "file_ids": ";".join(file_ids),
    }


def merge_with_existing(output_path: Path, new_df: pd.DataFrame) -> pd.DataFrame:
    """Append new rows to an existing CSV, dropping duplicate unique_usage_id (new wins)."""
    if not output_path.exists():
        print(f"No existing file at {output_path} — writing new data only")
        return new_df

    print(f"\nLoading existing data: {output_path}")
    existing_df = pd.read_csv(output_path, encoding="utf-8-sig", low_memory=False)
    print(f"Existing rows: {len(existing_df):,}")

    combined = pd.concat([existing_df, new_df], ignore_index=True)
    before_dedupe = len(combined)
    combined = combined.drop_duplicates(subset=["unique_usage_id"], keep="last")
    dropped = before_dedupe - len(combined)
    if dropped:
        print(f"Dropped {dropped:,} duplicate unique_usage_id rows")

    sort_col = "utc_time" if "utc_time" in combined.columns else "usage_date"
    if sort_col in combined.columns:
        combined = combined.sort_values(sort_col, kind="mergesort").reset_index(drop=True)

    print(f"Merged total: {len(combined):,} rows (+{len(new_df):,} new)")
    return combined


def load_hr_data(hr_file: Path) -> pd.DataFrame:
    print(f"\nLoading HR File: {hr_file}")
    hr_df = pd.read_excel(hr_file)
    hr_df.columns = hr_df.columns.astype(str).str.strip()
    hr_df["Email"] = hr_df["Email"].astype(str).str.strip().str.lower()
    if "Date of Joining" in hr_df.columns:
        hr_df["Date of Joining"] = pd.to_datetime(
            hr_df["Date of Joining"], errors="coerce"
        ).dt.strftime("%Y-%m-%d")
    print(f"HR records loaded: {len(hr_df):,}")
    return hr_df


def normalize_date_columns(df: pd.DataFrame) -> pd.DataFrame:
    """Ensure date columns are YYYY-MM-DD strings for Power BI import."""
    if "Date of Joining" in df.columns:
        df["Date of Joining"] = pd.to_datetime(
            df["Date of Joining"], errors="coerce"
        ).dt.strftime("%Y-%m-%d")
    if "usage_date" in df.columns:
        df["usage_date"] = pd.to_datetime(df["usage_date"], errors="coerce").dt.strftime(
            "%Y-%m-%d"
        )
    return df


def main() -> int:
    load_dotenv(SCRIPT_DIR / ".env")
    args = parse_args()
    start, end, append = resolve_date_range(args)

    token = os.environ.get("HARVEY_TOKEN")
    if not token:
        print("HARVEY_TOKEN not found. Set it in .env or environment.", file=sys.stderr)
        return 1

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }

    hr_path = Path(args.hr_file)
    if not hr_path.is_absolute():
        hr_path = SCRIPT_DIR / hr_path
    if not hr_path.exists():
        print(f"HR file not found: {hr_path}", file=sys.stderr)
        return 1

    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = SCRIPT_DIR / output_path

    print("\nFetching Harvey Usage...")
    print(f"Date Range: {start} -> {end} (end exclusive)")
    if append:
        print("Mode: append to existing output")

    events = fetch_usage_range(headers, start, end)
    print(f"Retrieved {len(events):,} events (all chunks)")

    if not events:
        print(f"No usage records found for {start}.")
        return 0 if append else 1

    harvey_df = pd.DataFrame([flatten_event(e) for e in events])
    harvey_df["user"] = harvey_df["user"].astype(str).str.strip().str.lower()

    # Drop rows without a valid unique_usage_id (required for Power BI relationships)
    before = len(harvey_df)
    harvey_df = harvey_df[
        harvey_df["unique_usage_id"].notna()
        & (harvey_df["unique_usage_id"].astype(str).str.strip() != "")
    ]
    dropped = before - len(harvey_df)
    if dropped:
        print(f"Dropped {dropped:,} rows with missing unique_usage_id")

    hr_df = load_hr_data(hr_path)

    print("\nMerging HR Data...")
    final_df = harvey_df.merge(hr_df, how="left", left_on="user", right_on="Email")

    matched = final_df["Workforce Name"].notna().sum()
    print(f"Matched Records: {matched:,}")
    print(f"Unmatched Records: {len(final_df) - matched:,}")

    if "usage_date" in final_df.columns and final_df["usage_date"].notna().any():
        dates = pd.to_datetime(final_df["usage_date"])
        print(f"Data date range: {dates.min().date()} to {dates.max().date()}")

    print("\nTop 10 Harvey Users")
    print(final_df.groupby("user").size().sort_values(ascending=False).head(10))

    new_chunk_df = final_df
    if append:
        final_df = merge_with_existing(output_path, new_chunk_df)

    final_df = normalize_date_columns(final_df)

    final_df.to_csv(output_path, index=False, encoding="utf-8-sig")
    print(f"\n{'Updated' if append else 'Created'}: {output_path}")

    if args.archive:
        archive = SCRIPT_DIR / archive_path(start, end)
        normalize_date_columns(new_chunk_df.copy()).to_csv(archive, index=False, encoding="utf-8-sig")
        print(f"Archived new chunk: {archive}")

    unmatched_df = final_df[final_df["Workforce Name"].isna()]
    if len(unmatched_df) > 0:
        unmatched_path = SCRIPT_DIR / UNMATCHED_FILE
        unmatched_df.to_csv(unmatched_path, index=False, encoding="utf-8-sig")
        print(f"Created: {unmatched_path}")

    print("\nExport Complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
