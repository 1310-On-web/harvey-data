"""
One-time bulk import of harvey_usage_enriched.csv into Supabase.

Usage:
    py -3 scripts/bulk_import_csv.py
    py -3 scripts/bulk_import_csv.py --csv path/to/file.csv --batch-size 500
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from db_utils import (  # noqa: E402
    dataframe_to_usage_records,
    get_supabase_client,
    update_sync_metadata,
    upsert_usage_batch,
)


def parse_args():
    parser = argparse.ArgumentParser(description="Bulk import enriched CSV to Supabase")
    parser.add_argument(
        "--csv",
        default=str(ROOT / "harvey_usage_enriched.csv"),
        help="Path to harvey_usage_enriched.csv",
    )
    parser.add_argument("--batch-size", type=int, default=500)
    parser.add_argument("--chunk-rows", type=int, default=10000, help="CSV read chunk size")
    return parser.parse_args()


def main() -> int:
    load_dotenv(ROOT / ".env")
    args = parse_args()
    csv_path = Path(args.csv)
    if not csv_path.exists():
        print(f"CSV not found: {csv_path}", file=sys.stderr)
        return 1

    client = get_supabase_client()
    total_imported = 0

    print(f"Reading {csv_path} in chunks of {args.chunk_rows:,}...")
    for chunk_idx, chunk in enumerate(
        pd.read_csv(csv_path, encoding="utf-8-sig", low_memory=False, chunksize=args.chunk_rows)
    ):
        records = dataframe_to_usage_records(chunk)
        if not records:
            continue
        print(f"\nChunk {chunk_idx + 1}: {len(records):,} rows")
        upsert_usage_batch(client, records, batch_size=args.batch_size)
        total_imported += len(records)

    print(f"\nTotal imported: {total_imported:,}")
    update_sync_metadata(client, total_imported)
    print("Bulk import complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
