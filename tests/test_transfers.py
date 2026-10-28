"""Layer 3. Transfers are typed from fields and fixed bank phrasings, never learned."""
from datetime import UTC, datetime

from app.connectors.base import Flow, NormalizedTransaction, Source
from app.core.transfers import TransferKind, classify_transfer

OWNER = "Шевченко Тарас"


def row(description, amount=-100, mcc=4829, counter_name=None):
    return NormalizedTransaction(
        external_id="x", occurred_at=datetime(2026, 1, 1, tzinfo=UTC), amount=amount,
        currency_code=980, flow=Flow.INCOME if amount > 0 else Flow.EXPENSE,
        raw_category=description, raw_merchant=description, source=Source.MONOBANK,
        mcc=mcc, counter_name=counter_name,
    )


def test_incoming_from_the_owner_is_own_card():
    r = row("Від: Shevchenko Taras", amount=350000, mcc=6012, counter_name="Shevchenko Taras")
    assert classify_transfer(r, OWNER) is TransferKind.OWN_CARD


def test_incoming_from_a_relative_is_a_person():
    r = row("Від: Оксана Шевченко", amount=200000, counter_name="Оксана Шевченко")
    assert classify_transfer(r, OWNER) is TransferKind.PERSON


def test_incoming_from_another_own_monobank_card():
    assert classify_transfer(row("З Білої картки", amount=3910), OWNER) is TransferKind.OWN_CARD
    assert classify_transfer(row("З доларової картки", amount=2983), OWNER) is TransferKind.OWN_CARD


def test_jar_top_up():
    assert classify_transfer(row("Поповнення «На Чай»"), OWNER) is TransferKind.JAR
    assert classify_transfer(row("Поповнення «Відпустка🌴»"), OWNER) is TransferKind.JAR


def test_migration_pair_both_legs():
    incoming = row("Зарахування коштів в рамках міграції", amount=5982337)
    outgoing = row("Списання коштів в рамках міграції", amount=-5982337)
    assert classify_transfer(incoming, OWNER) is TransferKind.MIGRATION
    assert classify_transfer(outgoing, OWNER) is TransferKind.MIGRATION


def test_outgoing_p2p_by_name_initials():
    assert classify_transfer(row("Ігор Н.", amount=-5000), OWNER) is TransferKind.PERSON


def test_outgoing_to_a_card_by_pan_phrase_or_mcc():
    assert classify_transfer(row("414962****3333", amount=-7280), OWNER) is TransferKind.CARD
    assert classify_transfer(row("Переказ на картку", amount=-62400), OWNER) is TransferKind.CARD
    assert classify_transfer(row("my privat", amount=-52000), OWNER) is TransferKind.CARD


def test_incoming_4829_is_not_a_transfer_by_mcc_alone():
    """The one MCC use is restricted to outgoing rows: salary stays income."""
    assert classify_transfer(row("Зарплата", amount=2183154, mcc=4829), OWNER) is None


def test_a_three_word_pharmacy_is_not_a_person():
    """FULL_NAME matches 'Аптека Доброго Дня'. Name detection is gated on 4829."""
    assert classify_transfer(row("Аптека Доброго Дня", amount=-5500, mcc=5912), OWNER) is None


def test_ordinary_purchase_is_not_a_transfer():
    assert classify_transfer(row("Сільпо", amount=-41230, mcc=5411), OWNER) is None
