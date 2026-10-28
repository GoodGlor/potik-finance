"""Build the iOS seed from the owner's Gmail->Sheets export.

    uv run python scripts/build_ios_seed.py            # default paths
    uv run python scripts/build_ios_seed.py IN.xlsx OUT.json

The xlsx is real personal data and is gitignored. The output is the same
spending shape with every person removed, and IS committed. Deterministic:
same input -> byte-identical output (stable ids, sorted keys).
"""

from __future__ import annotations

import json
import re
import sys
import unicodedata
import uuid
from collections import Counter, defaultdict
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from zoneinfo import ZoneInfo

import openpyxl

from app.core.products import ALL_GROUPS, GROUPS

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_IN = ROOT / "data" / "finance-monitor.local.xlsx"
DEFAULT_OUT = ROOT / "ios" / "MonitorFinance" / "Resources" / "reference.json"
KYIV = ZoneInfo("Europe/Kyiv")
NAMESPACE = uuid.UUID("6f1c2a6e-5b7e-4d0c-9a1e-2b3c4d5e6f70")

# --- scrubbing ---------------------------------------------------------------
# Measured against the actual file, see the spec's "Privacy of the dataset".
# The test imports PERSONAL_PATTERNS, so adding a pattern here is enough to
# make the test demand it be scrubbed.
CYR = "А-ЯІЇЄҐа-яіїєґ'ʼ"
SHORT_NAME = re.compile(rf"^[А-ЯІЇЄҐ][{CYR}]+ [А-ЯІЇЄҐ]\.$")
LATIN_SENDER = re.compile(r"від [A-Z]+ [A-Z]+")
FULL_NAME = re.compile(
    # Unanchored: a three-word Cyrillic name is a person wherever it sits in
    # the string, not only at position 0 or right after "ФОП ".
    rf"[А-ЯІЇЄҐ][{CYR}]+\s+[А-ЯІЇЄҐ][{CYR}]+\s+[А-ЯІЇЄҐ][{CYR}]+"
    r"|\bФОП\b"
)
LONG_DIGITS = re.compile(r"\d{8,}")
PERSONAL_PATTERNS = [SHORT_NAME, LATIN_SENDER, FULL_NAME, LONG_DIGITS]

# Two outliers FULL_NAME would not catch on its own: an upper-case name with
# a trailing ФОП, and a one-word ФОП.
FOP_LOOSE = re.compile(r"ФОП", re.IGNORECASE)

# This pipeline's text is Gmail-parsed and riddled with Latin letters that are
# visually identical to a Cyrillic counterpart (mixed script inside a single
# word). SHORT_NAME/FULL_NAME/FOP_LOOSE are written against Cyrillic-only
# character classes, so a name carrying even one such letter would pass them
# unmatched. `canonical` builds a match-only copy — Latin lookalikes mapped
# to Cyrillic — so matching sees the canonical form. It is never used for the
# emitted merchant string, which keeps its original spelling unless scrubbed.
_HOMOGLYPH_TO_CYRILLIC = str.maketrans({
    "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "I": "І",
    "K": "К", "M": "М", "O": "О", "P": "Р", "T": "Т", "X": "Х",
    "a": "а", "c": "с", "e": "е", "i": "і", "o": "о", "p": "р", "x": "х",
})


def canonical(s: str) -> str:
    return s.translate(_HOMOGLYPH_TO_CYRILLIC)


def scrub(merchant: str, category: str) -> str:
    m = merchant.strip()
    canon = canonical(m)
    if CARD_RE.fullmatch(m) and m not in SEEDED_SUFFIXES:
        # A bare "*NNNN" merchant is a card fragment, not a merchant name —
        # scrub it unless it names one of the owner's own seeded cards.
        return "Переказ на картку"
    if re.fullmatch(r"\d{8,}(\.0)?", m):
        return "Платіж"
    if SHORT_NAME.match(m) or SHORT_NAME.match(canon):
        # "Особа · К." — keeps rows distinguishable, does not re-match SHORT_NAME
        return f"Особа · {m.split()[-1]}"
    if LATIN_SENDER.search(m):
        return "Зарахування переказу: від Родич"
    is_org = (
        FULL_NAME.search(m) or FULL_NAME.search(canon)
        or FOP_LOOSE.search(m) or FOP_LOOSE.search(canon)
    )
    if is_org:
        return f"Підприємець · {category}"   # never "ФОП", which FULL_NAME would flag
    m = LONG_DIGITS.sub("…", m)
    m = re.sub(r",?\s*ID платежу:\s*…", "", m)
    return m.strip()


