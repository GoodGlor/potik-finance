"""Categories, bank-sentence patterns and the corpus-derived starter rules.

Everything here was read off twelve months of one real account (111 rows),
not invented. Nine categories cover the year; the largest by a factor of four
is `Відсотки за кредитом`, which the old vocabulary had no concept of.

There is deliberately no `Покупки`: Rozetka sells a kettle, a gift and
groceries, so a shopping bucket would swallow exactly the purchases that need
describing. Transfers are not categories either — they are a flow.
"""
import re

from app.core.text import normalize_key

INTEREST = "Відсотки за кредитом"

CATEGORIES: tuple[str, ...] = (
    "Продукти",
    "Кафе та ресторани",
    "Пальне",
    "Аптеки",
    "Підписки / Зв'язок",
    "Дім та ремонт",
    "Одяг",
    "Розваги",
    INTEREST,
)

# Bank sentences embed a changing month, so an exact key would never fire
# twice. Prefixes, lowercased. The over-limit fee is booked with the interest:
# same cause, same line on the report.
_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"^списання відсотків"), INTEREST),
    (re.compile(r"^за перевищення кредитного ліміту"), INTEREST),
)


def match_pattern(description: str) -> str | None:
    low = (description or "").strip().lower()
    for pattern, category in _PATTERNS:
        if pattern.match(low):
            return category
    return None


# Starter rules: every merchant in the corpus whose category is not in doubt.
# Keyed by raw description here and by normalize_key() at seed time, so this
# table stays readable. The owner can overwrite any of them by confirming.
SEED_RULES: dict[str, str] = {
    "Сільпо": "Продукти", "АТБ": "Продукти", "NOVUS": "Продукти",
    "МегаМаркет": "Продукти", "Мінімаркет box": "Продукти",
    "ROSHEN": "Продукти", "ORBITA": "Продукти",
    "McDonald’s": "Кафе та ресторани", "Kafe": "Кафе та ресторани",
    "LAVASH": "Кафе та ресторани", "GREEN BAR": "Кафе та ресторани",
    "Garden Wine": "Кафе та ресторани", "RIVER RESTAURANT": "Кафе та ресторани",
    "ORBITA SHOP": "Кафе та ресторани",
    "WOG": "Пальне", "Amic": "Пальне", "ОККО": "Пальне", "UPG": "Пальне", "UKRNAFTA": "Пальне",
    "APTEKA 24": "Аптеки", "Аптека Доброго Дня": "Аптеки", "Аптека «Будь Здоровий»": "Аптеки",
    "Netflix": "Підписки / Зв'язок", "lifecell": "Підписки / Зв'язок",
    "Епіцентр": "Дім та ремонт",
    "Militarka": "Одяг",
    "Кінопалац": "Розваги",
}

# Merchants that are never learned: the same shop sells different kinds of
# thing, and the API cannot say which. Asked every time; the owner's note
# does the work.
SEED_AMBIGUOUS: tuple[str, ...] = ("Rozetka",)


def seed(store) -> None:
    """Fill an empty RuleStore with the starter set. No-op once anything exists."""
    if not store.is_empty():
        return
    for description, category in SEED_RULES.items():
        store.put(normalize_key(description), category)
    for description in SEED_AMBIGUOUS:
        store.mark_ambiguous(normalize_key(description))
