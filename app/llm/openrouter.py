"""Layer 4: the LLM tail. Reached only by descriptions layers 1-3 could not
place — in a year of this account, three rows.

What leaves the machine: the scrubbed description, the owner's note if they
wrote one, and the category list. No amount — the function has no parameter
for one. `scrub_merchant()` only catches Cyrillic name forms (a full name, or
initials after a surname); a Latin-transliterated name such as "Shevchenko
Taras" — the exact form monobank's `counterName` uses — passes through it
unchanged, so it is NOT a backstop for Latin names. A regex for "two
capitalised Latin words" was considered and rejected: it cannot be told apart
from real merchant names of the same shape (`Garden Wine`, `GREEN BAR`, `ORBITA
SHOP`, `RIVER RESTAURANT`), and this layer has no other way to tell a name
from a shop. What actually keeps personal names off the wire is a single
mechanism, not defense-in-depth: rows carrying a counterparty name are typed
as transfers in `app/core/transfers.py` upstream and never reach this
function at all — for `/preview`, which resolves real monobank rows through
that cascade first. `/suggest` has no upstream: it hands this function an
arbitrary caller-supplied description, so `app/main.py` runs `classify_transfer()`
itself against a synthetic row before ever calling `suggest()`, plus the same
`NAME_INITIALS`/`FULL_NAME` check directly (that gate is normally reached only
on a row already known to carry MCC 4829, which `/suggest` has no way to
supply), and refuses the request rather than let a transfer-shaped description
through. Free-tier OpenRouter models log prompts; this is written as if every
prompt is public.
"""
import json
from dataclasses import dataclass

import httpx

from app.core.categories import scrub_merchant

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

_SYSTEM = (
    "You categorize bank transactions for a personal budget in Ukraine. "
    "Given a merchant description, an optional note from the owner saying what was bought, "
    "and a fixed list of categories, reply with JSON only: "
    '{"categories": [up to three items from the list, best first], '
    '"proposed": a short new Ukrainian category label if none fit, else null}. '
    'Never invent a category inside "categories"; put it in "proposed".'
)


@dataclass(frozen=True, slots=True)
class Suggestion:
    categories: tuple[str, ...]
    proposed: str | None


async def suggest(
    description: str,
    note: str | None,
    choices: tuple[str, ...],
    *,
    api_key: str,
    model: str,
    client: httpx.AsyncClient,
) -> Suggestion:
    merchant = scrub_merchant(description)
    user = f"Merchant: {merchant}\n"
    if note and note.strip():
        user += f"Owner's note: {note.strip()}\n"
    user += "Categories: " + "; ".join(choices)

    response = await client.post(
        OPENROUTER_URL,
        headers={"Authorization": f"Bearer {api_key}"},
        json={
            "model": model,
            "messages": [
                {"role": "system", "content": _SYSTEM},
                {"role": "user", "content": user},
            ],
            "response_format": {"type": "json_object"},
        },
        timeout=30.0,
    )
    response.raise_for_status()
    try:
        content = response.json()["choices"][0]["message"]["content"]
        payload = json.loads(content)
    except (KeyError, IndexError, ValueError, TypeError):
        return Suggestion((), None)

    allowed = set(choices)
    categories = tuple(
        c for c in payload.get("categories") or () if isinstance(c, str) and c in allowed
    )[:3]
    proposed = payload.get("proposed")
    return Suggestion(
        categories, proposed.strip() if isinstance(proposed, str) and proposed.strip() else None
    )
