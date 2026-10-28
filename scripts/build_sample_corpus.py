"""Write a synthetic 12-month monobank statement in the API's own JSON shape.

Same patterns the categorizer tests exercise (monthly interest, own-card
top-ups, person transfers, a migration pair, two ambiguous Rozetka rows and
one generic SHOP), but every id, time, amount and counterparty is invented.

    uv run python scripts/build_sample_corpus.py

Writes tests/fixtures/monobank_corpus.jsonl. Deterministic: same script -> same file.
"""
import json
from pathlib import Path
import random
import sys
from datetime import datetime, timedelta, timezone

rng = random.Random(20260901)
KYIV = timezone(timedelta(hours=3))
MONTHS = [(2025, m) for m in range(9, 13)] + [(2026, m) for m in range(1, 9)]
ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
# Interest is charged for the previous month; the bank's own wording, including
# the Latin "i" it writes in «сiчень».
INTEREST_FOR = ["серпень", "вересень", "жовтень", "листопад", "грудень", "сiчень",
                "лютий", "березень", "квітень", "травень", "червень", "липень"]

rows = []


def add(year, month, description, mcc, uah, *, currency=980, op=None, counter=None,
        hold=False, cashback=0, day=None, orig=None):
    when = datetime(year, month, day or rng.randint(1, 28), rng.randint(8, 21),
                    rng.randint(0, 59), rng.randint(0, 59), tzinfo=KYIV)
    amount = round(uah * 100)
    row = {
        "id": "".join(rng.choice(ID_CHARS) for _ in range(16)),
        "time": int(when.timestamp()),
        "mcc": mcc,
        "originalMcc": orig or mcc,
        "amount": amount,
        "operationAmount": amount if op is None else round(op * 100),
        "currencyCode": currency,
        "commissionRate": 0,
        "cashbackAmount": cashback,
        "hold": hold,
        "description": description,
    }
    if counter:
        row["counterName"] = counter
    rows.append(row)


def price(lo, hi):
    return round(rng.uniform(lo, hi), 2)


for i, (y, m) in enumerate(MONTHS):
    add(y, m, f"Списання відсотків за {INTEREST_FOR[i]}", 6012, -price(1250, 1650), day=1)
    add(y, m, "Netflix", 7829, -price(410, 440), currency=978, op=-9.99, day=12, orig=4899)

for y, m in rng.sample(MONTHS, 10):
    add(y, m, "Сільпо", 5411, -price(180, 520), cashback=rng.choice([0, 300, 500]))
for desc, mcc, lo, hi, n in [
    ("McDonald’s", 5814, 120, 260, 3), ("WOG", 5541, 600, 1100, 2), ("ОККО", 5541, 600, 1100, 1),
    ("UPG", 5541, 500, 900, 1), ("АТБ", 5499, 90, 300, 1), ("NOVUS", 5411, 150, 400, 1),
    ("Аптека Доброго Дня", 5912, 80, 350, 1), ("Епіцентр", 5211, 300, 900, 1),
    ("lifecell", 4814, 150, 250, 1), ("Rozetka", 5262, 300, 1500, 2), ("SHOP", 5499, 50, 200, 1),
]:
    for y, m in rng.sample(MONTHS, n):
        add(y, m, desc, mcc, -price(lo, hi))

for y, m in rng.sample(MONTHS, 8):
    add(y, m, "Від: Owner Name", 6012, price(1000, 4000), counter="Owner Name")
for y, m in rng.sample(MONTHS, 4):
    add(y, m, "Особа І.", 4829, -price(200, 1500))
for desc, mcc, sign, lo, hi in [
    ("Від: Родич Особа", 4829, 1, 500, 2000), ("Переказ на картку", 4829, -1, 300, 1500),
    ("my privat", 4829, -1, 500, 3000), ("000000****1111", 4829, -1, 200, 800),
    ("Поповнення «На Чай»", 4829, -1, 50, 200), ("З Білої картки", 4829, 1, 500, 2000),
    ("З доларової картки", 4829, 1, 500, 2000), ("За перевищення кредитного ліміту", 6012, -1, 50, 150),
]:
    y, m = rng.choice(MONTHS)
    add(y, m, desc, mcc, sign * price(lo, hi))

# The migration pair: the same sum leaving one account and arriving in another.
moved = price(2000, 5000)
add(2026, 3, "Списання коштів в рамках міграції рахунку\n", 4829, -moved, day=10)
add(2026, 3, "Зарахування коштів в рамках міграції рахунку\n", 4829, moved, day=10)

# Two rows still on hold, as a live statement always has.
for row in rng.sample([r for r in rows if r["description"] in ("Сільпо", "McDonald’s")], 2):
    row["hold"] = True

# Three domestic rows the bank recoded as well.
for row, orig in zip([r for r in rows if r["description"] in ("Сільпо", "WOG")][:3], (5499, 5499, 5542)):
    row["originalMcc"] = orig

rows.sort(key=lambda r: -r["time"])
OUT = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "monobank_corpus.jsonl"
with open(sys.argv[1] if len(sys.argv) > 1 else OUT, "w", encoding="utf-8") as out:
    for r in rows:
        out.write(json.dumps(r, ensure_ascii=False) + "\n")
print(len(rows), "rows")
