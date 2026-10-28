"""The connector boundary.

Every bank source — monobank now, PrivatBank statement import later, an open
banking aggregator after that — produces `NormalizedTransaction`. Nothing
downstream of this module knows which bank a row came from.
"""
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from typing import Protocol


class Flow(StrEnum):
    """The three-way split carried over from the Python pipeline.

    `transfer` rows are excluded from every spending report. Cash withdrawals
    and P2P transfers count as outflow but not as consumption, which is why
    total outflow and spend-by-category are two different numbers and must
    never be conflated.
    """

    INCOME = "income"
    EXPENSE = "expense"
    TRANSFER = "transfer"


class Source(StrEnum):
    MONOBANK = "monobank"
    PRIVAT_IMPORT = "privat_import"


@dataclass(frozen=True, slots=True)
class AccountInfo:
    """A bank account as the connector sees it, before we persist anything."""

    external_id: str
    name: str
    card_mask: str
    currency_code: int
    balance: int
    """Minor units (kopiykas). Never used in arithmetic that reports spending —
    with several cards a single balance column jumps between them."""

    credit_limit: int = 0
    """Minor units, and part of `balance` rather than additional to it: monobank
    reports a card with none of its own money and a 60 000 limit as balance
    60 000. Own funds are `balance - credit_limit` and go negative once the limit
    is being used — that difference, not `balance`, is what a "will my money last
    until payday?" answer must run on, because spending the limit is borrowing.

    A negative `balance` is not a contradiction of this: it means over-limit.
    Interest is charged against the debt and can push the drawn amount past the
    limit itself, which this account did in July (balance -921.34, i.e. 60 921.34
    drawn against 60 000) before a deposit brought it back under."""


@dataclass(frozen=True, slots=True)
class ClientInfo:
    """What /personal/client-info says about the token's owner.

    `owner_name` is how the bank writes the owner — in Cyrillic, while
    statement counterparties come back transliterated. `jars` are the titles
    of the owner's savings jars; a `Поповнення «…»` row is money moved into one.
    Currently informational only — `classify_transfer()` types a jar transfer
    from that `Поповнення «` prefix alone, not by matching against this list —
    kept because it is real information the API already gives us, not because
    anything reads it yet.
    """

    owner_name: str
    accounts: tuple[AccountInfo, ...]
    jars: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class NormalizedTransaction:
    """One bank transaction in the common shape, before categorization.

    `amount` is signed minor units: negative leaves the account. `flow` here
    is sign alone — INCOME or EXPENSE, never TRANSFER; the connector has no
    transfer detection. Structural typing happens downstream, in
    `classify_transfer()` (`app/core/transfers.py`), which reads fields and
    fixed bank phrasings to reclassify a row's flow as TRANSFER.
    """

    external_id: str
    occurred_at: datetime
    amount: int
    currency_code: int
    flow: Flow
    raw_category: str
    raw_merchant: str
    source: Source
    mcc: int | None = None
    balance_after: int | None = None

    # monobank-specific, all optional because the API omits keys rather than
    # nulling them. `amount` is always in the account's currency; when the
    # merchant charged in another currency the operation pair says which and
    # how much — Netflix: amount -43120 (UAH), operation_amount -999 (EUR).
    operation_amount: int | None = None
    operation_currency: int | None = None
    original_mcc: int | None = None
    """The card network's code before monobank rewrote it, when the two
    disagree. The corpus carries `mcc` 7829 against `original_mcc` 4899 on one
    subscription, and 4899 is the code describing the real shop; 15 of its 111
    rows are recoded, and three of those are UAH, so this is not only the
    cross-border case `operation_currency` marks. Reported, never read as a
    spending category."""
    commission: int = 0
    """Minor units the bank took for the operation — already included in
    `amount` (a −6240 transfer is 6000 plus a 240 fee; −52000 is 50000 plus
    2000). Must be reported but never added to `amount` or a spending total —
    doing so would double-count it. Every commissioned row in this corpus is a
    transfer, so these fees are real money that no spending report currently
    surfaces."""
    cashback: int = 0
    hold: bool = False
    """Pending. The amount can still change on settlement, so a re-ingest must
    replace a held row rather than dedup it away."""
    receipt_id: str | None = None
    counter_name: str | None = None
    """Transfer counterparty as the bank names it. Personal data — it is used to
    type own-card transfers and never becomes a rule key or leaves the machine."""


class BankConnector(Protocol):
    """The seam the whole roadmap rests on."""

    async def accounts(self) -> list[AccountInfo]: ...

    async def transactions(
        self, account: AccountInfo, frm: datetime, to: datetime
    ) -> list[NormalizedTransaction]: ...
