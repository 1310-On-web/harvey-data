"""
Daily Harvey usage sync to Supabase.

Fetches yesterday's usage from Harvey API using IST calendar boundaries (default),
merges with hr_employees in Supabase, and upserts into usage_events (file_ids excluded).

See HARVEY_USAGE_DATA_ALIGNMENT.md for timezone details.

Usage:
    py -3 harvey_usage_sync.py
    py -3 harvey_usage_sync.py --date 2026-06-23
    py -3 harvey_usage_sync.py --timezone UTC

Environment:
    HARVEY_TOKEN
    SUPABASE_URL
    SUPABASE_SERVICE_ROLE_KEY
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv

from db_utils import (
    dataframe_to_usage_records,
    get_supabase_client,
    load_hr_from_supabase,
    update_sync_metadata,
    upsert_usage_batch,
)
from harvey_usage_export import (
    DEFAULT_TZ,
    fetch_usage_range,
    flatten_event,
    load_env,
    local_yesterday,
    resolve_timezone,
)

SCRIPT_DIR = Path(__file__).resolve().parent


def parse_args():
    parser = argparse.ArgumentParser(description="Sync Harvey usage to Supabase")
    parser.add_argument(
        "--date",
        help="Single IST calendar day YYYY-MM-DD (default: IST yesterday)",
    )
    parser.add_argument(
        "--timezone",
        default=DEFAULT_TZ,
        help=f"IANA timezone for date boundaries (default: {DEFAULT_TZ})",
    )
    return parser.parse_args()


def resolve_date_range(args, tz) -> tuple[str, str]:
    if args.date:
        day = datetime.strptime(args.date, "%Y-%m-%d").date()
        start = day.strftime("%Y-%m-%d")
        end = (day + timedelta(days=1)).strftime("%Y-%m-%d")
        return start, end

    yesterday = local_yesterday(tz)
    start = yesterday.strftime("%Y-%m-%d")
    end = (yesterday + timedelta(days=1)).strftime("%Y-%m-%d")
    return start, end


def flatten_event_no_file_ids(event: dict, tz) -> dict:
    row = flatten_event(event, tz)
    row.pop("file_ids", None)
    return row


def main() -> int:
    load_env()
    args = parse_args()
    tz = resolve_timezone(args.timezone)
    start, end = resolve_date_range(args, tz)

    token = os.environ.get("HARVEY_TOKEN")
    if not token:
        print("HARVEY_TOKEN not found.", file=sys.stderr)
        return 1

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }

    client = get_supabase_client()

    print("\nLoading HR data from Supabase...")
    hr_df = load_hr_from_supabase(client)
    print(f"HR records: {len(hr_df):,}")

    print("\nFetching Harvey usage...")
    print(f"Timezone: {args.timezone}")
    print(f"Date range: {start} -> {end} (local, end exclusive)")

    events = fetch_usage_range(headers, start, end, tz)
    print(f"Retrieved {len(events):,} events")

    if not events:
        print("No new usage records.")
        update_sync_metadata(client, 0)
        return 0

    harvey_df = pd.DataFrame([flatten_event_no_file_ids(e, tz) for e in events])
    harvey_df["user"] = harvey_df["user"].astype(str).str.strip().str.lower()

    before = len(harvey_df)
    harvey_df = harvey_df[
        harvey_df["unique_usage_id"].notna()
        & (harvey_df["unique_usage_id"].astype(str).str.strip() != "")
    ]
    dropped = before - len(harvey_df)
    if dropped:
        print(f"Dropped {dropped:,} rows with missing unique_usage_id")

    print("\nMerging HR data...")
    final_df = harvey_df.merge(hr_df, how="left", left_on="user", right_on="Email")

    matched = final_df["Workforce Name"].notna().sum()
    print(f"Matched: {matched:,}, Unmatched: {len(final_df) - matched:,}")

    records = dataframe_to_usage_records(final_df)
    print(f"\nUpserting {len(records):,} rows to Supabase...")
    upsert_usage_batch(client, records)

    update_sync_metadata(client, len(records))
    print("\nSync complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
