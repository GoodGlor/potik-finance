"""How far back does this token's statement history actually go?

monobank documents the per-request cap (31 days) but not a total horizon, so
the horizon is measured rather than assumed: sample one 31-day window at each
offset and see whether rows come back. Each sample costs a full minute of the
statement rate limit, hence a handful of probes rather than a walk.

    uv run python scripts/history_probe.py <account-id>
"""
import asyncio
import json
import sys
from datetime import UTC, datetime, timedelta

from app.connectors.monobank import MonobankConnector
from scripts.probe import token

# Months back to sample. Deliberately sparse — a dense walk would take an hour.
OFFSETS = [1, 6, 12, 24]


async def main() -> None:
    account_id = sys.argv[1]
    connector = MonobankConnector(token())
    now = datetime.now(UTC)
    first_raw = None

    for months in OFFSETS:
        end = now - timedelta(days=30 * months)
        start = end - timedelta(days=31)
        raw = await connector._statement(account_id, start, end)
        print(f"  {months:>2}mo back  {start:%Y-%m-%d} … {end:%Y-%m-%d}  {len(raw):>3} rows",
              flush=True)
        if raw and first_raw is None:
            first_raw = raw[0]

    if first_raw:
        print("\nfields monobank returns per transaction:")
        print(json.dumps(first_raw, ensure_ascii=False, indent=2)[:900])


asyncio.run(main())
