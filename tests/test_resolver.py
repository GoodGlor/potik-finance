"""The cascade: rule → note rule → pattern → transfer → ask."""
from datetime import UTC, datetime

from app.connectors.base import Flow, NormalizedTransaction, Source
from app.core import vocabulary
from app.core.resolver import Decider, resolve
from app.core.rules import RuleStore
from app.core.text import normalize_key
from app.core.transfers import TransferKind

OWNER = "Шевченко Тарас"


def row(description, amount=-100, mcc=5411, counter_name=None):
    return NormalizedTransaction(
        external_id="x", occurred_at=datetime(2026, 1, 1, tzinfo=UTC), amount=amount,
        currency_code=980, flow=Flow.INCOME if amount > 0 else Flow.EXPENSE,
        raw_category=description, raw_merchant=description, source=Source.MONOBANK,
        mcc=mcc, counter_name=counter_name,
    )


def seeded():
    s = RuleStore()
    vocabulary.seed(s)
    return s


def test_seeded_merchant_resolves_by_rule_whatever_the_script_or_case():
    s = seeded()
    for text in ("ОККО", "OKKO", "окко"):
        r = resolve(row(text, mcc=5541), s, OWNER)
        assert (r.category, r.decided_by, r.flow) == ("Пальне", Decider.RULE, Flow.EXPENSE)


def test_interest_resolves_by_pattern_without_a_rule():
    interest_row = row("Списання відсотків за липень", amount=-142000, mcc=6012)
    r = resolve(interest_row, RuleStore(), OWNER)
    assert (r.category, r.decided_by) == (vocabulary.INTEREST, Decider.PATTERN)


def test_transfer_has_no_category_and_transfer_flow():
    transfer_row = row(
        "Від: Shevchenko Taras", amount=350000, mcc=6012, counter_name="Shevchenko Taras"
    )
    r = resolve(transfer_row, RuleStore(), OWNER)
    assert r.category is None
    assert r.flow is Flow.TRANSFER
    assert (r.decided_by, r.transfer_kind) == (Decider.TRANSFER, TransferKind.OWN_CARD)


def test_learned_rule_beats_transfer_shape():
    """A transfer-shaped row still loses to a rule the owner explicitly taught."""
    s = RuleStore()
    transfer_row = row(
        "Від: Shevchenko Taras", amount=350000, mcc=6012, counter_name="Shevchenko Taras"
    )
    key = resolve(transfer_row, s, OWNER).key
    s.confirm(key, "Подарунки")
    r = resolve(transfer_row, s, OWNER)
    assert (r.category, r.decided_by, r.flow) == ("Подарунки", Decider.RULE, Flow.INCOME)
    assert r.transfer_kind is None


def test_unknown_merchant_is_asked_not_guessed():
    r = resolve(row("BIRYUZA SHOP", mcc=5944), seeded(), OWNER)
    assert (r.category, r.decided_by, r.ask_reason) == (None, Decider.ASK, "unknown")
    assert r.flow is Flow.EXPENSE


def test_ambiguous_merchant_is_asked_every_time():
    r = resolve(row("Rozetka", mcc=5262), seeded(), OWNER)
    assert (r.decided_by, r.ask_reason) == (Decider.ASK, "ambiguous")


def test_note_rule_resolves_an_ambiguous_merchant():
    s = seeded()
    s.confirm(resolve(row("Rozetka"), s, OWNER).key, "Техніка", note_key=normalize_key("чайник"))
    r = resolve(row("Rozetka"), s, OWNER, note="Чайник")
    assert (r.category, r.decided_by) == ("Техніка", Decider.NOTE_RULE)


def test_income_without_transfer_shape_stays_income_and_asks():
    r = resolve(row("Зарплата", amount=2183154, mcc=4829), RuleStore(), OWNER)
    assert (r.flow, r.decided_by) == (Flow.INCOME, Decider.ASK)


def test_confirmation_then_resolution_round_trip():
    s = RuleStore()
    first = resolve(row("BIRYUZA SHOP"), s, OWNER)
    s.confirm(first.key, "Одяг")
    assert resolve(row("biryuza shop"), s, OWNER).category == "Одяг"
