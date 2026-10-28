"""Ukrainian → Latin per the 2010 Cabinet of Ministers table (КМУ №55).

Needed for exactly one comparison: /personal/client-info names the owner in
Cyrillic ("Шевченко Тарас") while a statement's counterName is the bank's
own transliteration ("Shevchenko Taras"). Equality never holds, so the owner
is transliterated and the two are compared as token sets — word order is not
stable either.
"""

_TABLE = {
    "а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "e", "є": "ie",
    "ж": "zh", "з": "z", "и": "y", "і": "i", "ї": "i", "й": "i", "к": "k", "л": "l",
    "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ю": "iu",
    "я": "ia", "ь": "", "'": "", "’": "",
}
# Word-initial forms differ for five letters.
_INITIAL = {"є": "ye", "ї": "yi", "й": "y", "ю": "yu", "я": "ya"}


def translit_ua(text: str) -> str:
    words = []
    for word in (text or "").lower().split():
        word = word.replace("зг", "zgh")  # the one digraph exception
        out = []
        for i, ch in enumerate(word):
            if i == 0 and ch in _INITIAL:
                out.append(_INITIAL[ch])
            else:
                out.append(_TABLE.get(ch, ch))
        words.append("".join(out))
    return " ".join(words)


def same_person(owner_name: str, counter_name: str | None) -> bool:
    """True when a transfer counterparty is the account owner, in either script."""
    if not owner_name or not counter_name:
        return False
    counter = set(counter_name.lower().split())
    return (
        counter == set(owner_name.lower().split())
        or counter == set(translit_ua(owner_name).split())
    )
