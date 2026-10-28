# tests/test_corpus.py
"""The spec's success criteria, measured against the frozen 12-month corpus.

The fixture is a synthetic 12-month statement in monobank's own JSON shape:
every id, time, amount and counterparty is invented. The owner appears as
"Owner Name"; that is what `owner_name` is set to here.
"""
import json
from pathlib import Path

import pytest

from app.connectors.base import Flow
from app.connectors.monobank import normalize
from app.core import vocabulary
from app.core.resolver import Decider, resolve
from app.core.rules import RuleStore
from app.core.text import normalize_key
from app.core.transfers import TransferKind

FIXTURE = Path(__file__).parent / "fixtures" / "monobank_corpus.jsonl"
OWNER = "Owner Name"


class _Account:
    external_id = "acc"
    currency_code = 980
    name = "black"
    card_mask = ""
    balance = 0
    credit_limit = 0


@pytest.fixture(scope="module")
def resolved():
    store = RuleStore()
    vocabulary.seed(store)
    rows = [
        normalize(json.loads(line), account=_Account())
        for line in FIXTURE.read_text().splitlines()
        if line
    ]
    assert len(rows) == 71
    return [(row, resolve(row, store, OWNER)) for row in rows]


def test_at_least_95_percent_resolve_without_an_llm(resolved):
    asked = [row for row, r in resolved if r.decided_by is Decider.ASK]
    share = 1 - len(asked) / len(resolved)
    assert share >= 0.95, f"{share:.1%} resolved; asked: {[r.raw_merchant for r in asked]}"


def test_only_rozetka_and_the_generic_shop_are_asked(resolved):
    asked = sorted(row.raw_merchant for row, r in resolved if r.decided_by is Decider.ASK)
    assert asked == ["Rozetka", "Rozetka", "SHOP"]


def test_rozetka_is_asked_as_ambiguous_not_unknown(resolved):
    reasons = {r.ask_reason for row, r in resolved if row.raw_merchant == "Rozetka"}
    assert reasons == {"ambiguous"}


def test_no_personal_name_becomes_a_rule_key(resolved):
    """A name-bearing row must be typed as a transfer by structure alone.

    That is the only thing standing between a person's name and (a) an LLM
    prompt, once ASK rows get sent out for classification, and (b) a shared
    rule key, once a category gets remembered against `r.key`. If either
    happens, that person's name leaks to a third party or sits keyed in
    everyone's rule table forever. So this test pins both halves: every
    name-bearing row must resolve as TRANSFER (never ASK), and — as a
    belt-and-braces check on any row that isn't a transfer for other
    reasons — no key may contain a folded name marker. The markers are
    computed via `normalize_key` itself, not hardcoded, so this survives
    changes to the lookalike-folding table (a prior version of this test
    hardcoded the folded Cyrillic spelling of "особа" and was defeated by
    that exact folding, making it vacuous).
    """
    name_bearing = [
        (row, r)
        for row, r in resolved
        if "Особа" in row.raw_merchant or "Owner" in row.raw_merchant
    ]
    assert name_bearing, "fixture must contain at least one name-bearing row"
    for row, r in name_bearing:
        assert r.decided_by is Decider.TRANSFER, row.raw_merchant

    name_markers = {normalize_key("особа"), normalize_key("owner")}
    for row, r in resolved:
        if r.decided_by is not Decider.TRANSFER:
            assert not any(marker in r.key for marker in name_markers), row.raw_merchant


def test_every_incoming_from_a_person_is_a_transfer(resolved):
    for row, r in resolved:
        if row.raw_merchant.startswith("Від:"):
            assert r.flow is Flow.TRANSFER, row.raw_merchant


def test_owner_top_ups_are_own_card_and_the_relative_is_a_person(resolved):
    kinds = {
        row.raw_merchant: r.transfer_kind
        for row, r in resolved
        if row.raw_merchant.startswith("Від:")
    }
    assert kinds["Від: Owner Name"] is TransferKind.OWN_CARD
    assert kinds["Від: Родич Особа"] is TransferKind.PERSON


def test_interest_resolves_every_month_of_the_year(resolved):
    interest = [r for row, r in resolved if row.raw_merchant.startswith("Списання відсотків")]
    assert len(interest) == 12
    assert all(
        r.category == vocabulary.INTEREST and r.decided_by is Decider.PATTERN for r in interest
    )


def test_migration_pair_is_excluded_from_everything(resolved):
    legs = [r for row, r in resolved if "міграції" in row.raw_merchant]
    assert len(legs) == 2
    assert all(r.transfer_kind is TransferKind.MIGRATION for r in legs)


def test_every_outgoing_4829_is_a_transfer(resolved):
    for row, r in resolved:
        if row.mcc == 4829 and row.amount < 0:
            assert r.flow is Flow.TRANSFER, row.raw_merchant


def test_interest_is_the_largest_category(resolved):
    """The number the app exists to show. If this flips, look hard at the rules."""
    totals: dict[str, int] = {}
    for row, r in resolved:
        if r.category and r.flow is Flow.EXPENSE:
            totals[r.category] = totals.get(r.category, 0) - row.amount
    assert max(totals, key=totals.get) == vocabulary.INTEREST
    others = sum(v for k, v in totals.items() if k != vocabulary.INTEREST)
    assert totals[vocabulary.INTEREST] > others * 0.9
