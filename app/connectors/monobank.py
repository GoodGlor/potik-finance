"""monobank personal-API connector.

Two constraints shape this whole module, and both come from monobank rather
than from us:

  * a statement request covers at most 31 days, and
  * statements are rate limited to one request per 60 seconds.

Both are the connector's problem, not the caller's. `transactions()` accepts
any date range and returns every row in it; internally it splits the range
into 31-day windows and paces the requests. A historical backfill is therefore
slow by construction — a year of history is twelve windows, so twelve minutes —
and callers are expected to run it in the background and show progress.
"""
import asyncio
import logging
import time
from datetime import UTC, datetime, timedelta

import httpx

from app.connectors.base import (
    AccountInfo,
    BankConnector,
    ClientInfo,
    Flow,
    NormalizedTransaction,
    Source,
)

log = logging.getLogger(__name__)

API_BASE = "https://api.monobank.ua"

# monobank's documented maximum is 31 days + 1 hour (2 682 000s). We ask for a
# flat 31 days so the request is comfortably inside the limit rather than
# resting on the extra hour.
MAX_WINDOW = timedelta(days=31)

# BOTH /personal/client-info and /personal/statement are limited to one request
# per 60 seconds ("Обмеження на використання функції не частіше ніж 1 раз у 60
# секунд"). The limit is documented per function, so each endpoint gets its own
# pacer — sharing one would make an accounts-then-statement call wait a full
# minute in the middle for no reason.
#
# The extra second is deliberate: the server measures against its own clock,
# and landing exactly on the boundary earns a 429.
CALL_INTERVAL = 61.0


class MonobankError(RuntimeError):
    """Any non-success response from monobank."""


class InvalidToken(MonobankError):
    """403 — the token is wrong, revoked, or for a different environment.

    Surfaced distinctly because the only fix is the user pasting a new token,
    and the UI shows a persistent 'reconnect' banner rather than a transient
    error. Existing data stays untouched.
    """


class RateLimited(MonobankError):
    """429 — we asked too soon despite pacing. Retried with backoff."""


class _Pacer:
    """Serializes calls to one endpoint and keeps them 60s apart.

    A lock rather than a token bucket: the limit is one *in flight and then a
    wait*, not a burst allowance, so concurrent callers must queue rather than
    all discover the limit at once.

    One instance per endpoint — see CALL_INTERVAL for why they are not shared.
    """

    def __init__(self, interval: float = CALL_INTERVAL) -> None:
        self._interval = interval
        self._lock = asyncio.Lock()
        self._last: float | None = None

    async def __aenter__(self) -> None:
        await self._lock.acquire()
        if self._last is not None:
            wait = self._interval - (time.monotonic() - self._last)
            if wait > 0:
                log.info("monobank pacing: sleeping %.1fs before next call", wait)
                await asyncio.sleep(wait)

    async def __aexit__(self, *exc: object) -> None:
        self._last = time.monotonic()
        self._lock.release()


