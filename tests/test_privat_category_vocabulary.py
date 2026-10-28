"""Board #149 — every PrivatBank category word must have been ruled on.

`PrivatMapper.categoryMap` exists because the suggestion chip **creates
whatever category it carries**, so a statement word passed through verbatim
becomes a real category on one tap. Its own comment predicted the failure:

> Board #15 spent a card folding forty names down to nineteen; without this
> table the chip grows them back, one tap at a time, and the person doing it
> is being *helpful* — they tapped the button the app offered.

That is exactly what happened. The owner asked «There is an Automobile, so why
is Авто there?», and «Авто» was one of **nine** bank words with no entry.

**Nothing in the app could have caught this**, which is why the guard lives
here. The chip is correct code doing what it is told; the gap is in a table,
and a table's completeness can only be judged against the vocabulary the bank
actually uses. That vocabulary is `OBSERVED` below, measured from the owner's
own categorization log on 2026-08-31 — not from documentation, which
PrivatBank does not publish.

The rule every word must satisfy, one of:

  * mapped by `categoryMap`;
  * already one of the seeded categories, so it passes through harmlessly;
  * a MECHANISM word, refused a chip entirely (`mechanismWords`);
  * recorded in `unmappedByDecision` — a deliberate refusal to invent an
    answer, with the reason written beside it.

**Merchant names are deliberately absent.** These are the bank's category
vocabulary, not the person's data; this repository is public and the owner's
merchants stay out of it.
"""

import json
import re

from tests.test_ios_seed import ROOT

MAPPER = ROOT / "ios/MonitorFinance/Import/PrivatMapper.swift"
REFERENCE = ROOT / "ios/MonitorFinance/Resources/reference.json"

#: Every distinct `category` PrivatBank wrote in the owner's real statements
#: and letters. Measured 2026-08-31 from the device log; extend it when a
#: new word is seen, never trim it.
OBSERVED: tuple[str, ...] = (
    "АЗС",
    "Авто",
    "Аптеки",
    "Годинники та ювелірні вироби",
    "Дім та ремонт",
    "Заощадження",
    "Зняття готівки",
    "Квіти",
    "Комуналка та Інтернет",
    "Краса",
    "Кіно",
    "Медичні послуги",
    "Одяг та взуття",
    "Освіта",
    "Перекази",
    "Платежі за реквізитами",
    "Поповнення мобільного",
    "Послуги",
    "Ресторани, кафе, бари",
    "Розваги",
    "Супермаркети та продукти",
    "Таксі",
    "Тварини",
    "Транспорт",
    "Туризм",
    "Цифрові товари",
)


def _swift_set(name: str) -> set[str]:
    src = MAPPER.read_text(encoding="utf-8")
    body = src.split(f"static let {name}: Set<String> = [", 1)[1].split("]", 1)[0]
    return set(re.findall(r'"([^"]+)"', body))


def _swift_constants() -> dict[str, str]:
    """`Type.member` -> its literal, for map values that are not string literals.

    `"зняття готівки": BudgetMath.cashCategory` is one, and the first draft of
    this guard silently skipped it — reporting a mapped word as unruled. A
    parser that quietly drops entries is worse than none, so the constants are
    resolved rather than special-cased.

    Keyed on the MEMBER name alone rather than on `Type.member`: matching the
    enclosing type would mean parsing Swift's nesting, and a resolver that gets
    that subtly wrong fails silently in the direction that hides gaps.
    """
    out: dict[str, str] = {}
    for path in (ROOT / "ios/MonitorFinance").rglob("*.swift"):
        for member, value in re.findall(r'static let (\w+)\s*=\s*"([^"]+)"',
                                        path.read_text(encoding="utf-8")):
            out.setdefault(member, value)
    return out


def _category_map() -> dict[str, str]:
    src = MAPPER.read_text(encoding="utf-8")
    body = src.split("static let categoryMap: [String: String] = [", 1)[1].split("\n    ]", 1)[0]
    constants = _swift_constants()
    mapped = {}
    for key, raw in re.findall(r'"([^"]+)"\s*:\s*("[^"]+"|[\w.]+)\s*,', body):
        mapped[key] = (raw[1:-1] if raw.startswith('"')
                       else constants.get(raw.rsplit(".", 1)[-1], raw))
    return mapped


def _seeded() -> set[str]:
    categories = json.loads(REFERENCE.read_text(encoding="utf-8"))["categories"]
    return {c["name"] if isinstance(c, dict) else c for c in categories}


def test_every_observed_privat_word_is_ruled_on():
    mapped, seeded = _category_map(), _seeded()
    mechanism = _swift_set("mechanismWords")
    recorded = _swift_set("unmappedByDecision")

    unruled = []
    for word in OBSERVED:
        key = word.lower()
        if key.startswith("переказ"):
            continue          # refused by the prefix rule in `suggestion(for:)`
        if key in mapped or key in mechanism or key in recorded or word in seeded:
            continue
        unruled.append(repr(word))

    assert unruled == [], (
        "PrivatBank writes these and nothing in the app has an opinion, so the "
        f"suggestion chip will create each one as a new category on one tap: {unruled}. "
        "Add an entry to `categoryMap`, or — if inventing a target would be a "
        "guess — to `unmappedByDecision` with the reason beside it."
    )


def test_the_word_the_owner_reported_is_folded():
    """«Авто» specifically, because it is the one that was actually reported.

    A general guard that happened to pass would not prove the reported defect
    was fixed; this names it.
    """
    assert _category_map().get("авто") == "Автомобіль"


def test_a_mapped_word_never_targets_a_category_that_does_not_exist():
    """A fold onto a name nobody seeded just renames the problem.

    Board #15 folded forty names to nineteen; a target outside that set is a
    fortieth name arriving by the back door.
    """
    seeded = _seeded()
    stray = {word: target for word, target in _category_map().items() if target not in seeded}
    assert stray == {}, (
        f"these fold onto categories the seed does not ship: {stray}. An "
        "unresolved `Type.member` here means the constant resolver missed it, "
        "which would also make the main guard report a mapped word as unruled."
    )


def test_the_map_is_idempotent():
    """`suggestion(for:)`'s doc claims it: no value is also a key.

    It matters because a row imported before board #14 stores «Готівка» where
    it now stores «Зняття готівки», so an already-translated word has to
    survive a second pass unchanged.
    """
    mapped = _category_map()
    keys = {k.lower() for k in mapped}
    collisions = {v for v in mapped.values() if v.lower() in keys}
    assert collisions == set(), f"these values are also keys: {collisions}"


def test_the_guard_can_fire():
    """A clean run above has to mean something.

    It scans a hand-written table against a hand-written list, which is exactly
    the shape of check that passes because it matched nothing at all.
    """
    assert len(_category_map()) >= 25, "the map parser read almost nothing"
    assert len(_seeded()) == 19, "the seeded vocabulary changed — re-read board #15"
    assert "азс" in _swift_set("unmappedByDecision")

    # And the rule really does reject: a word nobody has ruled on must fail.
    mapped, seeded = _category_map(), _seeded()
    mechanism = _swift_set("mechanismWords")
    recorded = _swift_set("unmappedByDecision")
    invented = "категорія-якої-немає"
    assert not (invented in mapped or invented in mechanism
                or invented in recorded or invented in seeded), (
        "the guard's own membership test accepts a word nobody ever ruled on"
    )
