"""
Bootstrap hr_employees from an enriched CSV (when Excel is unavailable).

Usage:
    py -3 scripts/import_hr_from_csv.py
    py -3 scripts/import_hr_from_csv.py --csv harvey_usage_enriched.csv
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
    parser = argparse.ArgumentParser(description="Import HR records from enriched CSV")
    parser.add_argument(
        "--csv",
        default=str(ROOT / "harvey_usage_enriched.csv"),
        help="Path to harvey_usage_enriched.csv",
    )
    return parser.parse_args()


def main() -> int:
    load_dotenv(ROOT / ".env")
    args = parse_args()
    csv_path = Path(args.csv)
    if not csv_path.exists():
        print(f"CSV not found: {csv_path}", file=sys.stderr)
        return 1

    print(f"Reading {csv_path}...")
    df = pd.read_csv(csv_path, encoding="utf-8-sig", low_memory=False, usecols=lambda c: c in {
        "Email", "Workforce Id", "Workforce Name", "Location", "Date of Joining",
        "Designation", "Team", "Practice/ Function", "Reporting Manager Name", "user",
    })

    if "Email" not in df.columns and "user" in df.columns:
        df["Email"] = df["user"]

    df = df.dropna(subset=["Email"])
    df["Email"] = df["Email"].astype(str).str.strip().str.lower()
    df = df[df["Email"] != ""]
    df = df.drop_duplicates(subset=["Email"], keep="first")

    records = hr_dataframe_to_records(df)
    print(f"Prepared {len(records):,} unique HR records from CSV")

    client = get_supabase_client()
    upsert_hr_records(client, records)
    print("HR import from CSV complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
