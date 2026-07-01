"""
Import Master-data Excel into Supabase hr_employees table.

Usage:
    py -3 scripts/import_hr_excel.py
    py -3 scripts/import_hr_excel.py --hr-file "Master-data.xlsx"
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from db_utils import (  # noqa: E402
    get_supabase_client,
    hr_dataframe_to_records,
    refresh_dashboard_cache,
    upsert_hr_records,
)


def parse_args():
    parser = argparse.ArgumentParser(description="Import Master-data Excel to Supabase")
    parser.add_argument(
        "--hr-file",
        default="Master-data.xlsx",
        help="Master-data xlsx filename or path",
    )
    return parser.parse_args()


def main() -> int:
    load_dotenv(ROOT / ".env")
    args = parse_args()

    hr_path = Path(args.hr_file)
    if not hr_path.is_absolute():
        hr_path = ROOT / hr_path
    if not hr_path.exists():
        print(f"Master data file not found: {hr_path}", file=sys.stderr)
        print("Place Master-data.xlsx in the WebAPP-Harvey folder or pass --hr-file.", file=sys.stderr)
        return 1

    try:
        print(f"Loading {hr_path}...")
        hr_df = pd.read_excel(hr_path)
    except PermissionError:
        print(f"Cannot read {hr_path} — close the file in Excel and try again.", file=sys.stderr)
        return 1

    records = hr_dataframe_to_records(hr_df)
    print(f"Prepared {len(records):,} employee records")

    counts = Counter(r.get("access_state") for r in records)
    for state in ("granted", "pending", "revoked", "resigned"):
        print(f"  {state}: {counts.get(state, 0):,}")

    client = get_supabase_client()
    upsert_hr_records(client, records)
    print("Master data import complete.")
    refresh_dashboard_cache(client)
    return 0


if __name__ == "__main__":
    sys.exit(main())
