"""The rule key: what makes two descriptions "the same merchant".

monobank's description is the acquirer's terminal name, so the same shop
arrives in different casing, with a typographic apostrophe one month and a
straight one the next, and — for chains like ОККО — typed in whichever script
the terminal happened to use. The key folds exactly those differences and no
others. It is opaque: a Cyrillic word with its lookalike letters swapped for
Latin is not readable, and is not meant to be.

What is deliberately NOT folded: transliteration pairs (`Kafe` / `кафе` are
different letters, not lookalikes) and wordings (`ORBITA` / `ORBITA SHOP`).
Each of those is a separate rule and costs a separate confirmation.
"""
from app.core.categories import CARD_TAIL, LONG_NUMBER

# Typographic and modifier apostrophes the terminals use for "McDonald’s".
_APOSTROPHES = str.maketrans({"’": "'", "ʼ": "'", "`": "'", "´": "'", "‘": "'"})

# Lowercase Cyrillic letters whose UPPERCASE shares a glyph with a Latin
# capital. Mapping the lowercase set keeps the fold consistent after lower():
# "ОККО" and "окко" both arrive at "okko".
_LOOKALIKES = str.maketrans("аветкмнорсухі", "abetkmhopcyxi")


def normalize_key(text: str) -> str:
    low = (text or "").lower().translate(_APOSTROPHES).translate(_LOOKALIKES)
    low = CARD_TAIL.sub("", low)
    low = LONG_NUMBER.sub("", low)
    return " ".join(low.split())
