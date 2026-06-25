"""
Compare Harvey API enriched CSV vs Harvey UI Export Analysis xlsx.

Join key: unique_usage_id. Compares Harvey core fields; ignores HR-only columns
in the enriched CSV. Exit code 0 = exact match, 1 = discrepancies remain.

Usage:
    py -3 compare_usage.py --api harvey_usage_enriched_2026-04-01_to_2026-04-30.csv `
        --ui harvey-usage-start_2026-04-01_end_2026-04-30.xlsx
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

HARVEY_FIELDS = [
    "user",
    "action",
    "product_surface_area",
    "access_point",
    "source",
    "workflow_name",
    "utc_time",
]

ID_COL = "unique_usage_id"


def parse_args():
    parser = argparse.ArgumentParser(description="Compare API CSV vs Harvey UI xlsx")
    parser.add_argument("--api", required=True, help="Path to enriched API CSV")
    parser.add_argument("--ui", required=True, help="Path to Harvey UI xlsx export")
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Directory for discrepancy CSV outputs (default: current directory)",
    )
    return parser.parse_args()


def normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df.columns = df.columns.astype(str).str.strip()
    return df


def normalize_id_series(series: pd.Series) -> pd.Series:
    return series.astype(str).str.strip()


def normalize_value(val) -> str:
    if pd.isna(val):
        return ""
    if isinstance(val, pd.Timestamp):
        return val.strftime("%Y-%m-%d %H:%M:%S")
    s = str(val).strip()
    if s.endswith("+00:00"):
        s = s.replace("+00:00", "")
    return s


def load_api(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, encoding="utf-8-sig", low_memory=False)
    df = normalize_columns(df)
    if ID_COL not in df.columns:
        raise SystemExit(f"API CSV missing column: {ID_COL}")
    df[ID_COL] = normalize_id_series(df[ID_COL])
    df = df[df[ID_COL] != ""]
    return df


def load_ui(path: Path) -> pd.DataFrame:
    df = pd.read_excel(path)
    df = normalize_columns(df)
    if ID_COL not in df.columns:
        raise SystemExit(f"UI xlsx missing column: {ID_COL}")
    df[ID_COL] = normalize_id_series(df[ID_COL])
    df = df[df[ID_COL] != ""]
    return df


def compare_frames(api_df: pd.DataFrame, ui_df: pd.DataFrame, output_dir: Path) -> int:
    api_ids = set(api_df[ID_COL])
    ui_ids = set(ui_df[ID_COL])

    only_api = api_ids - ui_ids
    only_ui = ui_ids - api_ids
    shared = api_ids & ui_ids

    print(f"API rows: {len(api_df):,} (unique {ID_COL}: {len(api_ids):,})")
    print(f"UI rows:  {len(ui_df):,} (unique {ID_COL}: {len(ui_ids):,})")
    print(f"Only in API: {len(only_api):,}")
    print(f"Only in UI:  {len(only_ui):,}")
    print(f"Shared:      {len(shared):,}")

    exit_code = 0
    output_dir.mkdir(parents=True, exist_ok=True)

    if only_api:
        exit_code = 1
        path = output_dir / "discrepancy_only_in_api.csv"
        api_df[api_df[ID_COL].isin(only_api)].to_csv(path, index=False, encoding="utf-8-sig")
        print(f"Wrote {path}")

    if only_ui:
        exit_code = 1
        path = output_dir / "discrepancy_only_in_ui.csv"
        ui_df[ui_df[ID_COL].isin(only_ui)].to_csv(path, index=False, encoding="utf-8-sig")
        print(f"Wrote {path}")

    api_shared = api_df.set_index(ID_COL)
    ui_shared = ui_df.set_index(ID_COL)

    mismatches = []
    for uid in shared:
        api_row = api_shared.loc[uid]
        ui_row = ui_shared.loc[uid]
        if isinstance(api_row, pd.DataFrame):
            api_row = api_row.iloc[0]
        if isinstance(ui_row, pd.DataFrame):
            ui_row = ui_row.iloc[0]

        for field in HARVEY_FIELDS:
            api_col = field
            ui_col = field
            if api_col not in api_shared.columns or ui_col not in ui_shared.columns:
                continue
            api_val = normalize_value(api_row.get(api_col))
            ui_val = normalize_value(ui_row.get(ui_col))
            if api_val != ui_val:
                mismatches.append(
                    {
                        ID_COL: uid,
                        "field": field,
                        "api_value": api_val,
                        "ui_value": ui_val,
                    }
                )

    if mismatches:
        exit_code = 1
        mismatch_df = pd.DataFrame(mismatches)
        path = output_dir / "discrepancy_field_mismatches.csv"
        mismatch_df.to_csv(path, index=False, encoding="utf-8-sig")
        print(f"Field mismatches: {len(mismatches):,} (wrote {path})")
    else:
        print("Field mismatches: 0")

    if exit_code == 0:
        print("\nPASS: Exact match — same records and counts in both sources.")
    else:
        print("\nFAIL: Discrepancies remain — see discrepancy_*.csv files.")

    return exit_code


def main() -> int:
    args = parse_args()
    api_path = Path(args.api)
    ui_path = Path(args.ui)
    output_dir = Path(args.output_dir)

    if not api_path.exists():
        print(f"API file not found: {api_path}", file=sys.stderr)
        return 1
    if not ui_path.exists():
        print(f"UI file not found: {ui_path}", file=sys.stderr)
        return 1

    print(f"API: {api_path}")
    print(f"UI:  {ui_path}\n")

    api_df = load_api(api_path)
    ui_df = load_ui(ui_path)
    return compare_frames(api_df, ui_df, output_dir)


if __name__ == "__main__":
    sys.exit(main())
