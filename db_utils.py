"""Shared helpers for Supabase sync and import scripts."""

from __future__ import annotations

import math
import os
from datetime import datetime
from typing import Any

import pandas as pd

USAGE_COLUMNS = [
    "unique_usage_id",
    "utc_time",
    "usage_date",
    "usage_hour",
    "user_email",
    "access_point",
    "action",
    "product_surface_area",
    "workflow_name",
    "source",
    "subsurface",
    "cm_id",
    "parent_thread_id",
    "space_name",
    "playbook_name",
    "vault_project_name",
    "review_table_name",
    "file_count",
    "workforce_id",
    "workforce_name",
    "location",
    "date_of_joining",
    "designation",
    "team",
    "practice_function",
    "email",
    "reporting_manager_name",
]

HR_COLUMNS = [
    "email",
    "workforce_id",
    "workforce_name",
    "location",
    "date_of_joining",
    "designation",
    "team",
    "practice_function",
    "reporting_manager_name",
    "harvey_status",
    "access_state",
    "phase",
    "low_usage_warning",
    "date_added",
    "training_attendance",
    "cohort_training_attendance",
    "notes",
]


def derive_access_state(status: str | None, *, has_status_column: bool = True) -> str:
    """Map Master-data Status column to normalized access_state."""
    if not has_status_column:
        return "granted"
    if not status:
        return "pending"
    s = status.strip()
    if s == "Added":
        return "granted"
    if s.lower().startswith("revoked"):
        return "revoked"
    if "resigned" in s.lower():
        return "resigned"
    return "pending"


_ACCESS_STATE_RANK = {"granted": 4, "revoked": 3, "resigned": 2, "pending": 1}


def dedupe_hr_records(records: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[str]]:
    """Merge duplicate emails; prefer granted access and fill missing fields."""
    by_email: dict[str, dict[str, Any]] = {}
    duplicate_emails: list[str] = []

    for rec in records:
        email = rec["email"]
        if email not in by_email:
            by_email[email] = rec.copy()
            continue

        duplicate_emails.append(email)
        existing = by_email[email]
        rec_rank = _ACCESS_STATE_RANK.get(rec.get("access_state"), 0)
        existing_rank = _ACCESS_STATE_RANK.get(existing.get("access_state"), 0)

        if rec_rank > existing_rank:
            winner, loser = rec.copy(), existing
        else:
            winner, loser = existing.copy(), rec

        for key, value in loser.items():
            if key == "email" or not value:
                continue
            if not winner.get(key):
                winner[key] = value

        by_email[email] = winner

    return list(by_email.values()), sorted(set(duplicate_emails))


def get_supabase_client():
    import httpx
    from supabase import ClientOptions, create_client

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key or "YOUR_PROJECT" in url or "your_secret" in key:
        raise SystemExit(
            "Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in .env "
            "(Project URL + Secret/service_role key from Supabase → Settings → API Keys)."
        )

    verify_ssl = os.environ.get("SUPABASE_SSL_VERIFY", "false").lower() == "true"
    options = ClientOptions(httpx_client=httpx.Client(verify=verify_ssl))
    return create_client(url, key, options=options)


