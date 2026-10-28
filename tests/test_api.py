"""HTTP surface. The connector is never hit; the store is swapped for an in-memory one."""
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from app import main
from app.connectors.base import Flow, NormalizedTransaction, Source
from app.connectors.monobank import MonobankConnector, RateLimited
from app.core.resolver import Decider, resolve
from app.core.rules import RuleStore
from app.core.text import normalize_key


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "store", RuleStore())
    return TestClient(main.app)


def test_confirm_writes_a_rule(client):
    r = client.post("/rules/confirm", json={"key": "biryuza shop", "category": "Одяг"})
    assert r.status_code == 204
    assert main.store.rule("biryuza shop") == "Одяг"


def test_confirm_with_note_writes_a_note_rule(client):
    body = {"key": "rozetka", "category": "Техніка", "note": "Чайник"}
    r = client.post("/rules/confirm", json=body)
    assert r.status_code == 204
    assert main.store.rule("rozetka") is None
    # note_key goes through normalize_key just like the merchant key does (see
    # resolver.resolve, which looks it up the same way) — "Чайник" folds to an
    # opaque key, not to the plain lowercase word.
    assert main.store.note_rule("rozetka", normalize_key("чайник")) == "Техніка"


def test_confirm_normalizes_a_raw_key_so_resolve_can_find_it(client):
    """A client posting the raw, un-normalized description (not `/preview`'s
    already-normalized `key`) must still write a rule `resolve()` can read —
    otherwise the rule is silently unreachable."""
    raw = "  ОККО Азс 123  "
    r = client.post("/rules/confirm", json={"key": raw, "category": "Заправка"})
    assert r.status_code == 204

    row = NormalizedTransaction(
        external_id="tx-1",
        occurred_at=datetime(2026, 1, 1, tzinfo=UTC),
        amount=-50000,
        currency_code=980,
        flow=Flow.EXPENSE,
        raw_category=raw,
        raw_merchant=raw,
        source=Source.MONOBANK,
    )
    resolution = resolve(row, main.store, owner_name="")
    assert resolution.category == "Заправка"
    assert resolution.decided_by is Decider.RULE


def test_confirm_rejects_empty_category(client):
    assert client.post("/rules/confirm", json={"key": "x", "category": "  "}).status_code == 422


def test_preview_without_token_is_503(client, monkeypatch):
    monkeypatch.setattr(main.settings, "monobank_token", "")
    assert client.get("/preview/acc").status_code == 503


def test_accounts_is_503_with_retry_after_when_monobank_rate_limits(client, monkeypatch):
    """A client must be able to tell 'retry in 60s' apart from 'the bank is
    broken' (a generic 502) — RateLimited gets its own branch."""
    monkeypatch.setattr(main.settings, "monobank_token", "tok")

    async def _raise_rate_limited(self):
        raise RateLimited("monobank rate limit hit")

    monkeypatch.setattr(MonobankConnector, "accounts", _raise_rate_limited)
    r = client.get("/accounts")
    assert r.status_code == 503
    assert r.headers["retry-after"] == "60"


def test_suggest_is_503_when_the_llm_layer_is_off(client, monkeypatch):
    monkeypatch.setattr(main.settings, "llm_enabled", False)
    assert client.post("/suggest", json={"description": "Rozetka"}).status_code == 503


def test_suggest_refuses_a_vid_prefixed_description(client, monkeypatch):
    """No client-info call is made — the owner-name-independent transfer
    rules are enough to catch this, and /suggest must never call it (it is
    rate limited in its own right)."""
    monkeypatch.setattr(main.settings, "llm_enabled", True)
    monkeypatch.setattr(main.settings, "openrouter_key", "k")
    r = client.post("/suggest", json={"description": "Від: Петренко А."})
    assert r.status_code == 422


def test_suggest_refuses_a_name_initials_description(client, monkeypatch):
    monkeypatch.setattr(main.settings, "llm_enabled", True)
    monkeypatch.setattr(main.settings, "openrouter_key", "k")
    r = client.post("/suggest", json={"description": "Ігор Н."})
    assert r.status_code == 422


def test_suggest_refuses_a_real_pharmacy_as_a_deliberate_false_positive(client, monkeypatch):
    """FULL_NAME matches any three capitalised Cyrillic words — a common shape
    for Ukrainian business names, not just personal names. "Аптека Доброго
    Дня" is a real pharmacy chain, and this asserts it is
    refused anyway.

    That is a deliberate trade-off, not a bug to be quietly tolerated:
    `app/core/transfers.py` avoids exactly this false positive by gating
    FULL_NAME on outgoing MCC 4829 (see its `test_a_three_word_pharmacy_is_not_a_person`),
    but `/suggest` has no MCC to gate on — a request body is just a
    description. Checking FULL_NAME ungated means a three-word merchant name
    is occasionally refused; the alternative is checking it not at all, which
    would let a real three-word personal name (e.g. "Іваненко Іван
    Петрович") reach a third-party LLM. Failing closed here is correct. A
    real fix would be plumbing the row's actual MCC through the /suggest
    request rather than weakening this check.
    """
    monkeypatch.setattr(main.settings, "llm_enabled", True)
    monkeypatch.setattr(main.settings, "openrouter_key", "k")
    r = client.post("/suggest", json={"description": "Аптека Доброго Дня"})
    assert r.status_code == 422


def test_suggest_accepts_an_ordinary_merchant(client, monkeypatch):
    """A real merchant with a Latin two-word name must not be refused —
    that is exactly the false-positive a name regex would have caused."""
    monkeypatch.setattr(main.settings, "llm_enabled", True)
    monkeypatch.setattr(main.settings, "openrouter_key", "k")

    async def fake_suggest(*args, **kwargs):
        from app.llm.openrouter import Suggestion
        return Suggestion(("Продукти",), None)

    monkeypatch.setattr(main, "suggest", fake_suggest)
    r = client.post("/suggest", json={"description": "Garden Wine"})
    assert r.status_code == 200
