"""monobank connector tests. No network: every response is a fixture."""
from datetime import UTC, datetime, timedelta
from itertools import pairwise

import httpx
import pytest
import respx

from app.connectors.base import Flow, Source
from app.connectors.monobank import (
    API_BASE,
    InvalidToken,
    MonobankConnector,
    MonobankError,
    _Pacer,
    _windows,
    normalize,
)

CLIENT_INFO = {
    "clientId": "abc",
    "name": "Тарас Шевченко",
    "accounts": [
        {
            "id": "acc-uah",
            "balance": 2231075,
            "creditLimit": 0,
            "type": "black",
            "currencyCode": 980,
            "maskedPan": ["444111****4444"],
            "iban": "UA00",
        }
    ],
}

# Field shapes copied from monobank's documented statement item.
STATEMENT = [
    {
        "id": "tx-1",
        "time": 1_750_000_000,
        "description": "Сільпо",
        "mcc": 5411,
        "amount": -24500,
        "operationAmount": -24500,
        "currencyCode": 980,
        "balance": 2231075,
        "hold": False,
    },
    {
        "id": "tx-2",
        "time": 1_750_003_000,
        "description": "Зарплата",
        "mcc": 4829,
        "amount": 2183154,
        "operationAmount": 2183154,
        "currencyCode": 980,
        "balance": 4414229,
        "hold": False,
    },
    {
        "id": "tx-3",
        "time": 1_750_004_000,
        "description": "На свою картку 4441 11** **** 4444",
        "mcc": 4829,
        "amount": -500000,
        "operationAmount": -500000,
        "currencyCode": 980,
        "balance": 3914229,
        "hold": False,
    },
]


@pytest.fixture
def account():
    return type(
        "A",
        (),
        {"external_id": "acc-uah", "currency_code": 980, "name": "black",
         "card_mask": "", "balance": 0},
    )()


def test_windows_splits_a_long_range_into_31_day_chunks():
    frm = datetime(2026, 1, 1, tzinfo=UTC)
    to = datetime(2026, 4, 1, tzinfo=UTC)
    windows = _windows(frm, to)
    assert len(windows) == 3
    assert windows[0][0] == frm
    assert windows[-1][1] == to
    # No gaps: each window starts where the previous ended.
    for (_, end), (start, _) in pairwise(windows):
        assert end == start
    assert all(end - start <= timedelta(days=31) for start, end in windows)


def test_windows_keeps_a_short_range_whole():
    frm = datetime(2026, 1, 1, tzinfo=UTC)
    to = datetime(2026, 1, 10, tzinfo=UTC)
    assert _windows(frm, to) == [(frm, to)]


def test_normalize_maps_a_purchase():
    row = normalize(STATEMENT[0], account=_Account())
    assert row.external_id == "tx-1"
    assert row.amount == -24500
    assert row.flow is Flow.EXPENSE
    assert row.source is Source.MONOBANK
    assert row.mcc == 5411
    # description becomes both raw fields — monobank has no category text.
    assert row.raw_category == row.raw_merchant == "Сільпо"


def test_normalize_keeps_the_networks_own_code_when_the_bank_rewrote_it():
    """Board #56. monobank recodes some rows and the original describes the
    real shop — in the corpus, `mcc` 7829 against `originalMcc` 4899 for one
    subscription. Dropping it here means the analysis side can never see the
    difference the iOS app now stores.
    """
    item = dict(STATEMENT[0], mcc=7829, originalMcc=4899, currencyCode=978)
    row = normalize(item, account=_Account())
    assert row.mcc == 7829
    assert row.original_mcc == 4899


def test_normalize_leaves_the_original_code_absent_rather_than_copying_mcc():
    """96 of the corpus's 111 rows have the two codes equal, so a copy would
    look right nearly everywhere and be wrong exactly where it matters."""
    assert "originalMcc" not in STATEMENT[0], "precondition for this test"
    assert normalize(STATEMENT[0], account=_Account()).original_mcc is None


def test_normalize_reads_flow_from_the_sign():
    assert normalize(STATEMENT[1], account=_Account()).flow is Flow.INCOME


def test_normalize_flow_is_sign_only():
    """Own-card wording is PrivatBank's; monobank rows are typed by the resolver, not here."""
    assert normalize(STATEMENT[2], account=_Account()).flow is Flow.EXPENSE


