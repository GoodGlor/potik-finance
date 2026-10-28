"""Layer 3 of the cascade: typing transfers.

Transfers are decided from fields and fixed bank phrasings, never from a
learned rule and never by an LLM. That is what keeps personal names off the
wire: every row that carries one is typed here and goes no further.

Seven shapes, read off the corpus. Order matters only where two could match —
the migration pair and the `Від:` prefix come first because they are the most
specific.
"""
import re
from enum import StrEnum

from app.connectors.base import NormalizedTransaction
from app.core.categories import FULL_NAME, NAME_INITIALS
from app.core.translit import same_person


class TransferKind(StrEnum):
    OWN_CARD = "own_card"
    """Between the owner's own cards. Not income, not spending."""
    PERSON = "person"
    """To or from a named person. Outflow, not consumption."""
    CARD = "card"
    """To a card with no name attached — a masked PAN, 'Переказ на картку'."""
    JAR = "jar"
    """Into one of the owner's savings jars. Own money set aside."""
    MIGRATION = "migration"
    """The bank moving a balance between its own systems. Both legs, net zero,
    excluded from everything — one month of a chart would otherwise show
    ±59 823 ₴ of phantom activity."""


_OWN_MONO_CARD = re.compile(r"^з .*картки$")
_MASKED_PAN = re.compile(r"\d{6}\*+\d{4}")

# monobank's code for "money transfer". The single MCC the cascade consults,
# and only for flow, only on outgoing rows: every outgoing 4829 in the corpus
# is a transfer, while an incoming 4829 can be salary.
_TRANSFER_MCC = 4829


def classify_transfer(row: NormalizedTransaction, owner_name: str) -> TransferKind | None:
    text = row.raw_merchant or ""
    low = text.strip().lower()

    if "в рамках міграції" in low:
        return TransferKind.MIGRATION
    if low.startswith("від:"):
        if same_person(owner_name, row.counter_name):
            return TransferKind.OWN_CARD
        return TransferKind.PERSON
    if _OWN_MONO_CARD.match(low):
        return TransferKind.OWN_CARD
    if low.startswith("поповнення «"):
        return TransferKind.JAR
    if _MASKED_PAN.search(text) or "переказ на картку" in low:
        return TransferKind.CARD
    if row.mcc == _TRANSFER_MCC and row.amount < 0:
        if NAME_INITIALS.search(text) or FULL_NAME.search(text):
            return TransferKind.PERSON
        return TransferKind.CARD
    return None