# --- derivation -------------------------------------------------------------
KIND = {"Витрата": "expense", "Дохід": "income", "Переказ": "transfer"}
PRIMARY_CARD = "*1001"
CARD_RE = re.compile(r"\*\d{4}")
# Merchants the sheet itself cannot categorize consistently; the queue's
# day-one backlog. NovaPay is "?" in the owner's own rules tab.
PENDING_MERCHANTS = {"NovaPay", "На картку"}
PENDING_PREFIXES = ("PORTMONE",)
PENDING_CATEGORIES = {"Оплата частинами", "Покупки / Побут"}

# The sheet's vocabulary is the owner's own, built up over years of his own
# bookkeeping. The app's is what a person meets on their FIRST pick, before any
# of that history exists — and 40 names is not a list, it is a wall (board #15).
#
# So the sheet's names are folded into 19: 15 things money is spent on, plus the
# four `BudgetMath.incomeCategories`. Nothing here is deleted — every row keeps a
# category, it is just a broader one. The rules the folding follows:
#
# * **A name that is really a transfer is not a category at all** (boards #6, #7,
#   #13). «Перекази — свої картки» maps to NOTHING: those rows are `.transfer`
#   and the app never stores a category on one, so the demo should not either.
#   The rest describe WHO was paid, and the app's vocabulary describes WHAT was
#   bought, so they fold into the nearest what.
# * **One name per idea.** «Аптеки»/«Медицина», «Комуналка»/«Квартплата»,
#   «Оплата частинами»/«Кредит» are one thing said twice.
# * **Nothing owner-specific.** «Суші» is a fine line in a personal sheet and
#   a strange thing to offer a stranger on their first pick.
#
# «Зняття готівки» → «Готівка» is the older half of this, from board #6: it
# names the EVENT at the ATM, and since the app stopped treating a withdrawal as
# "not spending" the category has to name what the money BECAME.
CATEGORY_RENAMES = {
    "Зняття готівки": "Готівка",
    # one name per idea
    "Аптеки": "Медицина",
    "Комуналка": "Квартплата",
    "Інтернет": "Квартплата",
    "Ремонт техніки": "Дім та ремонт",
    "Оплата частинами": "Кредит",
    "Таксі": "Транспорт",
    "Суші": "Кафе та ресторани",
    "Освіта": "Послуги",
    "Страхування": "Послуги",
    "Платежі до бюджету": "Послуги",
    "Спорт": "Розваги",
    "Цифрові товари": "Розваги",
    # the things a person buys, under one heading
    "Покупки / Побут": "Покупки",
    "Одяг та взуття": "Покупки",
    "Книги та канцтовари": "Покупки",
    "Квіти": "Покупки",
    "Краса": "Покупки",
    # who was paid → what it paid for, as far as the sheet can say
    "Переказ друзям": "Покупки",
    "Переказ рідним": "Покупки",
    "Перекази — людям / P2P": "Покупки",
    "Перекази — сервіси": "Послуги",
    # and the one that is not a category
    "Перекази — свої картки": "",
}

# The single exception the table above cannot express: money ARRIVING from
# another person is not a purchase, and «Подарунки» is the one income category
# the budget deliberately leaves out of earnings — which is right for a transfer
# from a relative, and would be wrong for anything the owner earned.
INCOME_OVERRIDES = {"Перекази — людям / P2P": "Подарунки"}

# Categories the app needs that the sheet never had to name. «Заощадження» is
# the starter plan's savings line and the answer for a jar top-up; without it
# seeded, `setBudget` conjures it for anyone who saves a plan and the picker
# offers it to nobody else.
EXTRA_CATEGORIES = {"Заощадження"}

