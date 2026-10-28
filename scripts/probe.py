"""What can this token actually see? A read-only probe against the real API.

Prints the account list (the /personal/client-info payload, humanized) and,
with --days, one statement window run through the categorizer. Nothing is
stored and nothing is written back to monobank — the personal API is read-only
by construction, so this is the whole ceiling of what the token permits.

    uv run python scripts/probe.py
    uv run python scripts/probe.py --days 7 --account <id>
"""
import argparse
import asyncio
import os
from collections import Counter
from datetime import UTC, datetime, timedelta

from app.connectors.monobank import InvalidToken, MonobankConnector, MonobankError
from app.core import vocabulary
from app.core.resolver import Decider, resolve
from app.core.rules import RuleStore

# ISO 4217 numeric codes monobank hands back, for the currencies an account
# here is plausibly denominated in. Anything else prints as the bare number.
CURRENCIES = {980: "UAH", 840: "USD", 978: "EUR", 985: "PLN", 826: "GBP"}


def money(minor: int, code: int) -> str:
    return f"{minor / 100:,.2f} {CURRENCIES.get(code, code)}"


def token() -> str:
    found = os.getenv("MF_MONOBANK_TOKEN") or os.getenv("MONO_KEY")
    if found:
        return found
    with open(".env", encoding="utf-8") as env:
        for line in env:
            key, _, value = line.strip().partition("=")
            if key in ("MF_MONOBANK_TOKEN", "MONO_KEY") and value:
                return value
    raise SystemExit("no token: set MF_MONOBANK_TOKEN in .env")


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=0,
                        help="also fetch this many days of statement")
    parser.add_argument("--account", help="account id (default: first UAH account)")
    args = parser.parse_args()

    connector = MonobankConnector(token())
    try:
        # One call serves both the account listing and, further down, the
        # owner name the resolver needs to type transfers — accounts() and
        # client_info() share a rate limiter, so a second call would just
        # sleep a minute for data already in hand.
        info = await connector.client_info()
    except InvalidToken:
        raise SystemExit("monobank rejected the token") from None
    except MonobankError as exc:
        raise SystemExit(f"monobank error: {exc}") from None

    print(f"\n{len(info.accounts)} account(s) visible to this token:\n")
    print(f"  {'id':<24} {'type':<14} {'card':<20} {'balance':>16} {'limit':>14} {'own funds':>16}")
    for account in info.accounts:
        # monobank folds the credit limit into `balance`, so the third column is
        # what is actually the owner's; the middle column is borrowable, not held.
        own = account.balance - account.credit_limit
        print(f"  {account.external_id:<24} {account.name:<14} {account.card_mask or '—':<20}"
              f" {money(account.balance, account.currency_code):>16}"
              f" {money(account.credit_limit, account.currency_code):>14}"
              f" {money(own, account.currency_code):>16}")

    if not args.days:
        print("\n(add --days N to pull a statement window; monobank paces those 1 request/60s)")
        return

    chosen = next(
        (a for a in info.accounts if a.external_id == args.account),
        next((a for a in info.accounts if a.currency_code == 980), info.accounts[0]),
    )
    to = datetime.now(UTC)
    print(f"\nfetching {args.days}d of {chosen.name} {chosen.card_mask}...")
    rows = await connector.transactions(chosen, to - timedelta(days=args.days), to)

    store = RuleStore()
    vocabulary.seed(store)
    results = [(row, resolve(row, store, info.owner_name)) for row in rows]
    print(f"\n{len(results)} transactions\n")
    for row, r in sorted(results, key=lambda pair: pair[0].occurred_at, reverse=True)[:15]:
        label = r.category or (
            f"transfer:{r.transfer_kind.value}" if r.transfer_kind else f"ask:{r.ask_reason}"
        )
        print(f"  {row.occurred_at:%Y-%m-%d %H:%M}  {money(row.amount, row.currency_code):>14}"
              f"  {r.decided_by.value:<9} {label:<28} {row.raw_merchant[:40]}")

    spend = Counter()
    for row, r in results:
        if r.category and r.flow.value == "expense":
            spend[r.category] += -row.amount
    print("\nspend by category (transfers excluded, as the reports do):")
    for category, total in spend.most_common():
        print(f"  {category:<32} {money(total, chosen.currency_code):>14}")
    asked = [row.raw_merchant for row, r in results if r.decided_by is Decider.ASK]
    if asked:
        print(f"\nwould ask about: {asked}")


if __name__ == "__main__":
    asyncio.run(main())
