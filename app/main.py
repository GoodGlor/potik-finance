"""HTTP surface.

Deliberately thin and deliberately incomplete: there is no transaction storage
yet, so nothing here persists except rules. `/accounts` and `/preview` prove
the monobank path end to end; `/rules/confirm` is the write side of the
review queue. Ingest and the queue itself arrive with storage.
"""
import logging
from datetime import UTC, datetime, timedelta

import httpx
from fastapi import FastAPI, HTTPException, Query, Response
from pydantic import BaseModel, field_validator

from app.config import settings
from app.connectors.base import Flow, NormalizedTransaction, Source
from app.connectors.monobank import InvalidToken, MonobankConnector, MonobankError, RateLimited
from app.core import vocabulary
from app.core.categories import FULL_NAME, NAME_INITIALS
from app.core.resolver import Decider, resolve
from app.core.rules import RuleStore
from app.core.text import normalize_key
from app.core.transfers import classify_transfer
from app.llm.openrouter import suggest

logging.basicConfig(level=settings.log_level)

app = FastAPI(title="MonitorFinance", version="0.1.0")

# One owner, one store. Tests swap this for RuleStore() in memory.
store = RuleStore(settings.sqlite_path)
vocabulary.seed(store)


def _connector() -> MonobankConnector:
    if not settings.monobank_token:
        raise HTTPException(503, "MF_MONOBANK_TOKEN is not set")
    return MonobankConnector(settings.monobank_token)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/accounts")
async def accounts() -> list[dict]:
    try:
        found = await _connector().accounts()
    except InvalidToken:
        raise HTTPException(401, "monobank rejected the token — reconnect required") from None
    except RateLimited:
        raise HTTPException(
            503, "monobank rate limit hit — retry in 60s", headers={"Retry-After": "60"}
        ) from None
    except MonobankError as exc:
        raise HTTPException(502, str(exc)) from None
    return [
        {
            "id": a.external_id,
            "name": a.name,
            "card_mask": a.card_mask,
            "currency_code": a.currency_code,
            "balance": a.balance,
            "credit_limit": a.credit_limit,
            "own_funds": a.balance - a.credit_limit,
            "credit_used": a.credit_limit - a.balance,
        }
        for a in found
    ]


@app.get("/preview/{account_id}")
async def preview(account_id: str, days: int = Query(31, ge=1, le=365)) -> dict:
    """Fetch and resolve a window without storing anything.

    Ranges longer than 31 days are paced at one request per minute by the
    connector, so a 365-day preview takes about twelve minutes. That is
    monobank's limit, not ours.
    """
    connector = _connector()
    try:
        info = await connector.client_info()
        account = next((a for a in info.accounts if a.external_id == account_id), None)
        if account is None:
            raise HTTPException(404, f"no such account: {account_id}")
        to = datetime.now(UTC)
        rows = await connector.transactions(account, to - timedelta(days=days), to)
    except InvalidToken:
        raise HTTPException(401, "monobank rejected the token — reconnect required") from None
    except RateLimited:
        raise HTTPException(
            503, "monobank rate limit hit — retry in 60s", headers={"Retry-After": "60"}
        ) from None
    except MonobankError as exc:
        raise HTTPException(502, str(exc)) from None

    resolved = [(row, resolve(row, store, info.owner_name)) for row in rows]
    return {
        "count": len(resolved),
        "unresolved": sum(1 for _, r in resolved if r.decided_by is Decider.ASK),
        "transactions": [
            {
                "id": row.external_id,
                "at": row.occurred_at.isoformat(),
                "amount": row.amount,
                "currency_code": row.currency_code,
                "description": row.raw_merchant,
                "key": r.key,
                "category": r.category,
                "flow": r.flow,
                "decided_by": r.decided_by,
                "transfer_kind": r.transfer_kind,
                "ask_reason": r.ask_reason,
                "commission": row.commission,
                "cashback": row.cashback,
                "hold": row.hold,
            }
            for row, r in resolved
        ],
    }


class Confirmation(BaseModel):
    key: str
    category: str
    note: str | None = None

    @field_validator("key", "category")
    @classmethod
    def _not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("must not be blank")
        return value.strip()


@app.post("/rules/confirm", status_code=204)
async def confirm(body: Confirmation) -> Response:
    """The write side of the review queue.

    `category` may be anything non-blank: a proposed-new label confirmed here
    IS the decision to add it. The note, if any, is keyed the same way the
    merchant is, so 'Чайник' and 'чайник' are one note rule.
    """
    note_key = normalize_key(body.note) if body.note and body.note.strip() else None
    store.confirm(normalize_key(body.key), body.category, note_key=note_key)
    return Response(status_code=204)


class SuggestRequest(BaseModel):
    description: str
    note: str | None = None


@app.post("/suggest")
async def suggest_categories(body: SuggestRequest) -> dict:
    """Ask the LLM tail. Off by default; the cascade resolves almost everything
    without it, and switching it on is a deliberate, measured decision.

    Unlike `/preview`, there is no upstream transfer typing here — the
    description comes straight from the request body. So this endpoint types
    it itself, with no client-info call (rate limited, and unneeded: the
    `Від:`/masked-PAN/jar/migration rules that catch name-bearing text do not
    depend on the owner name), and refuses to send anything transfer-shaped
    to the third party rather than risk a personal name leaving the machine.
    """
    if not settings.llm_enabled or not settings.openrouter_key:
        raise HTTPException(
            503, "LLM layer is off — set MF_LLM_ENABLED=true and MF_OPENROUTER_KEY"
        )
    synthetic = NormalizedTransaction(
        external_id="suggest",
        occurred_at=datetime.now(UTC),
        amount=-1,
        currency_code=980,
        flow=Flow.EXPENSE,
        raw_category=body.description,
        raw_merchant=body.description,
        source=Source.MONOBANK,
    )
    # classify_transfer's own initials/full-name gate only fires on a row
    # already known to carry MCC 4829 (outgoing money-transfer code); this
    # endpoint has no MCC to give it, and faking 4829 would make every
    # ordinary merchant fall into that branch's CARD catch-all too. So the
    # same two name patterns are checked directly against the description,
    # alongside whatever classify_transfer catches from the text alone.
    # Trade-off, accepted deliberately: without the MCC gate, FULL_NAME also
    # refuses real three-word Cyrillic business names (e.g. "Аптека Доброго
    # Дня") — a false positive judged far cheaper than letting a real
    # person's full name reach a third-party LLM.
    is_transfer_shaped = (
        classify_transfer(synthetic, "") is not None
        or NAME_INITIALS.search(body.description) is not None
        or FULL_NAME.search(body.description) is not None
    )
    if is_transfer_shaped:
        raise HTTPException(
            422,
            "this description looks like it names a person, so it was not sent "
            "to a third party — pick a category manually instead",
        )
    async with httpx.AsyncClient() as http:
        try:
            s = await suggest(
                body.description, body.note, vocabulary.CATEGORIES,
                api_key=settings.openrouter_key, model=settings.openrouter_model, client=http,
            )
        except httpx.HTTPError as exc:
            raise HTTPException(502, f"openrouter: {exc}") from None
    return {"categories": list(s.categories), "proposed": s.proposed}