# Board #61. An SF Symbol per seeded category.
#
# Here rather than hand-written into reference.json, because that file is
# GENERATED and `test_rebuild_reproduces_the_committed_seed` compares it
# byte-for-byte against a fresh build — an edit made in the JSON survives
# exactly until the next rebuild.
#
# Every name below must also appear in `CategoryIcon.offered`, and must be a
# symbol UIKit actually resolves. Both are asserted: the first by a guard in
# this repo's pytest suite, the second by `CategoryIconTests`, because a
# misspelt symbol renders as nothing at all — a blank swatch, silently.
CATEGORY_ICONS = {
    "Автомобіль": "car",
    "Благодійність": "heart",
    "Готівка": "banknote",
    "Дім та ремонт": "hammer",
    "Заощадження": "lock",
    "Зарплата": "briefcase",
    "Інші надходження": "arrow.down.left",
    "Кафе та ресторани": "fork.knife",
    "Квартплата": "house",
    "Кредит": "creditcard",
    "Медицина": "cross.case",
    "Подарунки": "gift",
    "Покупки": "bag",
    "Послуги": "wrench.and.screwdriver",
    "Продукти": "cart",
    "Розваги": "gamecontroller",
    "Стипендія": "graduationcap",
    "Тварини": "pawprint",
    "Транспорт": "bus",
}


# Board #94. The seed says what each category MEANS, so nothing has to infer it
# from the name. Before this, `BudgetMath` matched these three names against a
# hardcoded set, and renaming or deleting one silently re-based the budget.
# «Подарунки» is money in that no plan is built on, which is why it is not
# `earned` — see `BudgetMath.income(_:includeGifts:categories:)`.
EARNED_CATEGORIES = {"Зарплата", "Стипендія", "Інші надходження"}
UNEARNED_CATEGORIES = {"Подарунки"}


def category_kind(name: str) -> str:
    if name in EARNED_CATEGORIES:
        return "earned"
    if name in UNEARNED_CATEGORIES:
        return "unearned"
    return "spending"


def rename_category(category: str, kind: str = "Витрата") -> str:
    if kind == "Дохід" and category in INCOME_OVERRIDES:
        return INCOME_OVERRIDES[category]
    return CATEGORY_RENAMES.get(category, category)

OWN_CARDS = [
    # id, suffix, type, balance in minor units — the last row each card appears on
    ("mono-1001", "*1001", "black", 1_254_300, None),
    ("mono-1002", "*1002", "white", 3_820_000, None),
    ("mono-1003", "*1003", "white", 512_750, None),
    ("mono-1004", "*1004", "platinum", 125_000, 3_000_000),
]
SEEDED_SUFFIXES = {suffix for _id, suffix, *_ in OWN_CARDS}


def _uuid(seed_text: str) -> str:
    return str(uuid.uuid5(NAMESPACE, seed_text))