def csv_row_to_db(row: dict[str, Any]) -> dict[str, Any]:
    """Map enriched CSV column names to usage_events table columns."""
    usage_date = row.get("usage_date")
    if usage_date is not None and not (isinstance(usage_date, float) and math.isnan(usage_date)):
        usage_date = pd.to_datetime(usage_date, errors="coerce")
        usage_date = usage_date.date().isoformat() if pd.notna(usage_date) else None
    else:
        usage_date = None

    doj = row.get("Date of Joining")
    if doj is not None and not (isinstance(doj, float) and math.isnan(doj)):
        doj = pd.to_datetime(doj, errors="coerce")
        doj = doj.date().isoformat() if pd.notna(doj) else None
    else:
        doj = None

    usage_hour = row.get("usage_hour")
    if usage_hour is not None and not (isinstance(usage_hour, float) and math.isnan(usage_hour)):
        try:
            usage_hour = int(usage_hour)
        except (TypeError, ValueError):
            usage_hour = None
    else:
        usage_hour = None

    file_count = row.get("file_count")
    if file_count is not None and not (isinstance(file_count, float) and math.isnan(file_count)):
        try:
            file_count = int(file_count)
        except (TypeError, ValueError):
            file_count = 0
    else:
        file_count = 0

    uid = row.get("unique_usage_id")
    if uid is None or (isinstance(uid, float) and math.isnan(uid)):
        return {}
    uid = str(uid).strip()
    if not uid:
        return {}

    user_email = row.get("user") or row.get("user_email") or row.get("Email")
    if user_email is not None and not (isinstance(user_email, float) and math.isnan(user_email)):
        user_email = str(user_email).strip().lower()
    else:
        user_email = None

    utc_time = row.get("utc_time")
    if utc_time is not None and not (isinstance(utc_time, float) and math.isnan(utc_time)):
        utc_time = str(utc_time)
    else:
        utc_time = None

    def _str(val: Any) -> str | None:
        if val is None or (isinstance(val, float) and math.isnan(val)):
            return None
        s = str(val).strip()
        return s if s else None

    return {
        "unique_usage_id": uid,
        "utc_time": utc_time,
        "usage_date": usage_date,
        "usage_hour": usage_hour,
        "user_email": user_email,
        "access_point": _str(row.get("access_point")),
        "action": _str(row.get("action")),
        "product_surface_area": _str(row.get("product_surface_area")),
        "workflow_name": _str(row.get("workflow_name")),
        "source": _str(row.get("source")),
        "subsurface": _str(row.get("subsurface")),
        "cm_id": _str(row.get("cm_id")),
        "parent_thread_id": _str(row.get("parent_thread_id")),
        "space_name": _str(row.get("space_name")),
        "playbook_name": _str(row.get("playbook_name")),
        "vault_project_name": _str(row.get("vault_project_name")),
        "review_table_name": _str(row.get("review_table_name")),
        "file_count": file_count,
        "workforce_id": _str(row.get("Workforce Id") or row.get("workforce_id")),
        "workforce_name": _str(row.get("Workforce Name") or row.get("workforce_name")),
        "location": _str(row.get("Location") or row.get("location")),
        "date_of_joining": doj,
        "designation": _str(row.get("Designation") or row.get("designation")),
        "team": _str(row.get("Team") or row.get("team")),
        "practice_function": _str(row.get("Practice/ Function") or row.get("practice_function")),
        "email": _str(row.get("Email") or row.get("email") or user_email),
        "reporting_manager_name": _str(
            row.get("Reporting Manager Name") or row.get("reporting_manager_name")
        ),
    }


def dataframe_to_usage_records(df: pd.DataFrame) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for row in df.to_dict(orient="records"):
        mapped = csv_row_to_db(row)
        if mapped.get("unique_usage_id") and mapped.get("user_email"):
            records.append(mapped)
    return records


def hr_dataframe_to_records(hr_df: pd.DataFrame) -> list[dict[str, Any]]:
    hr_df = hr_df.copy()
    hr_df.columns = hr_df.columns.astype(str).str.strip()
    has_status_column = "Status" in hr_df.columns
    records: list[dict[str, Any]] = []

    for row in hr_df.to_dict(orient="records"):
        email = row.get("Email")
        if email is None or (isinstance(email, float) and math.isnan(email)):
            continue
        email = str(email).strip().lower()
        if not email:
            continue

        doj = row.get("Date of Joining")
        if doj is not None and not (isinstance(doj, float) and math.isnan(doj)):
            doj = pd.to_datetime(doj, errors="coerce")
            doj = doj.date().isoformat() if pd.notna(doj) else None
        else:
            doj = None

        def _str(val: Any) -> str | None:
            if val is None or (isinstance(val, float) and math.isnan(val)):
                return None
            s = str(val).strip()
            return s if s else None

        harvey_status = _str(row.get("Status")) if has_status_column else None
        access_state = derive_access_state(harvey_status, has_status_column=has_status_column)

        date_added = row.get("Date Added")
        if date_added is not None and not (isinstance(date_added, float) and math.isnan(date_added)):
            date_added = pd.to_datetime(date_added, errors="coerce", dayfirst=True)
            date_added = date_added.date().isoformat() if pd.notna(date_added) else None
        else:
            date_added = None

        records.append(
            {
                "email": email,
                "workforce_id": _str(row.get("Workforce Id")),
                "workforce_name": _str(row.get("Workforce Name")),
                "location": _str(row.get("Location")),
                "date_of_joining": doj,
                "designation": _str(row.get("Designation")),
                "team": _str(row.get("Team")),
                "practice_function": _str(row.get("Practice/ Function")),
                "reporting_manager_name": _str(row.get("Reporting Manager Name")),
                "harvey_status": harvey_status,
                "access_state": access_state,
                "phase": _str(row.get("Phase")),
                "low_usage_warning": _str(row.get("Low usage warning")),
                "date_added": date_added,
                "training_attendance": _str(row.get("Training Attendance")),
                "cohort_training_attendance": _str(row.get("Cohort Training Attendance")),
                "notes": _str(row.get("Notes")),
                "updated_at": datetime.utcnow().isoformat(),
            }
        )
    records, _ = dedupe_hr_records(records)
    return records


