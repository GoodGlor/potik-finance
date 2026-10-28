"""Write the Debug-only demo data: a short, invented month and a half.

    uv run python scripts/build_demo_sample.py

`build_ios_seed.py` builds the same file from a private export; this script
writes a small public sample instead, so the app has something to show on a
fresh clone. Every merchant, amount and account here is invented. The four
purchases the UI tests name by id keep their ids, dates, sums and categories.

Deterministic: same script -> byte-identical output.
"""

from __future__ import annotations

import importlib.util
import json
import uuid
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios" / "MonitorFinance" / "Resources" / "demo.json"

spec = importlib.util.spec_from_file_location("build_ios_seed", ROOT / "scripts" / "build_ios_seed.py")
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)

MAIN, SAVINGS, CREDIT = "*1001", "*1002", "*1004"
KYIV = ZoneInfo("Europe/Kyiv")

# (id or None, date, merchant, amount in kopecks, kind, category, resolution, card)
# Receipts are attached below by id.
ROWS = [
    ("551dced6-6d40-5401-aaa6-50d42f5336a2", "2026-08-19T11:03", "WOG", -80000, "expense", "Автомобіль", "rule", MAIN),
    (None, "2026-08-18T19:42", "Сільпо", -64230, "expense", "Продукти", "rule", MAIN),
    ("1c3deb13-0989-556b-b0c4-1b8047a6d6a1", "2026-08-17T21:00", "Паркінг Центр", -12000, "expense", "Автомобіль", "rule", MAIN),
    (None, "2026-08-14T08:15", "Uklon", -18700, "expense", "Транспорт", "rule", MAIN),
    (None, "2026-08-12T13:05", "Aroma Kava", -9600, "expense", "Кафе та ресторани", "rule", MAIN),
    (None, "2026-08-12T00:10", "Megogo", -41900, "expense", "Розваги", "rule", MAIN),
    (None, "2026-08-10T16:30", "Rozetka", -129900, "expense", "Покупки", "pending", MAIN),
    (None, "2026-08-09T18:20", "АТБ", -23815, "expense", "Продукти", "rule", MAIN),
    (None, "2026-08-07T10:00", "Переказ на свою картку *1004", -150000, "transfer", "", "transfer", MAIN),
    (None, "2026-08-06T09:00", "Переказ зі своєї картки *1002", 300000, "transfer", "", "transfer", MAIN),
    (None, "2026-08-05T12:00", "ТОВ «Приклад Софт»", 4500000, "income", "Зарплата", "rule", MAIN),
    ("812b1e29-45a5-5871-a4ef-28e4820924c4", "2026-08-04T17:39", "Термінал самообслуговування", -20000, "expense", "Готівка", "rule", MAIN),
    (None, "2026-08-02T15:45", "Аптека АНЦ", -31240, "expense", "Медицина", "rule", MAIN),
    (None, "2026-08-01T09:00", "Відсотки за кредитом", -142000, "expense", "Кредит", "rule", MAIN),
    (None, "2026-07-30T19:10", "Сільпо", -51780, "expense", "Продукти", "rule", MAIN),
    ("e9d0f6eb-4061-5ed2-a17f-32f1e4ba4dc3", "2026-07-24T09:21", "Мийка самообслуговування", -14580, "expense", "Автомобіль", "rule", MAIN),
    (None, "2026-07-22T20:00", "Повернись живим", -50000, "expense", "Благодійність", "rule", MAIN),
    (None, "2026-07-21T17:35", "Зоомагазин «Хвостик»", -36000, "expense", "Тварини", "rule", MAIN),
    (None, "2026-07-19T14:20", "McDonald's", -21400, "expense", "Кафе та ресторани", "rule", MAIN),
    (None, "2026-07-16T11:30", "Justin", -8500, "expense", "Послуги", "pending", MAIN),
    (None, "2026-07-15T10:00", "Комунальні послуги", -214000, "expense", "Квартплата", "rule", MAIN),
    (None, "2026-07-05T12:00", "ТОВ «Приклад Софт»", 4500000, "income", "Зарплата", "rule", MAIN),
    (None, "2026-08-03T19:30", "На картку", -80000, "transfer", "", "transfer", MAIN),
    (None, "2026-07-10T09:00", "Стипендія", 250000, "income", "Стипендія", "rule", SAVINGS),
    # The newest row, and a purchase with no receipt on it.
    (None, "2026-08-21T18:12", "Сільпо", -38940, "expense", "Продукти", "rule", MAIN),
    (None, "2026-08-20T08:40", "ОККО", -65000, "expense", "Автомобіль", "rule", MAIN),
    (None, "2026-06-11T15:20", "Rozetka", -54900, "expense", "Покупки", "pending", MAIN),
    # The credit card only ever receives money from the everyday one.
    (None, "2026-08-07T10:01", "Переказ зі своєї картки *1001", 150000, "transfer", "", "transfer", CREDIT),
    (None, "2026-05-08T09:30", "Переказ на свою картку *1004", -200000, "transfer", "", "transfer", MAIN),
    (None, "2026-05-08T09:31", "Переказ зі своєї картки *1001", 200000, "transfer", "", "transfer", CREDIT),
    (None, "2026-06-17T22:40", "Uklon", -16500, "expense", "Транспорт", "rule", MAIN),
    (None, "2026-04-26T12:15", "Сільпо", -45520, "expense", "Продукти", "rule", MAIN),
    (None, "2026-03-12T00:10", "Megogo", -19900, "expense", "Розваги", "rule", MAIN),
]
# Earlier months, so the history reaches back to January: pay, a grocery run
# and the credit interest every month.
for _n, _m in enumerate(range(1, 7)):
    ROWS += [
        (None, f"2026-0{_m}-05T12:00", "ТОВ «Приклад Софт»", 4500000, "income", "Зарплата", "rule", MAIN),
        (None, f"2026-0{_m}-1{_n}T18:30", "АТБ", -(31000 + 2370 * _n), "expense", "Продукти", "rule", MAIN),
        (None, f"2026-0{_m}-01T09:00", "Відсотки за кредитом", -(139000 + 1100 * _n), "expense", "Кредит", "rule", MAIN),
    ]
