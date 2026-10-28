"""The LLM tail. No network; the one contract that matters is what leaves."""
import json

import httpx
import respx

from app.core.categories import scrub_merchant
from app.llm.openrouter import OPENROUTER_URL, suggest

CHOICES = ("Продукти", "Техніка", "Подарунки", "Одяг")


def _reply(payload: dict) -> httpx.Response:
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(payload)}}]})


@respx.mock
async def test_suggestions_are_filtered_to_the_choice_list_and_capped_at_three():
    route = respx.post(OPENROUTER_URL).mock(
        return_value=_reply(
            {
                "categories": ["Техніка", "Нісенітниця", "Подарунки", "Одяг", "Продукти"],
                "proposed": None,
            }
        )
    )
    async with httpx.AsyncClient() as http:
        s = await suggest("Rozetka", "чайник", CHOICES, api_key="k", model="m", client=http)
    assert s.categories == ("Техніка", "Подарунки", "Одяг")
    assert s.proposed is None
    assert route.calls[0].request.headers["authorization"] == "Bearer k"


@respx.mock
async def test_a_proposed_new_label_comes_back_as_a_proposal_not_a_category():
    respx.post(OPENROUTER_URL).mock(return_value=_reply({"categories": [], "proposed": "Спорт"}))
    async with httpx.AsyncClient() as http:
        s = await suggest("Sportmaster", None, CHOICES, api_key="k", model="m", client=http)
    assert s.categories == () and s.proposed == "Спорт"


@respx.mock
async def test_personal_names_are_scrubbed_before_sending():
    route = respx.post(OPENROUTER_URL).mock(
        return_value=_reply({"categories": [], "proposed": None})
    )
    async with httpx.AsyncClient() as http:
        await suggest("Переказ Іваненко І.П.", None, CHOICES, api_key="k", model="m", client=http)
    sent = route.calls[0].request.content.decode()
    assert "Іваненко" not in sent and "особа" in sent


@respx.mock
async def test_the_request_carries_no_amount_field():
    """By construction: suggest() has no amount parameter. This pins the body."""
    route = respx.post(OPENROUTER_URL).mock(
        return_value=_reply({"categories": [], "proposed": None})
    )
    async with httpx.AsyncClient() as http:
        await suggest("Rozetka", "чайник 186 грн", CHOICES, api_key="k", model="m", client=http)
    body = json.loads(route.calls[0].request.content)
    assert set(body) == {"model", "messages", "response_format"}


def test_scrub_merchant_does_not_catch_latin_transliterated_names():
    """KNOWN GAP, not a bug: FULL_NAME/NAME_INITIALS in app/core/categories.py are
    Cyrillic-only, so a transliterated name such as monobank's counterName form
    "Shevchenko Taras" passes through scrub_merchant() unchanged — it is verified
    here so nobody mistakes silence for protection. A Latin-name regex was
    rejected (see app/llm/openrouter.py's module docstring): it cannot be told
    apart from real merchants like "Garden Wine" or "GREEN BAR". The actual
    mitigation is upstream: rows carrying a counterparty name are typed as
    transfers in app/core/transfers.py and never reach this layer at all.
    """
    assert scrub_merchant("Shevchenko Taras") == "Shevchenko Taras"
    assert scrub_merchant("Ігор Н.") == "особа"
    assert scrub_merchant("Іваненко Іван Петрович") == "особа"


@respx.mock
async def test_garbage_from_the_model_is_an_empty_suggestion_not_an_exception():
    respx.post(OPENROUTER_URL).mock(
        return_value=httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})
    )
    async with httpx.AsyncClient() as http:
        s = await suggest("X", None, CHOICES, api_key="k", model="m", client=http)
    assert s.categories == () and s.proposed is None
