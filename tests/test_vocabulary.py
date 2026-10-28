from app.core import vocabulary
from app.core.vocabulary import INTEREST, match_pattern


def test_interest_matches_every_month_including_the_latin_i():
    """monobank writes 'сiчень' with a Latin i. The prefix rule does not care."""
    for month in ("липень", "сiчень", "серпень"):
        assert match_pattern(f"Списання відсотків за {month}") == INTEREST


def test_over_limit_fee_is_interest_too():
    assert match_pattern("За перевищення кредитного ліміту") == INTEREST


def test_patterns_are_prefixes_not_substrings():
    assert match_pattern("Кафе Списання відсотків") is None


def test_seed_rules_use_only_known_categories():
    assert set(vocabulary.SEED_RULES.values()) <= set(vocabulary.CATEGORIES)


def test_no_shopping_bucket():
    """Where something was bought does not say what it was. See spec."""
    assert "Покупки" not in vocabulary.CATEGORIES