def test_normalize_amount_is_in_the_account_currency_not_the_operations():
    """A €4.99 Netflix charge: amount is UAH, operationAmount/currencyCode are EUR."""
    item = dict(STATEMENT[0], id="tx-nf", description="Netflix",
                amount=-43120, operationAmount=-999, currencyCode=978)
    row = normalize(item, account=_Account())
    assert row.amount == -43120
    assert row.currency_code == 980          # the account's, never 978
    assert row.operation_amount == -999
    assert row.operation_currency == 978


def test_normalize_keeps_the_fields_the_resolver_needs():
    item = dict(STATEMENT[0], id="tx-k", commissionRate=240, cashbackAmount=101,
                hold=True, receiptId="6H2T-7CC6", counterName="Shevchenko Taras")
    row = normalize(item, account=_Account())
    assert (row.commission, row.cashback, row.hold) == (240, 101, True)
    assert row.receipt_id == "6H2T-7CC6"
    assert row.counter_name == "Shevchenko Taras"


def test_normalize_defaults_when_monobank_omits_fields():
    """monobank omits keys rather than nulling them."""
    row = normalize(STATEMENT[0], account=_Account())
    assert (row.commission, row.cashback, row.hold) == (0, 0, False)
    assert row.receipt_id is None and row.counter_name is None


@respx.mock
async def test_accounts_parses_client_info():
    respx.get(f"{API_BASE}/personal/client-info").mock(
        return_value=httpx.Response(200, json=CLIENT_INFO)
    )
    async with httpx.AsyncClient(base_url=API_BASE) as http:
        connector = MonobankConnector("token", client=http)
        accounts = await connector.accounts()
    assert len(accounts) == 1
    assert accounts[0].external_id == "acc-uah"
    assert accounts[0].card_mask == "444111****4444"


@respx.mock
async def test_client_info_carries_owner_name_and_jars():
    payload = dict(CLIENT_INFO, jars=[{"id": "j1", "title": "Пиріжок", "balance": 100}])
    respx.get(f"{API_BASE}/personal/client-info").mock(
        return_value=httpx.Response(200, json=payload))
    async with httpx.AsyncClient(base_url=API_BASE) as http:
        info = await MonobankConnector("tok", client=http).client_info()
    assert info.owner_name == "Тарас Шевченко"
    assert info.jars == ("Пиріжок",)
    assert info.accounts[0].external_id == "acc-uah"


@respx.mock
async def test_403_is_an_invalid_token_not_a_generic_error():
    """The only fix is a new token, so the caller needs to tell them apart."""
    respx.get(f"{API_BASE}/personal/client-info").mock(return_value=httpx.Response(403))
    async with httpx.AsyncClient(base_url=API_BASE) as http:
        with pytest.raises(InvalidToken):
            await MonobankConnector("bad", client=http).accounts()


@respx.mock
async def test_a_transport_failure_is_a_monobank_error_not_an_unhandled_500():
    """A timeout or DNS failure must not escape _get() as a raw httpx exception —
    callers (main.py) catch MonobankError and turn it into a clean response."""
    respx.get(f"{API_BASE}/personal/client-info").mock(side_effect=httpx.ConnectError("boom"))
    async with httpx.AsyncClient(base_url=API_BASE) as http:
        with pytest.raises(MonobankError):
            await MonobankConnector("token", client=http).accounts()


@respx.mock
async def test_transactions_dedupes_rows_repeated_across_windows():
    """Window boundaries can hand back the same row twice."""
    respx.get(url__regex=rf"{API_BASE}/personal/statement/.*").mock(
        return_value=httpx.Response(200, json=STATEMENT)
    )
    frm = datetime(2026, 1, 1, tzinfo=UTC)
    to = datetime(2026, 3, 1, tzinfo=UTC)  # two windows, same fixture both times
    async with httpx.AsyncClient(base_url=API_BASE) as http:
        connector = MonobankConnector(
            "token", client=http, pacer=_Pacer(interval=0.0), info_pacer=_Pacer(interval=0.0)
        )
        rows = await connector.transactions(_Account(), frm, to)
    assert [r.external_id for r in rows] == ["tx-1", "tx-2", "tx-3"]


async def test_pacer_serializes_and_spaces_requests():
    """The rate limit is the connector's problem; callers never see it."""
    import asyncio
    import time

    pacer = _Pacer(interval=0.2)
    starts: list[float] = []

    async def call():
        async with pacer:
            starts.append(time.monotonic())

    await asyncio.gather(call(), call(), call())
    starts.sort()
    assert starts[1] - starts[0] >= 0.19
    assert starts[2] - starts[1] >= 0.19


class _Account:
    external_id = "acc-uah"
    currency_code = 980
    name = "black"
    card_mask = ""
    balance = 0