def _sample_receipts() -> list[dict]:
    """Content for the simulator's scanner, not fixtures for matching — since
    the 2026-08-23 spec revision a receipt is always scanned from a purchase
    that is already known, so nothing here has to meet a seed row. One sample
    carries a sum that matches no purchase on purpose, so the mismatch notice
    has something to fire on (D4/D5). The six fiscalSum totals are pinned as
    literals in tests/test_ios_seed.py::test_seed_ships_the_sample_receipts
    — change a price here and that test is where it will fail.

    Two of them are also PRE-ATTACHED to a purchase further down (see the
    `receipt:*-attached` loop): each of those two must total its purchase
    exactly, or the one reachable split example ships in the state the split
    refuses."""

    def item(name: str, qty: float, price: int) -> dict:
        return {"id": _uuid(f"item:{name}:{qty}:{price}"), "name": name,
                "qty": qty, "price": price, "sum": round(qty * price)}

    def receipt(key: str, seller: str, when: str, register: str,
                check: str, items: list[dict]) -> dict:
        return {"id": _uuid(f"receipt:{key}"), "scannedAt": when,
                "registerNumber": register, "documentNumber": check,
                "fiscalTime": when, "fiscalSum": sum(i["sum"] for i in items),
                "sellerName": seller, "items": items}

    return [
        receipt("market", "Магазин «Затишок»", "2026-08-21T18:12:00+03:00",
                "3000000001", "1000000001", [
                    item("Хліб житній", 1, 32_50),
                    item("Молоко 2,5% 900 мл", 2, 41_90),
                    item("Яйця С1, 10 шт", 1, 68_00),
                    item("Сир кисломолочний 9%", 1, 74_30),
                    item("Яблука", 1.24, 39_00),
                    item("Курка охолоджена", 1.68, 129_90),
                    item("Олія соняшникова 1 л", 1, 78_40),
                    item("Кава мелена 250 г", 1, 189_00),
                ]),
        receipt("kiosk", "Кіоск «Ранок»", "2026-08-20T09:05:00+03:00",
                "3000000002", "1000000002", [
                    item("Вода негазована 0,5 л", 1, 21_00),
                    item("Батончик горіховий", 1, 31_99),
                ]),
        # 287,01 ₴ — deliberately a sum no purchase in the seed carries, so
        # the mismatch notice fires against any queue item (D5). 287,00 ₴
        # collides with a real amount; the odd kopeck is the whole point.
        receipt("cafe", "Кав'ярня «Пауза»", "2026-08-19T15:40:00+03:00",
                "3000000003", "1000000003", [
                    item("Капучино", 2, 85_00),
                    item("Круасан з мигдалем", 1, 92_01),
                    item("Вода 0,33 л", 1, 25_00),
                ]),
        receipt("fuel", "АЗС «Приклад»", "2026-08-20T08:41:00+03:00",
                "3000000004", "1000000004", [
                    # 12.40 × 74_50 = 923_80 exactly. `item()` computes the sum
                    # as round(qty * price); a price that does not divide
                    # cleanly lands a kopeck off and fails the literal above.
                    item("Бензин А-95-Євро5", 12.40, 74_50),
                ]),
        receipt("fuel-attached", "АЗС «Приклад»", "2026-08-19T17:26:00+03:00",
                "3000000005", "1000000005", [
                    # 10.00 × 80_00 = 800_00 — round, but the only clean pair
                    # that lands exactly on the purchase it is attached to.
                    item("Бензин А-95-Євро5", 10.00, 80_00),
                ]),
        # The SECOND pre-attached receipt, in a different month from the one
        # above — the fixture the period-scoped drill assertions need. Until
        # it existed the seed had exactly one confirmable split, so a drill
        # filtered to one period and a drill filtered to nothing at all
        # returned the identical single row and nothing could tell them apart.
        #
        # A car wash, not a fill-up, on purpose. `ProductGuess` files
        # «Мийка автомобіля» under the SAME product group as the petrol above
        # («Пальне та автотовари» — it is one of that group's own keywords),
        # which is what makes the two months comparable inside one group;
        # but `FuelGrade.parse` finds no grade token in it, so
        # `Derived.fillUps` — and every Заправки assertion — ignores it and
        # the fuel log stays a one-row fixture.
        receipt("wash-attached", "Автомийка «Приклад»", "2026-07-24T09:21:00+03:00",
                "3000000006", "1000000006", [
                    # 1 × 145_80 — exactly the purchase it attaches to, so
                    # this one is confirmable without a remainder line too.
                    # That purchase is the NEWEST of its spending category in
                    # its month, so a category-narrowed feed puts it at the
                    # top of the list and a UI test reaches it without
                    # scrolling.
                    item("Мийка автомобіля", 1, 145_80),
                ]),
    ]


def rule_key(merchant: str) -> str:
    """The key the iOS app will look a merchant up by.

    Byte-for-byte what `MerchantKey.normalize` does in Swift — NFC, trim,
    lowercase, in that order. It is NOT `app.core.text.normalize_key`, which
    also folds apostrophes, card tails and Cyrillic/Latin lookalikes: whatever
    is written here is only ever compared against the Swift side, and a key
    normalised by a rule Swift does not share can never match anything.

    Un-normalised keys were shipped until now (`"NovaPay"`, streets in caps),
    so every seeded rule was unreachable from the app: the queue looked up a
    lowercased key and found nothing.
    """
    return unicodedata.normalize("NFC", merchant).strip().lower()