# Generic merchants the queue cannot group: each one is its own card with a date.
for _n, (_day, _merchant, _amount) in enumerate([
        ("2026-08-16T10:05", "Платіж", -45000), ("2026-08-11T12:40", "NovaPay", -6500),
        ("2026-08-08T14:10", "NovaPay", -12900), ("2026-08-02T09:30", "На картку", -30000),
        ("2026-07-28T12:00", "Платіж", -27500), ("2026-07-25T16:45", "NovaPay", -8900),
        ("2026-07-12T11:15", "На картку", -50000), ("2026-07-03T13:00", "Платіж", -19900),
        ("2026-06-24T17:20", "NovaPay", -15400), ("2026-06-09T10:10", "На картку", -20000),
        ("2026-05-21T19:00", "Платіж", -33000)]):
    ROWS.append((None, _day, _merchant, _amount, "expense", "Послуги", "pending", MAIN))
SUGGESTIONS = {"Rozetka": ["Покупки", "Дім та ремонт", "Подарунки"],
               "Justin": ["Послуги", "Покупки", "Подарунки"],
               "NovaPay": ["Послуги", "Покупки", "Подарунки"],
               "Платіж": ["Послуги", "Квартплата", "Покупки"],
               "На картку": ["Подарунки", "Послуги", "Покупки"]}
ATTACHED = {"551dced6-6d40-5401-aaa6-50d42f5336a2": "1000000005",   # fuel, 800,00 ₴
            "e9d0f6eb-4061-5ed2-a17f-32f1e4ba4dc3": "1000000006"}   # car wash, 145,80 ₴


def main() -> None:
    receipts = seed._sample_receipts()
    receipt_id = {r["documentNumber"]: r["id"] for r in receipts}
    transactions = []
    for n, (tx_id, when, merchant, amount, kind, category, resolution, card) in enumerate(ROWS):
        tx_id = tx_id or str(uuid.uuid5(seed.NAMESPACE, f"demo-sample|{n}"))
        transactions.append({
            "id": tx_id,
            "date": datetime.fromisoformat(when).replace(tzinfo=KYIV).isoformat(),
            "merchant": merchant,
            "amount": amount,
            "kind": kind,
            "category": category,
            "resolution": resolution,
            "suggestions": SUGGESTIONS.get(merchant, []) if resolution == "pending" else [],
            "bankId": "monobank",
            "cardSuffix": card,
            "receiptId": receipt_id[ATTACHED[tx_id]] if tx_id in ATTACHED else None,
            "splits": [],
        })
    transactions.sort(key=lambda t: t["date"])   # oldest first, as the builder writes it
    rules = [
        {"merchantKey": seed.rule_key(CREDIT), "category": "Кредит", "ambiguous": False},
        {"merchantKey": seed.rule_key("NovaPay"), "category": None, "ambiguous": True},
        {"merchantKey": seed.rule_key("АТБ"), "category": "Продукти", "ambiguous": False},
        {"merchantKey": seed.rule_key("Uklon"), "category": "Транспорт", "ambiguous": False},
        {"merchantKey": seed.rule_key("Megogo"), "category": "Розваги", "ambiguous": False},
    ]
    accounts = [
        {"id": aid, "suffix": suffix, "type": kind, "currency": "UAH",
         "balance": balance, "creditLimit": limit}
        for aid, suffix, kind, balance, limit in seed.OWN_CARDS
    ]
    demo = {
        "transactions": transactions,
        "receipts": receipts,
        "rules": rules,
        "accounts": {"monobank": accounts, "privatbank": []},
    }
    OUT.write_text(json.dumps(demo, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{len(transactions)} transactions -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
