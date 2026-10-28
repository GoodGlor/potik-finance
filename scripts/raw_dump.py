"""Raw statement rows, unnormalized — for seeing what monobank actually sends.

`normalize()` keeps eight of monobank's fields and drops the rest; this prints
the untouched payload so the dropped ones are visible, plus the union of keys
seen across the sample (the API omits fields rather than nulling them, so the
shape varies row to row).

    uv run python scripts/raw_dump.py <account-id> [months-back ...]
"""
import asyncio
import json
import sys
from datetime import UTC, datetime, timedelta

from app.connectors.monobank import MonobankConnector
from scripts.probe import token


async def main() -> None:
    account_id = sys.argv[1]
    offsets = [int(a) for a in sys.argv[2:]] or [0]
    connector = MonobankConnector(token())
    now = datetime.now(UTC)
    keys: set[str] = set()

    for months in offsets:
        end = now - timedelta(days=30 * months)
        start = end - timedelta(days=31)
        rows = await connector._statement(account_id, start, end)
        print(f"\n===== {start:%Y-%m-%d} … {end:%Y-%m-%d} — {len(rows)} rows =====", flush=True)
        for row in rows:
            keys.update(row)
            print(json.dumps(row, ensure_ascii=False), flush=True)

    print(f"\nkeys seen across the sample: {sorted(keys)}")


asyncio.run(main())
