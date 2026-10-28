"""The cascade. Each layer sees only what the layer above could not answer.

    learned rule → note rule → seeded pattern → structural transfer → ask

`resolve()` is a pure function of (row, store, owner, note). It never writes;
confirmations go through `RuleStore.confirm()` and the next call sees them.
The result says which layer decided, so a wrong category can be traced to a
rule rather than guessed at.

`Не визначено` is gone: an unresolved row is `category=None, decided_by=ASK`
with a reason — `ambiguous` (asked on purpose, every time) or `unknown`.
"""
from dataclasses import dataclass
from enum import StrEnum

from app.connectors.base import Flow, NormalizedTransaction
from app.core import vocabulary
from app.core.rules import RuleStore
from app.core.text import normalize_key
from app.core.transfers import TransferKind, classify_transfer


class Decider(StrEnum):
    RULE = "rule"
    NOTE_RULE = "note_rule"
    PATTERN = "pattern"
    TRANSFER = "transfer"
    ASK = "ask"


@dataclass(frozen=True, slots=True)
class Resolution:
    key: str
    category: str | None
    flow: Flow
    decided_by: Decider
    transfer_kind: TransferKind | None = None
    ask_reason: str | None = None


def _spend_flow(row: NormalizedTransaction) -> Flow:
    return Flow.INCOME if row.amount > 0 else Flow.EXPENSE


def resolve(
    row: NormalizedTransaction,
    store: RuleStore,
    owner_name: str,
    note: str | None = None,
) -> Resolution:
    key = normalize_key(row.raw_merchant)

    if category := store.rule(key):
        return Resolution(key, category, _spend_flow(row), Decider.RULE)

    if note and (category := store.note_rule(key, normalize_key(note))):
        return Resolution(key, category, _spend_flow(row), Decider.NOTE_RULE)

    if category := vocabulary.match_pattern(row.raw_merchant):
        return Resolution(key, category, _spend_flow(row), Decider.PATTERN)

    if kind := classify_transfer(row, owner_name):
        return Resolution(key, None, Flow.TRANSFER, Decider.TRANSFER, transfer_kind=kind)

    reason = "ambiguous" if store.is_ambiguous(key) else "unknown"
    return Resolution(key, None, _spend_flow(row), Decider.ASK, ask_reason=reason)