class MonobankConnector(BankConnector):
    def __init__(
        self,
        token: str,
        client: httpx.AsyncClient | None = None,
        pacer: _Pacer | None = None,
        info_pacer: _Pacer | None = None,
    ) -> None:
        if not token:
            raise ValueError("monobank token is required")
        self._token = token
        self._client = client or httpx.AsyncClient(base_url=API_BASE, timeout=30.0)
        self._pacer = pacer or _Pacer()
        self._info_pacer = info_pacer or _Pacer()

    async def _get(self, path: str) -> object:
        try:
            response = await self._client.get(path, headers={"X-Token": self._token})
        except httpx.HTTPError as exc:
            # A timeout or DNS failure is monobank being unreachable, not a
            # bug here — callers already catch MonobankError and turn it into
            # a 502; without this it escapes as an unhandled 500 instead.
            raise MonobankError(f"monobank request failed: {exc}") from exc
        if response.status_code == 403:
            raise InvalidToken("monobank rejected the token")
        if response.status_code == 429:
            raise RateLimited("monobank rate limit hit")
        if response.status_code >= 400:
            raise MonobankError(f"monobank returned {response.status_code}: {response.text[:200]}")
        return response.json()

    async def client_info(self) -> ClientInfo:
        """Client info is rate limited to 1/60s in its own right — hence a pacer.

        Callers should cache the result rather than re-fetching per operation:
        a minute of the account list's own budget is a minute the user waits.
        """
        async with self._info_pacer:
            payload = await self._get("/personal/client-info")
        assert isinstance(payload, dict)
        accounts = tuple(
            AccountInfo(
                external_id=account["id"],
                name=account.get("type", "account"),
                card_mask=_card_mask(account),
                currency_code=account["currencyCode"],
                balance=account["balance"],
                credit_limit=account.get("creditLimit", 0),
            )
            for account in payload.get("accounts", [])
        )
        jars = tuple(jar.get("title", "") for jar in payload.get("jars", []) or [])
        return ClientInfo(owner_name=payload.get("name", ""), accounts=accounts, jars=jars)

    async def accounts(self) -> list[AccountInfo]:
        return list((await self.client_info()).accounts)

    async def transactions(
        self, account: AccountInfo, frm: datetime, to: datetime
    ) -> list[NormalizedTransaction]:
        """Every transaction in [frm, to], however long the range."""
        if frm > to:
            raise ValueError("frm must not be after to")
        rows: list[NormalizedTransaction] = []
        for window_start, window_end in _windows(frm, to):
            raw = await self._statement(account.external_id, window_start, window_end)
            rows.extend(normalize(item, account) for item in raw)
        return _dedupe(rows)

    async def _statement(self, account_id: str, frm: datetime, to: datetime) -> list[dict]:
        path = f"/personal/statement/{account_id}/{int(frm.timestamp())}/{int(to.timestamp())}"
        for attempt in range(3):
            async with self._pacer:
                try:
                    payload = await self._get(path)
                except RateLimited:
                    if attempt == 2:
                        raise
                    backoff = CALL_INTERVAL * (attempt + 1)
                    log.warning("monobank 429, backing off %.0fs", backoff)
                    await asyncio.sleep(backoff)
                    continue
            assert isinstance(payload, list)
            return payload
        raise RateLimited("exhausted retries")


def _card_mask(account: dict) -> str:
    pans = account.get("maskedPan") or []
    return pans[0] if pans else ""


def _windows(frm: datetime, to: datetime) -> list[tuple[datetime, datetime]]:
    """Split a range into <=31-day windows, oldest first."""
    windows: list[tuple[datetime, datetime]] = []
    cursor = frm
    while cursor < to:
        end = min(cursor + MAX_WINDOW, to)
        windows.append((cursor, end))
        cursor = end
    return windows or [(frm, to)]


def _dedupe(rows: list[NormalizedTransaction]) -> list[NormalizedTransaction]:
    """Window boundaries can return the same row twice; external_id decides.

    Dedup also happens at the storage layer — this is not a substitute for it,
    only an early one so a caller inspecting connector output sees the truth.
    """
    seen: set[str] = set()
    unique: list[NormalizedTransaction] = []
    for row in rows:
        if row.external_id in seen:
            continue
        seen.add(row.external_id)
        unique.append(row)
    return unique


def normalize(item: dict, account: AccountInfo) -> NormalizedTransaction:
    """Map one monobank statement item into the common shape.

    Two things the field names invite you to get wrong:

    * `currencyCode` describes `operationAmount`, not `amount`. `amount` is
      always in the account's currency, so that is the currency stored.
    * There is no transfer detection here. PrivatBank wording like "на свою
      картку" never appears in monobank text; the resolver types transfers from
      `counter_name`, fixed bank phrasings and the sign. Flow here is sign only.

    The description becomes both raw fields because the old vocabulary keyed
    on a category column monobank does not supply.
    """
    description = (item.get("description") or "").strip()
    amount = item["amount"]
    return NormalizedTransaction(
        external_id=item["id"],
        occurred_at=datetime.fromtimestamp(item["time"], tz=UTC),
        amount=amount,
        currency_code=account.currency_code,
        flow=Flow.INCOME if amount > 0 else Flow.EXPENSE,
        raw_category=description,
        raw_merchant=description,
        source=Source.MONOBANK,
        mcc=item.get("mcc"),
        balance_after=item.get("balance"),
        operation_amount=item.get("operationAmount"),
        original_mcc=item.get("originalMcc"),
        operation_currency=item.get("currencyCode"),
        commission=item.get("commissionRate", 0),
        cashback=item.get("cashbackAmount", 0),
        hold=bool(item.get("hold", False)),
        receipt_id=item.get("receiptId"),
        counter_name=item.get("counterName"),
    )
