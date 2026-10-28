"""Rules and confirmations. Ambiguity is derived from history, not declared."""
from app.core.rules import RuleStore


def test_empty_then_put_then_rule():
    s = RuleStore()
    assert s.is_empty()
    s.put("okko", "Пальне")
    assert not s.is_empty()
    assert s.rule("okko") == "Пальне"
    assert s.rule("nope") is None


def test_confirm_without_note_writes_a_merchant_rule():
    s = RuleStore()
    s.confirm("wog", "Пальне")
    assert s.rule("wog") == "Пальне"


def test_confirm_with_note_writes_a_note_rule_not_a_merchant_rule():
    """A note says 'this one was a kettle' — about the purchase, not the shop."""
    s = RuleStore()
    s.confirm("rozetka", "Техніка", note_key="чайник")
    assert s.rule("rozetka") is None
    assert s.note_rule("rozetka", "чайник") == "Техніка"


def test_two_different_categories_make_a_merchant_ambiguous():
    s = RuleStore()
    s.confirm("rozetka", "Техніка")
    assert s.rule("rozetka") == "Техніка"
    s.confirm("rozetka", "Подарунки")
    assert s.is_ambiguous("rozetka")
    assert s.rule("rozetka") is None            # the rule is withdrawn


def test_note_confirmations_count_toward_ambiguity_too():
    s = RuleStore()
    s.confirm("rozetka", "Техніка", note_key="чайник")
    s.confirm("rozetka", "Подарунки", note_key="подарунок")
    assert s.is_ambiguous("rozetka")
    assert s.note_rule("rozetka", "подарунок") == "Подарунки"   # notes survive


def test_same_category_twice_is_not_ambiguous():
    s = RuleStore()
    s.confirm("silpo", "Продукти")
    s.confirm("silpo", "Продукти")
    assert not s.is_ambiguous("silpo")


def test_mark_ambiguous_withdraws_any_rule():
    s = RuleStore()
    s.put("rozetka", "Техніка")
    s.mark_ambiguous("rozetka")
    assert s.is_ambiguous("rozetka") and s.rule("rozetka") is None


def test_confirming_an_ambiguous_merchant_without_note_does_not_resurrect_the_rule():
    s = RuleStore()
    s.mark_ambiguous("rozetka")
    s.confirm("rozetka", "Техніка")
    assert s.rule("rozetka") is None