def minor(amount) -> int:
    return int((Decimal(str(amount)) * 100).quantize(Decimal(1)))


def read_rows(ws):
    for row in ws.iter_rows(min_row=2, values_only=True):
        if row[0] is None:
            continue
        date, time, kind, category, merchant, amount, _balance, _tid = row
        yield date, time, kind, str(category or ""), str(merchant or ""), amount


def suggestions_for(merchant: str, by_merchant, global_top) -> list[str]:
    own = [c for c, _ in by_merchant[merchant].most_common()]
    out: list[str] = []
    for c in own + global_top:
        if c not in out:
            out.append(c)
        if len(out) == 3:
            break
    return out


def build(src: Path = DEFAULT_IN, dst: Path = DEFAULT_OUT) -> None:
    wb = openpyxl.load_workbook(src, data_only=True)
    rows = sorted(read_rows(wb["data"]), key=lambda r: (r[0], r[1]))

    by_merchant: dict[str, Counter] = defaultdict(Counter)
    global_counts: Counter = Counter()
    for _d, _t, kind, category, merchant, _a in rows:
        if kind == "Витрата":
            # Renamed here, not in `read_rows`: `PENDING_CATEGORIES` below tests
            # the SHEET's own words, and folding them first made that set match
            # nothing at all — silently, taking four rows out of the demo queue.
            # Suggestions, though, are offered to a person, so they must speak
            # the app's vocabulary.
            by_merchant[merchant][rename_category(category)] += 1
            global_counts[rename_category(category)] += 1
    global_top = [c for c, _ in global_counts.most_common(5)]

    rules_tab = {}
    for key, category, *_ in wb["Sheet2"].iter_rows(min_row=2, values_only=True):
        if key and category and not str(key).startswith("*0000"):
            rules_tab[str(key)] = rename_category(str(category))

    transactions = []
    for i, (date, time, kind_uk, sheet_category, merchant, amount) in enumerate(rows):
        kind = KIND[kind_uk]
        category = rename_category(sheet_category, kind_uk)
        local = datetime.combine(date.date(), time, tzinfo=KYIV)
        value = minor(amount)
        if kind == "expense":
            value = -value
        elif kind == "transfer":
            value = value if merchant.startswith("Переказ зі своєї картки") else -value

        # The sheet cannot tell us which card a transfer row actually sits on
        # (the named card is the *other* side of the transfer — source on
        # money-in, destination on money-out — and a balance-continuity check
        # yields 36 fragments, not 4 chains). The attribution below is
        # necessarily a fiction; keep it joinable to a seeded account by only
        # trusting a named card the owner actually holds, else fall back.
        card = PRIMARY_CARD
        if (
            kind == "transfer"
            and (m := CARD_RE.search(merchant))
            and m.group(0) in SEEDED_SUFFIXES
        ):
            card = m.group(0)

        if kind == "transfer":
            resolution, sugg = "transfer", []
        elif (
            merchant in PENDING_MERCHANTS
            or merchant.startswith(PENDING_PREFIXES)
            or sheet_category in PENDING_CATEGORIES
        ):
            resolution, sugg = "pending", suggestions_for(merchant, by_merchant, global_top)
        else:
            # `.rule`, never `.user` — board #12. `.user` means "this person
            # answered this row", and `AppStore.recentCategories` reads it to
            # decide what «Нещодавні» offers. Demo rows claiming it put five
            # categories under that heading on a phone whose owner had not yet
            # tapped anything, «Інші надходження» among them. The demo may show
            # a filled-in app; it may not put words in its owner's mouth.
            resolution, sugg = "rule", []

        transactions.append(
            {
                "id": str(uuid.uuid5(NAMESPACE, f"{i}|{local.isoformat()}|{value}")),
                "date": local.isoformat(),
                "kind": kind,
                "category": category,
                "merchant": scrub(merchant, category),
                "amount": value,
                "cardSuffix": card,
                "bankId": "monobank",
                "receiptId": None,
                "splits": [],
                "resolution": resolution,
                "suggestions": sugg,
            }
        )

    # Two purchases ship with a receipt already attached, one per month, so
    # a period-scoped view of the receipts namespace has something to
    # include AND something to exclude. Each is located by (day, category,
    # amount) and must match exactly one row — a filter that matched two
    # would attach the same receipt id to a row chosen by list order.
    for key, day, amount in [
        ("receipt:fuel-attached", "2026-08-19", -800_00),
        ("receipt:wash-attached", "2026-07-24", -145_80),
    ]:
        matches = [t for t in transactions
                   if t["date"].startswith(day)
                   and t["category"] == "Автомобіль" and t["amount"] == amount]
        if len(matches) != 1:
            raise SystemExit(
                f"expected exactly one {day} Автомобіль purchase of {amount}, "
                f"found {len(matches)}")
        matches[0]["receiptId"] = _uuid(key)

    # Emptied AFTER renaming, not before: «Перекази — свої картки» folds to the
    # empty string on purpose, and a blank name in this list becomes a blank row
    # in the picker.
    categories = sorted(
        (
            {rename_category(c, k) for _d, _t, k, c, _m, _a in rows if c}
            | {rename_category(str(r[0]))
               for r in wb["Категорії"].iter_rows(min_row=2, values_only=True) if r[0]}
            | EXTRA_CATEGORIES
        ) - {""}
    )

    # A rule about a person is meaningless once the person is scrubbed, and two
    # scrubbed keys could collide — keep only keys the scrubber leaves alone.
    # The surviving keys are normalised on the way out (see `rule_key`); the
    # RAW key is what the scrub filter and the resolution pass above test,
    # because those compare against the sheet's own merchant text.
    rules = [
        {
            "merchantKey": rule_key(key),
            "category": None if category == "?" else category,
            "ambiguous": category == "?",
        }
        for key, category in sorted(rules_tab.items())
        # A rule whose category folded away to nothing (board #15: the sheet's
        # own-card-transfer category is not a category) would be a rule teaching
        # the empty string. All three were keyed to a masked card number, which
        # `GenericMerchant` refuses to apply a rule for anyway — they have been
        # dead weight since board #7.
        if scrub(key, category) == key and category
    ]
    keys = [r["merchantKey"] for r in rules]
    if len(set(keys)) != len(keys):
        # Two sheet keys that differ only in case are one rule to the app, and
        # silently keeping both would make which one wins depend on order.
        raise ValueError(f"rule keys collide once normalised: {sorted(keys)}")

    banks = [
        {
            "id": "monobank",
            "displayName": "monobank",
            "status": "available",
            "connected": False,
            "accounts": [
                {
                    "id": aid,
                    "suffix": suffix,
                    "type": kind,
                    "currency": "UAH",
                    "balance": balance,
                    "creditLimit": limit,
                }
                for aid, suffix, kind, balance, limit in OWN_CARDS
            ],
        },
        {
            "id": "privatbank",
            "displayName": "ПриватБанк",
            "status": "statement",
            "connected": False,
            "accounts": [],
        },
    ]

    sample_receipts = _sample_receipts()
    product_groups = [
        {"name": name, "keywords": list(GROUPS.get(name, ()))} for name in ALL_GROUPS
    ]

    reference = {
        # Bank identity only — the ACCOUNTS are the owner's and go to demo.json.
        "banks": [{**b, "accounts": []} for b in banks],
        "categories": [
            {"name": c, "tintIndex": None, "icon": CATEGORY_ICONS.get(c),
             "kind": category_kind(c)}
            for c in categories
        ],
        "productGroups": product_groups,
    }
    demo = {
        "transactions": transactions,
        "receipts": sample_receipts,
        "rules": rules,
        "accounts": {b["id"]: b["accounts"] for b in banks},
    }
    out_dir = dst.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "reference.json").write_text(
        json.dumps(reference, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    (out_dir / "demo.json").write_text(
        json.dumps(demo, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    print(f"{len(transactions)} transactions -> {out_dir}")


if __name__ == "__main__":
    args = [Path(a) for a in sys.argv[1:]]
    build(*args)