def upsert_usage_batch(client, records: list[dict[str, Any]], batch_size: int = 500) -> int:
    total = 0
    for i in range(0, len(records), batch_size):
        batch = records[i : i + batch_size]
        client.table("usage_events").upsert(batch, on_conflict="unique_usage_id").execute()
        total += len(batch)
        print(f"  Upserted {total:,}/{len(records):,} usage rows")
    return total


def upsert_hr_records(client, records: list[dict[str, Any]], batch_size: int = 500) -> int:
    records, duplicate_emails = dedupe_hr_records(records)
    if duplicate_emails:
        print(f"  Merged {len(duplicate_emails):,} duplicate email(s): {', '.join(duplicate_emails)}")
    total = 0
    for i in range(0, len(records), batch_size):
        batch = records[i : i + batch_size]
        client.table("hr_employees").upsert(batch, on_conflict="email").execute()
        total += len(batch)
        print(f"  Upserted {total:,}/{len(records):,} HR rows")
    return total


def load_hr_from_supabase(client) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    offset = 0
    page_size = 1000
    while True:
        response = (
            client.table("hr_employees")
            .select("*")
            .range(offset, offset + page_size - 1)
            .execute()
        )
        batch = response.data or []
        if not batch:
            break
        rows.extend(batch)
        if len(batch) < page_size:
            break
        offset += page_size

    if not rows:
        raise SystemExit("hr_employees table is empty. Run scripts/import_hr_excel.py first.")

    hr_df = pd.DataFrame(rows)
    hr_df = hr_df.rename(
        columns={
            "email": "Email",
            "workforce_id": "Workforce Id",
            "workforce_name": "Workforce Name",
            "location": "Location",
            "date_of_joining": "Date of Joining",
            "designation": "Designation",
            "team": "Team",
            "practice_function": "Practice/ Function",
            "reporting_manager_name": "Reporting Manager Name",
        }
    )
    hr_df["Email"] = hr_df["Email"].astype(str).str.strip().str.lower()
    return hr_df


def update_sync_metadata(client, last_sync_rows: int) -> None:
    stats = client.table("usage_events").select("unique_usage_id", count="exact").limit(1).execute()
    row_count = stats.count or 0

    dates = (
        client.table("usage_events")
        .select("usage_date")
        .order("usage_date", desc=False)
        .limit(1)
        .execute()
    )
    min_row = dates.data[0]["usage_date"] if dates.data else None

    dates_max = (
        client.table("usage_events")
        .select("usage_date")
        .order("usage_date", desc=True)
        .limit(1)
        .execute()
    )
    max_row = dates_max.data[0]["usage_date"] if dates_max.data else None

    client.table("sync_metadata").upsert(
        {
            "id": 1,
            "last_sync": datetime.utcnow().isoformat(),
            "min_date": min_row,
            "max_date": max_row,
            "row_count": row_count,
            "last_sync_rows": last_sync_rows,
        }
    ).execute()

    print(f"Sync metadata updated: {row_count:,} rows, dates {min_row} to {max_row}")
    refresh_dashboard_cache(client)


def refresh_dashboard_cache(client) -> None:
    """Refresh pre-computed dashboard stats in Supabase (avoids query timeouts)."""
    try:
        client.rpc("refresh_dashboard_cache").execute()
        print("Dashboard cache refreshed.")
    except Exception as exc:
        print(f"Warning: dashboard cache refresh failed: {exc}")
