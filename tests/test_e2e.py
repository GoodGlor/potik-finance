"""The product loop, end to end over HTTP: preview → confirm → preview again.

Every other test checks one layer against its own contract. This one checks
that the layers add up to the thing the app is for — the owner sees a purchase
nobody could categorize, answers once, and is never asked again. A regression
anywhere along that path (the key written under a different normalization than
it is read, a confirmation that lands but is never consulted, transfers
miscounted as needing review) leaves every unit test green and the product
broken.

monobank is mocked; no network, no token, no rate-limit sleeps.
"""
import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app import main
from app.connectors.monobank import API_BASE
from app.core.rules import RuleStore

OWNER = "Шевченко Тарас"
ACCOUNT = "acc-uah"

CLIENT_INFO = {
    "clientId": "e2e",
    "name": OWNER,
    "accounts": [
        {
            "id": ACCOUNT,
            "balance": 512750,
            "creditLimit": 3000000,
            "type": "black",
            "currencyCode": 980,
            "maskedPan": ["444111****5555"],
        }
    ],
    "jars": [],
}

# One of each kind the cascade must handle differently: a seeded merchant, the
# bank's own monthly interest sentence, an own-card top-up naming the owner in
# the transliterated form the bank actually sends, and a merchant nothing can
# place. Amounts and wording are the shapes seen in the real statement.
STATEMENT = [
    {"id": "tx-silpo", "time": 1_785_000_000, "description": "Сільпо", "mcc": 5411,
     "amount": -41230, "operationAmount": -41230, "currencyCode": 980, "hold": False},
    {"id": "tx-interest", "time": 1_785_100_000, "description": "Списання відсотків за липень",
     "mcc": 6012, "amount": -142000, "operationAmount": -142000, "currencyCode": 980,
     "hold": False},
    {"id": "tx-topup", "time": 1_785_200_000, "description": "Від: Shevchenko Taras",
     "mcc": 6012, "amount": 350000, "operationAmount": 350000, "currencyCode": 980,
     "hold": False, "counterName": "Shevchenko Taras"},
    {"id": "tx-unknown", "time": 1_785_300_000, "description": "BIRYUZA SHOP", "mcc": 5944,
     "amount": -120000, "operationAmount": -120000, "currencyCode": 980, "hold": False},
]


@pytest.fixture
def client(monkeypatch):
    """A real app with an empty, seeded store — no on-disk database."""
    store = RuleStore()
    from app.core import vocabulary

    vocabulary.seed(store)
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main.settings, "monobank_token", "e2e-token")
    return TestClient(main.app)


def _mock_monobank() -> None:
    respx.get(f"{API_BASE}/personal/client-info").mock(
        return_value=httpx.Response(200, json=CLIENT_INFO)
    )
    respx.route(method="GET", path__startswith="/personal/statement/").mock(
        return_value=httpx.Response(200, json=STATEMENT)
    )


def _by_id(payload: dict) -> dict:
    return {t["id"]: t for t in payload["transactions"]}


@respx.mock
def test_the_owner_answers_once_and_is_never_asked_again(client):
    _mock_monobank()

    first = client.get(f"/preview/{ACCOUNT}", params={"days": 31})
    assert first.status_code == 200
    rows = _by_id(first.json())

    # The four kinds resolve by four different mechanisms, and only one of them
    # is a question for the owner.
    assert rows["tx-silpo"]["category"] == "Продукти"
    assert rows["tx-silpo"]["decided_by"] == "rule"
    assert rows["tx-interest"]["category"] == "Відсотки за кредитом"
    assert rows["tx-interest"]["decided_by"] == "pattern"
    assert rows["tx-topup"]["decided_by"] == "transfer"
    assert rows["tx-topup"]["transfer_kind"] == "own_card"
    assert rows["tx-topup"]["category"] is None
    assert rows["tx-unknown"]["decided_by"] == "ask"
    assert rows["tx-unknown"]["ask_reason"] == "unknown"

    # The own-card top-up has no category either, but it is NOT a question:
    # counting it as one would send the owner to review their own transfers.
    assert first.json()["unresolved"] == 1

    # The owner answers, using the key the preview handed back.
    confirm = client.post(
        "/rules/confirm",
        json={"key": rows["tx-unknown"]["key"], "category": "Одяг"},
    )
    assert confirm.status_code == 204

    second = client.get(f"/preview/{ACCOUNT}", params={"days": 31})
    again = _by_id(second.json())
    assert again["tx-unknown"]["category"] == "Одяг"
    assert again["tx-unknown"]["decided_by"] == "rule"
    assert again["tx-unknown"]["ask_reason"] is None
    assert second.json()["unresolved"] == 0

    # Nothing else moved. A confirmation teaches one merchant, not a category
    # to everything that happened to be nearby.
    for tx_id in ("tx-silpo", "tx-interest", "tx-topup"):
        assert again[tx_id]["category"] == rows[tx_id]["category"]
        assert again[tx_id]["decided_by"] == rows[tx_id]["decided_by"]


@respx.mock
def test_a_merchant_confirmed_two_ways_starts_asking_every_time(client):
    """The app must notice, by itself, that a shop cannot be learned.

    The owner buys a kettle, then a gift, from one marketplace. After the
    second answer the merchant rule is withdrawn, because any rule it could
    hold would be wrong about half the purchases from then on.

    Uses a merchant with no history rather than Rozetka: Rozetka ships already
    marked ambiguous, so it would test the seed, not the learning.
    """
    _mock_monobank()
    key = "marketplace-x"

    client.post("/rules/confirm", json={"key": key, "category": "Техніка"})
    assert main.store.rule(key) == "Техніка"
    assert not main.store.is_ambiguous(key)

    client.post("/rules/confirm", json={"key": key, "category": "Подарунки"})
    assert main.store.is_ambiguous(key)
    assert main.store.rule(key) is None


@respx.mock
def test_the_seeded_ambiguous_merchant_is_asked_from_the_very_first_row(client):
    """Rozetka is asked on day one, before the owner has taught anything.

    Shipping it pre-marked is what stops the app confidently filing a gift as
    groceries once and then repeating that answer forever.
    """
    _mock_monobank()
    respx.route(method="GET", path__startswith="/personal/statement/").mock(
        return_value=httpx.Response(200, json=[
            {"id": "tx-rozetka", "time": 1_785_400_000, "description": "Rozetka",
             "mcc": 5262, "amount": -21900, "operationAmount": -21900,
             "currencyCode": 980, "hold": False},
        ])
    )
    payload = client.get(f"/preview/{ACCOUNT}", params={"days": 31}).json()
    row = payload["transactions"][0]
    assert row["decided_by"] == "ask"
    assert row["ask_reason"] == "ambiguous"
    assert row["category"] is None


@respx.mock
def test_a_transfer_shaped_description_never_reaches_the_llm(client, monkeypatch):
    """The owner's condition for enabling the LLM at all, checked at the door.

    `/suggest` is the one path with no upstream transfer typing, so the guard
    lives on the endpoint. With the layer switched ON, a description naming a
    person must be refused before any request is built.
    """
    monkeypatch.setattr(main.settings, "llm_enabled", True)
    monkeypatch.setattr(main.settings, "openrouter_key", "not-a-real-key")

    for description in ("Ігор Н.", "Від: Shevchenko Taras", "414962****3333"):
        r = client.post("/suggest", json={"description": description})
        assert r.status_code == 422, description

    # respx is active and has no route for openrouter.ai, so any outbound call
    # would raise rather than pass silently. Reaching this line proves none was
    # attempted for any of the descriptions above.
