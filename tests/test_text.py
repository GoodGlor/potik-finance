"""The rule key. Opaque and deterministic; the raw description is what gets shown."""
from app.core.text import normalize_key


def test_case_and_typographic_apostrophe_fold():
    assert normalize_key("McDonald’s") == normalize_key("MCDONALD'S") == normalize_key("mcdonald's")


def test_cyrillic_lookalikes_fold_to_latin():
    """ОККО typed in Cyrillic and OKKO typed in Latin are the same chain."""
    assert normalize_key("ОККО") == normalize_key("OKKO") == "okko"


def test_transliteration_pairs_do_not_fold():
    """Kafe vs кафе is a different-letters pair, not a lookalike pair: two keys."""
    assert normalize_key("Kafe") != normalize_key("кафе")


def test_card_tails_and_long_numbers_are_stripped():
    assert normalize_key("McDonalds *4321") == normalize_key("McDonalds")
    assert normalize_key("Кредит готівкою 11111111111111") == normalize_key("Кредит готівкою")


def test_short_numbers_survive():
    """WOG 24 is a brand, not a contract number."""
    assert normalize_key("WOG 24") == "wog 24"


def test_whitespace_collapses():
    assert normalize_key("  Сільпо   ") == normalize_key("Сільпо")


def test_distinct_merchants_stay_distinct():
    assert normalize_key("ORBITA") != normalize_key("ORBITA SHOP")
