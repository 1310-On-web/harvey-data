"""
Export Harvey usage from API, merge with Master-data, write enriched CSV.

Date ranges use local calendar boundaries (default Asia/Kolkata / IST) to match
Harvey admin Export Analysis. See HARVEY_USAGE_DATA_ALIGNMENT.md for details.

Usage:
    py -3 harvey_usage_export.py
        Daily run (no args): fetch IST yesterday and append to the output CSV.

    py -3 harvey_usage_export.py --date 2026-06-23
        Fetch one IST calendar day and append to the output CSV.

    py -3 harvey_usage_export.py --month 2026-04 --archive
        Full IST calendar month (April 2026).

    py -3 harvey_usage_export.py --start 2026-01-01 --end 2026-06-25 --output out.csv
        IST inclusive start, exclusive end (end = day after last inclusive day).

    py -3 harvey_usage_export.py --start 2026-04-01 --end 2026-05-01 --timezone UTC
        Legacy UTC midnight boundaries (not recommended for Harvey UI parity).

Harvey API end_time is exclusive — use the first day AFTER your inclusive range
(e.g. --end 2026-05-01 to include all of April 2026 in IST).
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd
import requests
import urllib3
from dotenv import load_dotenv

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

BASE_URL = "https://eu.api.harvey.ai"
INCLUDE_FILE_IDS = True
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_HR_FILE = "Master-data.xlsx"
DEFAULT_OUTPUT = "harvey_usage_enriched.csv"
UNMATCHED_FILE = "unmatched_emails.csv"
DEFAULT_TZ = "Asia/Kolkata"
MAX_RANGE_DAYS = 30  # Harvey API: time range must be within 30 days


def load_env() -> None:
    load_dotenv(SCRIPT_DIR / ".env")
    load_dotenv(SCRIPT_DIR.parent / ".env")


def parse_args():
    parser = argparse.ArgumentParser(description="Export Harvey usage enriched with HR data")
    parser.add_argument(
        "--date",
        help="Single IST calendar day YYYY-MM-DD (inclusive); appends to output CSV",
    )
    parser.add_argument(
        "--month",
        help="Full calendar month YYYY-MM in local timezone (e.g. 2026-04)",
    )
    parser.add_argument(
        "--start",
        help="Start date YYYY-MM-DD inclusive in local timezone; requires --end",
    )
    parser.add_argument(
        "--end",
        help="End date YYYY-MM-DD exclusive in local timezone; requires --start",
    )
    parser.add_argument(
        "--timezone",
        default=DEFAULT_TZ,
        help=f"IANA timezone for date boundaries (default: {DEFAULT_TZ})",
    )
    parser.add_argument(
        "--hr-file",
        default=DEFAULT_HR_FILE,
        help=f"Master-data xlsx (default: {DEFAULT_HR_FILE})",
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


def resolve_timezone(tz_name: str) -> ZoneInfo:
    try:
        return ZoneInfo(tz_name)
    except Exception as exc:
        raise SystemExit(f"Invalid timezone: {tz_name!r} ({exc})") from exc


def local_yesterday(tz: ZoneInfo) -> date:
    now_local = datetime.now(tz)
    return (now_local - timedelta(days=1)).date()


def local_date_to_datetime(date_string: str, tz: ZoneInfo) -> datetime:
    """Parse YYYY-MM-DD as local midnight in tz."""
    d = datetime.strptime(date_string, "%Y-%m-%d").date()
    return datetime(d.year, d.month, d.day, tzinfo=tz)


def local_date_to_epoch(date_string: str, tz: ZoneInfo) -> int:
    return int(local_date_to_datetime(date_string, tz).timestamp())


def to_epoch(date_string: str, tz: ZoneInfo) -> int:
    return local_date_to_epoch(date_string, tz)


def resolve_date_range(args, tz: ZoneInfo) -> tuple[str, str, bool]:
    """Return (start, end_exclusive, append). Default: IST yesterday, append=True."""
    if args.month:
        if args.date or args.start or args.end:
            raise SystemExit("Use --month alone, or --date, or --start/--end.")
        year, month = map(int, args.month.split("-"))
        start_dt = date(year, month, 1)
        if month == 12:
            end_dt = date(year + 1, 1, 1)
        else:
            end_dt = date(year, month + 1, 1)
        return start_dt.isoformat(), end_dt.isoformat(), args.append

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

    yesterday = local_yesterday(tz)
    start = yesterday.strftime("%Y-%m-%d")
    end = (yesterday + timedelta(days=1)).strftime("%Y-%m-%d")
    return start, end, True


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


def fetch_usage_range(
    headers: dict,
    start_date: str,
    end_date: str,
    tz: ZoneInfo | None = None,
) -> list:
    """Fetch all events between local start (inclusive) and end (exclusive), chunking by MAX_RANGE_DAYS."""
    if tz is None:
        tz = ZoneInfo(DEFAULT_TZ)

    start_dt = local_date_to_datetime(start_date, tz)
    end_dt = local_date_to_datetime(end_date, tz)
    all_events: list = []
    seen_ids: set = set()
    chunk_start = start_dt

    while chunk_start < end_dt:
        chunk_end = min(chunk_start + timedelta(days=MAX_RANGE_DAYS), end_dt)
        start_utc = chunk_start.astimezone(timezone.utc)
        end_utc = chunk_end.astimezone(timezone.utc)
        label = f"{chunk_start.date()} -> {chunk_end.date()} local ({start_utc} -> {end_utc} UTC)"
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


def flatten_event(event: dict, tz: ZoneInfo | None = None) -> dict:
    if tz is None:
        tz = ZoneInfo(DEFAULT_TZ)

    file_ids = event.get("file_ids", [])
    utc_time = event.get("utc_time", "")
    usage_date = ""
    usage_hour = ""

    try:
        dt = pd.to_datetime(utc_time, utc=True)
        local_dt = dt.tz_convert(tz)
        usage_date = local_dt.date()
        usage_hour = local_dt.hour
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
    load_env()
    args = parse_args()
    tz = resolve_timezone(args.timezone)
    start, end, append = resolve_date_range(args, tz)

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
    print(f"Timezone: {args.timezone}")
    print(f"Date Range: {start} -> {end} (local, end exclusive)")
    if append:
        print("Mode: append to existing output")

    events = fetch_usage_range(headers, start, end, tz)
    print(f"Retrieved {len(events):,} events (all chunks)")

    if not events:
        print(f"No usage records found for {start}.")
        return 0 if append else 1

    harvey_df = pd.DataFrame([flatten_event(e, tz) for e in events])
    harvey_df["user"] = harvey_df["user"].astype(str).str.strip().str.lower()

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
        if archive.resolve() != output_path.resolve():
            normalize_date_columns(new_chunk_df.copy()).to_csv(
                archive, index=False, encoding="utf-8-sig"
            )
            print(f"Archived new chunk: {archive}")
        else:
            print(f"Archive skipped (same as output): {archive}")

    unmatched_df = final_df[final_df["Workforce Name"].isna()]
    if len(unmatched_df) > 0:
        unmatched_path = SCRIPT_DIR / UNMATCHED_FILE
        unmatched_df.to_csv(unmatched_path, index=False, encoding="utf-8-sig")
        print(f"Created: {unmatched_path}")

    print("\nExport Complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
