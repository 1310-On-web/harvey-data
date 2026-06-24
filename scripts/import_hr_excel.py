"""
Import HR Active List Excel into Supabase hr_employees table.

Usage:
    py -3 scripts/import_hr_excel.py
    py -3 scripts/import_hr_excel.py --hr-file "Active List_15 June 26.xlsx"
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from db_utils import get_supabase_client, hr_dataframe_to_records, upsert_hr_records  # noqa: E402


def parse_args():
    parser = argparse.ArgumentParser(description="Import HR Excel to Supabase")
    parser.add_argument(
        "--hr-file",
        default="Active List_15 June 26.xlsx",
        help="HR Active List xlsx filename or path",
    )
    return parser.parse_args()


def main() -> int:
    load_dotenv(ROOT / ".env")
    args = parse_args()

    hr_path = Path(args.hr_file)
    if not hr_path.is_absolute():
        hr_path = ROOT / hr_path
    if not hr_path.exists():
        print(f"HR file not found: {hr_path}", file=sys.stderr)
        print("Place the Active List xlsx in the WebAPP-Harvey folder or pass --hr-file.", file=sys.stderr)
        return 1

    print(f"Loading {hr_path}...")
    hr_df = pd.read_excel(hr_path)
    records = hr_dataframe_to_records(hr_df)
    print(f"Prepared {len(records):,} HR records")

    client = get_supabase_client()
    upsert_hr_records(client, records)
    print("HR import complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
