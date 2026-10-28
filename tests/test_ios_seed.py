"""The iOS seed is the owner's spending shape with every person removed.

Two halves. The first runs always and guards the committed reference.json and
demo.json: shape,
row count, and — the one that matters — that no merchant matches any of the
builder's own scrub patterns, imported so the test and the scrubber cannot
drift apart. The second needs the gitignored xlsx and proves the builder is
deterministic and loses no money in translation.
"""

import importlib.util
import json
import re
from collections import defaultdict
from pathlib import Path

import pytest

from app.core.products import ALL_GROUPS, GROUPS, OTHER

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "ios" / "MonitorFinance" / "Resources"
REFERENCE = RESOURCES / "reference.json"
DEMO = RESOURCES / "demo.json"
XLSX = ROOT / "data" / "finance-monitor.local.xlsx"


def _builder():
    spec = importlib.util.spec_from_file_location(
        "build_ios_seed", ROOT / "scripts" / "build_ios_seed.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _merged(reference_path: Path, demo_path: Path) -> dict:
    """The same dict shape the single-file seed.json used to have: banks
    taking their accounts from demo["accounts"], everything else concatenated
    from the two halves."""
    reference = json.loads(reference_path.read_text(encoding="utf-8"))
    demo = json.loads(demo_path.read_text(encoding="utf-8"))
    banks = [
        {**b, "accounts": demo["accounts"].get(b["id"], [])} for b in reference["banks"]
    ]
    return {
        "transactions": demo["transactions"],
        "banks": banks,
        "categories": reference["categories"],
        "rules": demo["rules"],
        "receipts": demo["receipts"],
        "productGroups": reference["productGroups"],
    }


@pytest.fixture(scope="module")
def seed():
    return _merged(REFERENCE, DEMO)


def test_seed_has_every_collection(seed):
    assert set(seed) == {
        "transactions", "banks", "categories", "rules", "receipts", "productGroups",
    }
    assert len(seed["transactions"]) == 62
    assert {b["id"] for b in seed["banks"]} == {"monobank", "privatbank"}
    assert len(seed["banks"][0]["accounts"]) == 4


def test_the_taxonomy_is_internally_consistent():
    """A keyword owned by two groups makes the matcher's answer depend on
    dict order, which is a coin flip wearing a suit."""
    seen: dict[str, str] = {}
    for group, keywords in GROUPS.items():
        for kw in keywords:
            assert kw == kw.strip().lower(), f"{kw!r} is not normalised"
            assert kw not in seen, f"{kw!r} claimed by both {seen[kw]!r} and {group!r}"
            seen[kw] = group
    assert all(GROUPS[g] for g in GROUPS), "a group with no keywords is unreachable"
    assert OTHER not in GROUPS, "OTHER is the fallback, never a keyword-bearing group"
    assert ALL_GROUPS[-1] == OTHER
    assert len(ALL_GROUPS) == 21
    # масло names both butter and oil in Ukrainian, and the owner's own
    # taxonomy puts it in both "Молочні продукти" and "Харчові жири" — a bare
    # "масло" keyword would make the matcher guess between them. Only its
    # qualified forms may appear, and they must still land in different
    # groups, or "масло" has quietly been dropped rather than disambiguated.
    assert "масло" not in seen, "масло must never be a bare keyword"
    assert seen["масло вершкове"] != seen["масло соняшникове"]
    assert seen["масло соняшникове"] == seen["масло оливкове"]


def test_the_seed_ships_the_taxonomy(seed):
    groups = seed["productGroups"]
    assert [g["name"] for g in groups] == list(ALL_GROUPS)
    # OTHER ships with no keywords — nothing may match INTO it, only fall to it.
    assert groups[-1]["keywords"] == []
    assert any(len(g["keywords"]) > 5 for g in groups), "keywords must ship, not just names"


def test_no_merchant_identifies_a_person(seed):
    builder = _builder()
    patterns = builder.PERSONAL_PATTERNS
    canonical = builder.canonical

    def flagged(text):
        # Same normalisation the scrubber applies: a pattern written against
        # a Cyrillic-only character class must also see the canonical form,
        # so an intra-word Latin/Cyrillic homoglyph cannot slip through.
        return any(p.search(text) or p.search(canonical(text)) for p in patterns)

    offenders = [t["merchant"] for t in seed["transactions"] if flagged(t["merchant"])]
    assert offenders == []
    rule_offenders = [r["merchantKey"] for r in seed["rules"] if flagged(r["merchantKey"])]
    assert rule_offenders == []


def test_no_bare_card_merchant_names_an_unowned_card(seed):
    # A merchant that is nothing but "*NNNN" identifies a specific card; it
    # must never survive the scrub unless it is one of the owner's own.
    seeded = {suffix for _id, suffix, *_ in _builder().OWN_CARDS}
    card_re = re.compile(r"\*\d{4}")
    for t in seed["transactions"]:
        for token in card_re.findall(t["merchant"]):
            assert token in seeded, t["merchant"]


def test_every_transaction_is_well_formed(seed):
    kinds = {"expense", "income", "transfer"}
    resolutions = {"rule", "pattern", "transfer", "user", "pending", "skipped"}
    for t in seed["transactions"]:
        assert t["kind"] in kinds
        # Swift decodes `category` as a non-optional String: one null and
        # `try?` drops the whole demo, leaving the app (and its tests) empty.
        assert isinstance(t["category"], str), t["merchant"]
        assert t["resolution"] in resolutions
        assert isinstance(t["amount"], int) and t["amount"] != 0
        if t["kind"] in ("expense", "income"):
            assert (t["amount"] < 0) == (t["kind"] == "expense")
        assert t["cardSuffix"].startswith("*") and len(t["cardSuffix"]) == 5
        assert t["date"].endswith(("+02:00", "+03:00"))
        if t["resolution"] == "pending":
            assert len(t["suggestions"]) == 3
        else:
            assert t["suggestions"] == []


def test_transfer_sign_reflects_direction(seed):
    # Transfers go both ways, so kind alone cannot carry the sign: a
    # transfer is positive exactly when it is money coming in from one of
    # the owner's own cards.
    transfers = [t for t in seed["transactions"] if t["kind"] == "transfer"]
    assert any(t["amount"] > 0 for t in transfers)
    assert any(t["amount"] < 0 for t in transfers)
    for t in transfers:
        assert (t["amount"] > 0) == t["merchant"].startswith("Переказ зі своєї картки")


def test_every_card_suffix_is_a_seeded_account(seed):
    seeded = {suffix for _id, suffix, *_ in _builder().OWN_CARDS}
    assert {t["cardSuffix"] for t in seed["transactions"]} <= seeded


def test_the_seed_leaves_a_realistic_number_of_merchants_unresolved(seed):
    pending = [t for t in seed["transactions"] if t["resolution"] == "pending"]
    assert 0 < len(pending) <= len(seed["transactions"]) // 2, len(pending)


def test_seed_ships_the_sample_receipts(seed):
    receipts = seed["receipts"]
    assert len(receipts) == 6
    # Varying item counts, so the simulator's sample picker shows visibly
    # different receipts rather than several of the same shape.
    assert sorted(len(r["items"]) for r in receipts) == [1, 1, 1, 2, 3, 8]
    assert {r["documentNumber"] for r in receipts} == {
        "1000000001", "1000000002", "1000000003",
        "1000000004", "1000000005", "1000000006",
    }
    for r in receipts:
        assert r["fiscalSum"] > 0
        # These two lines are tautologies: the builder derives fiscalSum from
        # the item sums, and each item's sum from qty * price, so both sides
        # of each assertion are the same computation and can never disagree
        # from any change to the builder. They still guard against a
        # hand-edited demo.json (forbidden, but not impossible to produce),
        # where the two sides could be edited independently.
        assert sum(i["sum"] for i in r["items"]) == r["fiscalSum"]
        for i in r["items"]:
            assert i["sum"] == round(i["qty"] * i["price"])
    # The totals as LITERALS. The two assertions above are tautologies — the
    # builder derives fiscalSum from the item sums and each item sum from
    # qty * price, so both sides move together and neither can ever fail. These
    # do not: a typo in any price changes its receipt's total and fails here.
    assert {r["documentNumber"]: r["fiscalSum"] for r in receipts} == {
        "1000000001": 792_59,   # 8-line grocery run
        "1000000002": 52_99,    # 2-line corner shop
        "1000000003": 287_01,   # cafe — the odd kopeck is deliberate
        "1000000004": 923_80,   # fuel sample — 12,40 л × 74,50 ₴/л
        "1000000005": 800_00,   # fuel, pre-attached — 10,00 л × 80,00 ₴/л
        "1000000006": 145_80,   # car wash, pre-attached in a DIFFERENT month
    }


def test_the_seed_pre_attaches_exactly_two_receipts_in_two_months(seed):
    """Заправки must have something to show on first launch, and that
    something must also be splittable — a receipt whose total differs from the
    charge is exactly the case the split refuses, so shipping the demo in that
    state would make the one reachable example the broken one.

    TWO of them, in two different Kyiv months, since the whole-branch review:
    with one confirmable split in the whole dataset, a drill filtered to one
    period and a drill filtered to nothing at all returned the identical
    single row, so no test could tell a working period filter from a missing
    one."""
    attached = [t for t in seed["transactions"] if t["receiptId"]]
    assert len(attached) == 2
    for tx in attached:
        receipt = next(r for r in seed["receipts"] if r["id"] == tx["receiptId"])
        # Exactly the charge — the invariant that makes each one confirmable.
        assert receipt["fiscalSum"] == abs(tx["amount"])
        assert tx["category"] == "Автомобіль"
        assert len(receipt["items"]) == 1
    assert len({t["date"][:7] for t in attached}) == 2, "the two must sit in different months"

    # …and the two are DIFFERENT KINDS of purchase, which is what keeps the
    # fuel log a one-row fixture while both feed the same product group.
    by_month = {t["date"][:7]: t for t in attached}
    fuel_tx = by_month["2026-08"]
    wash_tx = by_month["2026-07"]
    fuel = next(r for r in seed["receipts"] if r["id"] == fuel_tx["receiptId"])
    wash = next(r for r in seed["receipts"] if r["id"] == wash_tx["receiptId"])
    assert fuel["items"][0]["qty"] > 1, "a fill-up, not a car wash"
    assert wash["items"][0]["qty"] == 1
    # `FuelGrade.parse` (Swift) reads whole tokens; «Мийка автомобіля» spells
    # none of the eight grades, so `Derived.fillUps` never sees this one.
    assert not any(g in wash["items"][0]["name"].casefold()
                   for g in ("а-92", "а-95", "а-98", "а-100", "дп", "дт", "газ", "lpg"))


def test_the_cafe_sample_matches_no_real_purchase(seed):
    """D5. Task 7's mismatch test attaches this sample to whatever sits at the
    top of the queue, so its sum must collide with nothing — otherwise the test
    passes or fails on queue order. 287,00 collides; 287,01 does not."""
    cafe = next(r for r in seed["receipts"] if len(r["items"]) == 3)
    amounts = {abs(t["amount"]) for t in seed["transactions"]}
    assert cafe["fiscalSum"] not in amounts


def test_sample_receipts_invent_their_sellers(seed):
    """Real merchant names never leave the scrubbed corpus (see the privacy
    rules); the samples are written content, not harvested data."""
    merchants = {t["merchant"].casefold() for t in seed["transactions"]}
    for r in seed["receipts"]:
        assert r["sellerName"].casefold() not in merchants


def test_rule_keys_are_normalised_the_way_the_app_normalises_them(seed):
    """`MerchantKey.normalize` (Swift) lowercases and trims before it compares,
    so a rule stored with the sheet's own casing can never match a merchant —
    which is what shipped: 0 of the queue's rows could reach any seeded rule."""
    rule_key = _builder().rule_key
    for r in seed["rules"]:
        assert r["merchantKey"] == rule_key(r["merchantKey"]), r["merchantKey"]
    # …and the keys are still distinct after folding, or one rule silently
    # shadows another.
    keys = [r["merchantKey"] for r in seed["rules"]]
    assert len(set(keys)) == len(keys)
    # A positive partner for the loop, which would pass just as happily against
    # an identity function: `rule_key` really does fold, in the same three ways
    # Swift does.
    assert rule_key("  FooPay ") == "foopay"            # trim + lowercase
    # И + COMBINING BREVE: the decomposed "Й" a terminal can emit. NFC
    # folds it to the precomposed letter, a different string to `==`.
    assert rule_key("Й") == "й"
    # …and the shipped keys really are folded, without this test spelling one
    # of the owner's own merchants to prove it.
    assert any(k != k.upper() for k in keys), "no shipped key is in a folded form"


# Merchants already named in app source before this guard existed, each mapped
# to the file that may name it. Scoped to a PATH, not just to a string: a bare
# string exemption would let `sellerName: "<exempt merchant>"` into a new
# #Preview — which is the exact leak this guard was written for. Nothing is
# listed that is not actually present; `test_the_exemptions_have_not_rotted`
# fails if one stops being used, so the list cannot quietly become a set of
# standing permissions for names nobody writes any more.
PRE_EXISTING_MERCHANT_MENTIONS = {
    # named in comments about ambiguous merchant rules, and in the doc comment
    # of the predicate that decides which merchant families are generic — a
    # comment explaining «NovaPay» that may not write «NovaPay» explains
    # nothing.
    "NovaPay": {"Store/AppStore+Queue.swift", "Store/GenericMerchant.swift"},
    "На картку": {"Store/AppStore+Queue.swift", "Store/GenericMerchant.swift"},
    "Платіж": {"Store/GenericMerchant.swift"},
    "Rozetka": {"Store/AppStore+Queue.swift"},
    # a CATEGORY that also happens to be a merchant. It is a generic Ukrainian
    # word shipped in reference.json, not a name off anyone's statement, so the
    # tests that pin the income picker's own vocabulary have to be able to
    # spell it.
    #
    # Board #94 moved the load-bearing copy: `BudgetMath.earnedCategories` was
    # a hardcoded set and is now derived from `Category.kind`. What is left in
    # `BudgetMath` is `canonicalIncomeOrder`, which decides the ORDER the
    # picker offers a vocabulary in and never membership; the answer for a
    # category stored before the field existed lives in
    # `CategoryKind.legacy(for:)` in `Models.swift`.
    "Стипендія": {
        "Budget/BudgetMath.swift",
        "Models/Models.swift",
        "MonitorFinanceTests/IncomeCategoryTests.swift",
        "MonitorFinanceUITests/QueueFlowTests.swift",
    },
}


def _app_sources():
    """Every Swift file in the project, tests included.

    Scoped to the app target alone until 2026-08-24, which let eight real
    strings — shop names and card suffixes from the owner's own statement —
    sit in test fixtures the guard never looked at. A fixture is source like
    any other, and it is where an invented name costs nothing: every one of
    the eight was pure fixture data, so all eight were replaced rather than
    exempted. The exemptions below stay app-only, and are earned: each names
    a real merchant inside a COMMENT explaining that merchant's behaviour.
    """
    return sorted(
        p
        for d in ("MonitorFinance", "MonitorFinanceTests", "MonitorFinanceUITests")
        for p in (ROOT / "ios" / d).rglob("*.swift")
    )


def test_the_exemptions_have_not_rotted(seed):
    """Every exemption must still be earned. An exemption for a name no file
    contains is a standing permission nobody is watching."""
    merchants = {t["merchant"] for t in seed["transactions"]}
    for name, allowed in PRE_EXISTING_MERCHANT_MENTIONS.items():
        assert name in merchants, f"{name!r} is exempted but is not a seed merchant"
        if not allowed:
            continue
        present = {
            suffix
            for suffix in allowed
            for p in _app_sources()
            if str(p).endswith(suffix) and name in p.read_text()
        }
        stale = allowed - present
        assert not stale, f"{name!r}: exemption lists {stale}, which no longer name it"


def test_no_swift_source_names_a_merchant_from_the_seed(seed):
    """The standing privacy rule: a merchant from the owner's own statement
    never gets written into source, and a sample receipt's seller is invented.
    A `#Preview` naming a real shop is how this was breached once already.

    Blind spot: this scans Swift source TEXT. A merchant string reaching a
    Swift file only base64-encoded (e.g. inside a generated xlsx fixture's
    embedded base64 constant) does not appear as that string and is invisible
    to this guard — the generator that produces such fixtures must itself
    stay free of real merchant text, since nothing downstream will catch it."""
    app_sources = _app_sources()
    assert app_sources, "no Swift sources found — the guard would pass vacuously"
    merchants = {t["merchant"] for t in seed["transactions"]}
    assert len(merchants) > 15, "the merchant set the guard searches for is suspiciously small"

    def offenders_in(relpath, text):
        out = []
        for m in merchants:
            if m not in text:
                continue
            allowed = PRE_EXISTING_MERCHANT_MENTIONS.get(m)
            # A missing key means "never allowed". An empty set means "allowed
            # anywhere" (the degenerate punctuation merchant). Otherwise the
            # exemption is only good in the files it names — so the same string
            # appearing in a NEW file is still a finding.
            if allowed is None or (allowed and not any(relpath.endswith(a) for a in allowed)):
                out.append((relpath, m))
        return out

    found = []
    for path in app_sources:
        found += offenders_in(path.relative_to(ROOT).as_posix(), path.read_text(encoding="utf-8"))
    assert found == [], f"seed merchants named in app source: {found}"

    # Two positive partners, because the assertion above would pass just as
    # happily for a search that can never match anything.
    leaked = next(m for m in sorted(merchants) if m not in PRE_EXISTING_MERCHANT_MENTIONS)
    assert offenders_in("fake.swift", f'sellerName: "{leaked}",') == [("fake.swift", leaked)]
    # …and an EXEMPT name in a file its exemption does not cover is still caught.
    # This is the leak shape a bare string exemption would have let through.
    scoped = next(m for m, a in PRE_EXISTING_MERCHANT_MENTIONS.items() if a)
    assert offenders_in("Receipts/ReceiptItemsView.swift",
                        f'sellerName: "{scoped}",') == [("Receipts/ReceiptItemsView.swift", scoped)]


@pytest.mark.skipif(not XLSX.exists(), reason="local xlsx absent")
def test_rebuild_reproduces_the_committed_seed(tmp_path):
    out = tmp_path / "reference.json"
    _builder().build(XLSX, out)
    assert (tmp_path / "reference.json").read_bytes() == REFERENCE.read_bytes()
    assert (tmp_path / "demo.json").read_bytes() == DEMO.read_bytes()


@pytest.mark.skipif(not XLSX.exists(), reason="local xlsx absent")
def test_monthly_sums_match_the_sheet(seed):
    import openpyxl

    ws = openpyxl.load_workbook(XLSX, data_only=True)["data"]
    # Imported, not restated: a private copy of this map would let the test
    # keep agreeing with itself after the builder's own map changed.
    kinds = _builder().KIND
    sheet = defaultdict(int)
    for row in ws.iter_rows(min_row=2, values_only=True):
        if row[0] is None:
            continue
        kind = kinds[row[2]]
        sheet[(row[0].strftime("%Y-%m"), kind)] += round(float(row[5]) * 100)
    ours = defaultdict(int)
    for t in seed["transactions"]:
        ours[(t["date"][:7], t["kind"])] += abs(t["amount"])
    assert dict(ours) == dict(sheet)


MAPPER_CORPUS = "tests/fixtures/monobank_corpus.jsonl"
MAPPER_FIXTURE = "ios/MonitorFinanceTests/Generated/MonobankMapperFixture.swift"


def _mapper_corpus_rows():
    rows = [
        json.loads(line)
        for line in (ROOT / MAPPER_CORPUS).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert len(rows) > 50, f"the corpus holds {len(rows)} rows — the guards below would be thin"
    return rows


def test_the_generated_mapper_fixture_carries_no_corpus_text_at_all():
    """The corpus stands in for a real statement (a capture would be one). The
    committed Swift must not quote a word of it.

    **An allowlist, board #82.** This used to name `description` and
    `counterName` — the only free text the corpus happens to hold today, so it
    reported clean and always would. monobank's statement API also returns
    `comment`, `counterIban` and `counterEdrpou`, each of which identifies a
    person, and a recapture including any of them would have passed this in
    silence. Naming what may be carried instead means a new field fails the day
    it appears rather than the day somebody notices.

    Same class as `test_the_generated_check_fixture_is_byte_equal_to_its_source_json`:
    that exists because a guard watched the wrong surface and a real fiscal
    lookup key stayed committed.
    """
    from scripts.build_ios_test_fixtures import CARRIED_VERBATIM

    fixture = ROOT / MAPPER_FIXTURE
    assert fixture.exists(), "run: uv run python scripts/build_ios_test_fixtures.py"
    swift = fixture.read_text(encoding="utf-8")

    leaked = []
    for row in _mapper_corpus_rows():
        for field, value in row.items():
            if field in CARRIED_VERBATIM or not isinstance(value, str):
                continue
            value = value.strip()
            # Short tokens collide with ordinary Swift text — «АТБ» would match
            # inside a comment. Every real name in the corpus is longer.
            if len(value) >= 5 and value in swift:
                leaked.append(field)
    assert leaked == [], (
        f"corpus text reached the committed fixture through {sorted(set(leaked))} — "
        "scrub it in scripts/build_ios_test_fixtures.py, or argue it into CARRIED_VERBATIM"
    )


def test_the_leak_guard_above_can_actually_fire():
    """Prove the detector before trusting its clean run.

    The guard reports clean, and reported clean in its old shape too — while
    being unable to see three of the five fields it was there to watch. So it
    is fed a corpus row whose text really is in the fixture, and must object.
    """
    from scripts.build_ios_test_fixtures import CARRIED_VERBATIM

    swift = (ROOT / MAPPER_FIXTURE).read_text(encoding="utf-8")
    planted = {"comment": "Продавець 0"}   # a real value the fixture does hold

    leaked = [
        field
        for field, value in planted.items()
        if field not in CARRIED_VERBATIM and len(value) >= 5 and value in swift
    ]
    assert leaked == ["comment"], (
        "the guard's own predicate does not fire on a value that IS in the fixture"
    )


def test_every_string_the_corpus_holds_is_decided_about():
    """A new field in a recaptured corpus must force a decision, not slip
    through.

    `scrub` replaces every string it is not told to carry, so a new personal
    field is already scrubbed by default — this is the second half: somebody
    has to look at it. A field appearing here that nobody has classified fails
    the run with its own name in the message.
    """
    from scripts.build_ios_test_fixtures import _REPLACEMENTS, CARRIED_VERBATIM

    seen = {
        field
        for row in _mapper_corpus_rows()
        for field, value in row.items()
        if isinstance(value, str)
    }
    known = CARRIED_VERBATIM | set(_REPLACEMENTS)
    assert seen <= known, (
        f"new string field(s) in the corpus: {sorted(seen - known)}. "
        "Give each one a stand-in in _REPLACEMENTS, or carry it verbatim and say why."
    )
    # The other direction, so a field that leaves the corpus does not quietly
    # leave a rule behind describing something that no longer exists.
    assert known - seen == set(), (
        f"classified but no longer in the corpus: {sorted(known - seen)}"
    )


def test_the_scrubber_replaces_a_field_nobody_thought_of():
    """The fallback is what makes the allowlist a defence rather than a report.

    A recapture carrying `comment` — free text a person typed about their own
    payment — must come out replaced without anybody editing this repo first.
    """
    from scripts.build_ios_test_fixtures import scrub

    row = {"id": "abc123", "description": "Справжня Крамниця",
           "comment": "за оренду, Іван", "amount": -100}
    out = scrub(row, 3)

    assert out["id"] == "abc123", "the allowlisted field is carried through"
    assert out["amount"] == -100, "non-strings are untouched"
    assert "Іван" not in out["comment"], "an unknown string field must still be scrubbed"
    assert "Крамниця" not in out["description"]


def test_the_generated_check_fixture_is_byte_equal_to_its_source_json():
    """`Generated/CheckFixture.swift` embeds base64 copies of
    `tests/fixtures/fiscal_check_*.json`'s `checkXml`. Those two drifted
    once already (2026-08-25): the JSON fixtures got scrubbed of their real
    `FN`/`NO`/`TS` lookup key, but the generated Swift file was not
    regenerated afterwards, so the committed source kept quoting a real
    receipt's real lookup key — anyone with the repo could have used it to
    re-fetch the unscrubbed original from the public tax-cabinet endpoint.
    A generated file that merely LOOKS regenerated (same shape, same line
    count) is not proof that it carries current data; only byte-equality
    with the source it claims to be generated from is.
    """
    import base64
    import re

    repo = Path(__file__).resolve().parent.parent
    fixtures = repo / "tests" / "fixtures"
    fixture = repo / "ios" / "MonitorFinanceTests" / "Generated" / "CheckFixture.swift"
    assert fixture.exists(), "run: uv run python scripts/build_ios_test_fixtures.py"
    swift = fixture.read_text(encoding="utf-8")

    def swift_base64(pattern: str) -> str:
        match = re.search(pattern, swift)
        assert match, f"pattern not found in CheckFixture.swift: {pattern!r}"
        return match.group(1)

    fuel = json.loads((fixtures / "fiscal_check_fuel.json").read_text(encoding="utf-8"))
    got = swift_base64(r'static let base64 = "(.*?)"')
    assert got == fuel["checkXml"], "the fuel-receipt fixture has drifted from its source JSON"

    for n in range(1, 8):
        source = json.loads((fixtures / f"fiscal_check_{n}.json").read_text(encoding="utf-8"))
        got = swift_base64(rf'{n}: CheckFixture\.Document\(\s*base64: "(.*?)"')
        assert got == source["checkXml"], f"receipt {n}'s fixture has drifted from its source JSON"
        # Decoded, not just string-equal: proves the check is not vacuous —
        # both sides really are the same document, not two same-length strings.
        assert base64.b64decode(got) == base64.b64decode(source["checkXml"])


def test_reference_carries_no_transactions_and_no_receipts():
    """reference.json ships to strangers. Nothing personal may be in it."""
    import json
    from pathlib import Path
    repo = Path(__file__).resolve().parent.parent
    ref = json.loads((repo / "ios/MonitorFinance/Resources/reference.json").read_text("utf-8"))
    assert set(ref) == {"banks", "categories", "productGroups"}
    assert all(b["accounts"] == [] for b in ref["banks"])


def test_the_seed_vocabulary_matches_what_board_6_decided():
    """«Це не витрата» now means own-card transfers alone, so the two answers it
    stopped covering must be one tap away in the picker — which means seeded,
    not conjured by `setBudget` for whoever happens to save a plan.

    «Зняття готівки» is asserted ABSENT rather than simply unused: it was
    renamed, not supplemented, and two near-identical cash categories one row
    apart is exactly the list the app's design tries not to grow.
    """
    import json
    from pathlib import Path
    repo = Path(__file__).resolve().parent.parent
    ref = json.loads((repo / "ios/MonitorFinance/Resources/reference.json").read_text("utf-8"))
    names = {c["name"] for c in ref["categories"]}
    assert "Готівка" in names
    assert "Заощадження" in names
    assert "Зняття готівки" not in names

    demo = json.loads((repo / "ios/MonitorFinance/Resources/demo.json").read_text("utf-8"))
    used = {t["category"] for t in demo["transactions"] if t["category"]}
    assert used <= names, f"the demo uses categories the picker cannot show: {used - names}"


def test_the_seed_ships_a_short_vocabulary_with_no_transfers_in_it():
    """Board #15. Forty names is what a person met on their first-ever pick;
    nineteen is what they meet now — fifteen things money is spent on plus the
    four income categories the budget counts.

    The transfer names are asserted ABSENT rather than merely unused: boards #6,
    #7 and #13 established that a transfer is not a category, and leaving one in
    the list puts "who you paid" back in a vocabulary that describes what you
    bought, one row above the answer that handles transfers properly.
    """
    import json
    from pathlib import Path
    repo = Path(__file__).resolve().parent.parent
    ref = json.loads((repo / "ios/MonitorFinance/Resources/reference.json").read_text("utf-8"))
    names = [c["name"] for c in ref["categories"]]
    assert len(names) == 19, names
    assert all(n for n in names), "a blank name would be a blank row in the picker"
    assert not [n for n in names if "ереказ" in n], names

    demo = json.loads((repo / "ios/MonitorFinance/Resources/demo.json").read_text("utf-8"))
    blank = [t for t in demo["transactions"] if not t["category"]]
    assert blank, "the demo must still carry own-card transfers"
    assert all(t["kind"] == "transfer" for t in blank), \
        "only a transfer may carry no category — anything else is a row the app cannot explain"

    # Board #12's half: `.user` means "this person answered this row", and
    # `recentCategories` reads it. A demo claiming it filled «Нещодавні» on a
    # phone whose owner had not tapped anything.
    assert not [t for t in demo["transactions"] if t["resolution"] == "user"], \
        "the demo may show a filled-in app; it may not put words in its owner's mouth"


def _code_only(src: str) -> str:
    """Swift source with `//` comment lines and trailing comments removed.

    Only for guards that forbid a literal. This repo documents the copy it
    replaces, so a plain substring check trips over the explanation of the very
    thing it is guarding against. Crude — it does not know about `//` inside a
    string literal — and that is fine for asserting one is ABSENT.
    """
    return "\n".join(line.split("//")[0] for line in src.splitlines())


def _privat_category_map() -> dict[str, str]:
    """`PrivatMapper.categoryMap`, read out of the Swift source.

    A literal dictionary of string pairs, so a regex is enough and a parser
    would be a second thing to maintain. The one non-literal value is
    `BudgetMath.cashCategory`, resolved here to the name the seed ships it
    under.
    """
    src = (ROOT / "ios/MonitorFinance/Import/PrivatMapper.swift").read_text("utf-8")
    body = re.search(
        r"static let categoryMap: \[String: String\] = \[(.*?)\n    \]", src, re.DOTALL
    )
    assert body, "the mapping table is not where the guard looks for it"
    out = {}
    for key, value in re.findall(r'"([^"]+)":\s*(?:"([^"]*)")', body.group(1)):
        out[key] = value
    for key in re.findall(r'"([^"]+)":\s*BudgetMath\.cashCategory', body.group(1)):
        out[key] = "Готівка"
    assert out, "the guard parsed no entries — the table's shape changed"
    return out


def test_the_privat_chip_can_never_create_a_category():
    """Board #14. `acceptSuggestion` calls `addCategory` with whatever the chip
    carries, so a statement word offered verbatim becomes a real category on
    one tap — «Ресторани, кафе, бари» beside the seeded «Кафе та ресторани»,
    splitting one shop's history between them. Board #15 spent a card folding
    forty names into nineteen; the chip grew them back one tap at a time.

    Pinned in pytest as well as in Swift because this is a claim about TWO
    files that no single test target owns: the map lives in the app, the
    nineteen names are generated by `build_ios_seed.py`, and a category renamed
    on the Python side leaves the Swift table pointing at a name that no longer
    exists — with no compiler and no unit test able to say so.
    """
    ref = json.loads(REFERENCE.read_text("utf-8"))
    seeded = {c["name"] for c in ref["categories"]}
    mapping = _privat_category_map()

    unknown = {k: v for k, v in mapping.items() if v not in seeded}
    assert not unknown, f"maps onto categories the seed does not ship: {unknown}"
    assert not (set(mapping.values()) & set(mapping)), \
        "a target that is also a key would move again on a second translation"


def test_the_privat_map_agrees_with_the_seed_generator():
    """The same word may not mean two things in two files.

    `CATEGORY_RENAMES` is where this project already ruled on what «Аптеки» or
    «Оплата частинами» becomes. The Swift table has to carry those rulings
    rather than re-decide them, or the seed generator and the import path fold
    the owner's history differently.

    Transfer names are exempt in one direction only: `PrivatMapper.suggestion`
    refuses anything starting «переказ» outright — a movement is not a purpose
    — where the generator, which is folding rows that ALREADY happened, guesses
    «Покупки» for them. Deliberate, and the reason is on both sides.
    """
    renames = _builder().CATEGORY_RENAMES
    mapping = _privat_category_map()

    for privat, ours in renames.items():
        if privat.lower().startswith("переказ") or not ours:
            assert privat.lower() not in mapping, \
                f"«{privat}» is a transfer word and must offer no chip at all"
            continue
        assert mapping.get(privat.lower()) == ours, \
            f"«{privat}» → «{ours}» in the seed generator, «{mapping.get(privat.lower())}» in Swift"


def test_the_privat_chip_says_what_tapping_it_does():
    """Board #14's other half. The chip was «Приват: Продукти» in green text on
    a pale wash — the shape of a label, on the one control in the queue that
    answers a card outright.

    The attribution went with the restyle because the mapping made it untrue:
    the word shown is the app's, not the bank's. What must NOT go is the check
    on `bankId` that keeps the chip off the 66 monobank seed rows carrying a
    legacy `suggestions` array — that one is still about provenance.
    """
    # Comments stripped: this file explains the copy it replaced, and a guard
    # that cannot tell an explanation from the thing it warns about fails on
    # its own documentation.
    queue = _code_only((ROOT / "ios/MonitorFinance/QueueView.swift").read_text("utf-8"))
    assert '"Так, \\(suggestion)"' in queue, "the chip must say what tapping it does"
    assert "Приват: " not in queue, "the app's own word may not be quoted as the bank's"
    assert "Theme.greenWash, in: Capsule()" not in queue, "a label's fill on a button"

    store = (ROOT / "ios/MonitorFinance/Store/AppStore+Queue.swift").read_text("utf-8")
    assert "tx.bankId == PrivatMapper.bankId" in store, \
        "only rows PrivatBank actually sent may offer a chip"
    assert "PrivatMapper.suggestion(for: raw)" in store, \
        "the queue must translate the bank's word before offering it"


def test_the_way_out_of_onboarding_is_not_called_skipping():
    """Board #17. The ONLY exit from onboarding was a button called
    «Пропустити», offered exactly when the user had already done the thing
    onboarding asked for — so the app called their finished setup a thing they
    had skipped, and invited them to abandon it.

    The identifier moved with the word, and this is what keeps the old one from
    creeping back into a test and re-teaching the old meaning. Comments are
    stripped: the source explains what it replaced.
    """
    picker = _code_only(
        (ROOT / "ios/MonitorFinance/Banks/BankPickerView.swift").read_text("utf-8")
    )
    # The WORD and the identifier, not the widget it is wrapped in: board #19
    # promoted this from a text button to the screen's primary control, and a
    # guard that pinned `Button("…")` would have failed on an improvement.
    assert '"Готово"' in picker
    assert 'accessibilityIdentifier("bank.done")' in picker

    swift = [
        p for p in (ROOT / "ios").rglob("*.swift") if "Tests" not in p.parts[-1]
    ]
    assert swift, "no Swift sources found — the guard would pass vacuously"
    stale = [
        str(p.relative_to(ROOT)) for p in swift if "bank.skip" in _code_only(p.read_text("utf-8"))
    ]
    assert not stale, f"«bank.skip» names a control that no longer skips: {stale}"


def test_the_bank_picker_answers_on_one_tap():
    """Board #19. Two banks, and choosing one took two taps: a radio button,
    then a «Далі» that was the biggest control on the screen and *disabled*
    until a row was picked — pointing the eye at a dead button while the real
    way forward sat under it as a small green link.

    Absence is asserted over APP sources only. The first version of this guard
    swept the tests too and failed on the UI test that asserts the control is
    gone — a `bank.next` in a test is a stale line only when the test WAITS for
    it, and `testTappingABankRowGoesStraightOnWithNothingToConfirm` is the one
    place naming it on purpose. That test is the real claim; this is the
    backstop for the view.
    """
    picker = _code_only(
        (ROOT / "ios/MonitorFinance/Banks/BankPickerView.swift").read_text("utf-8")
    )
    assert "onPick(bank.id)" in picker, "the row's own tap must be the choice"
    assert 'PrimaryButton(title: "Готово")' in picker, "the exit inherits the primary slot"
    assert "Далі" not in picker

    sources = sorted((ROOT / APP_SOURCES).rglob("*.swift"))
    assert sources, "no app sources found — the guard would pass vacuously"
    stale = [
        str(p.relative_to(ROOT)) for p in sources if "bank.next" in _code_only(p.read_text("utf-8"))
    ]
    assert not stale, f"«bank.next» names a control that no longer exists: {stale}"


def test_the_lock_asks_for_face_id_only_while_the_app_is_on_screen():
    """Board #21. `RootView` locks on the way OUT, so `LockWindow` presents
    `LockView` while the app is already backgrounding — and `onAppear` fired
    the Face ID prompt unconditionally, from a view nobody could see.

    With a grace period most of those returns dismiss the lock without wanting
    a prompt at all, and a Face ID sheet racing that dismissal is the exact
    interruption the card is about.

    A source guard because no test we can run sees it: the simulator has no
    enrolled biometrics (`-noBiometrics` everywhere), so both the guarded and
    the unguarded version leave every screen identical. It also pins the
    mechanism — `@Environment(\\.scenePhase)` is not trustworthy inside a
    hand-built `UIWindow`, which is why this reads `UIApplication` instead.
    """
    lock = _code_only((ROOT / APP_SOURCES / "Auth/LockView.swift").read_text("utf-8"))
    assert "UIApplication.shared.applicationState == .active" in lock, (
        "the automatic Face ID prompt must be gated on the app being on screen"
    )
    automatic = lock.split("func offerFaceIdIfActive", 1)[1]
    assert "Task { await faceId() }" in automatic, (
        "the automatic prompt must be the one behind the guard"
    )
    on_appear = lock.split(".onAppear {", 1)[1].split(".onReceive", 1)[0]
    assert "faceId()" not in on_appear, (
        f"`onAppear` must ask through the guard, not start the prompt itself: {on_appear!r}"
    )
    assert "offerFaceIdIfActive()" in on_appear
    # The «Увійти за Face ID» button is a deliberate tap and needs no gate —
    # it cannot be pressed from a screen nobody can see.
    assert 'accessibilityIdentifier("lock.faceid")' in lock


def test_the_lock_grace_is_never_written_to_disk():
    """Board #21. The grace covers an errand with the process still alive; a
    cold start locks however recent the stamp was. Keeping the stamp off
    `Settings` — the type that IS persisted — is what makes that true, and it
    is one refactor away from not being.

    `LockGraceTests.testTheStampIsNeverWrittenToDisk` asserts the same thing
    against the written file; this names the line to change if it ever fails.
    """
    models = _code_only((ROOT / APP_SOURCES / "Models/Models.swift").read_text("utf-8"))
    settings = models.split("struct Settings", 1)[1]
    assert "backgroundedAt" not in settings, "the grace stamp must not join the persisted settings"

    store = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))
    assert "private(set) var backgroundedAt: Date?" in store


def test_adding_a_bank_from_settings_walks_the_same_road_as_onboarding():
    """Board #22. Connecting a bank from Настройки skipped the card selection
    and never started a sync, so the rows turned up whenever the app was next
    activated — hours later — and the second card had been enrolled without
    anyone being asked. Onboarding, which is the same connection, does both.

    The route ORDER is the claim, and it is a source guard because the missing
    sync is invisible on every screen: a reconnect re-reads windows the app
    has already seen, so a run that starts brings no new rows to look at, and
    the only visible trace is a spinner whose lifetime depends on how many
    windows the stub is asked for. `SettingsTests.testAddBankFromSettings\
AsksWhichCardsAndReconnects` covers the half a simulator CAN see.

    Depth is deliberately absent: it is one setting for the whole app and
    lives in Налаштування → Дані.
    """
    home = _code_only((ROOT / APP_SOURCES / "Home/HomeView.swift").read_text("utf-8"))
    routes = home.split("private func settingsDestination", 1)[1]

    assert "TokenView(bankId: id) { path.append(.addBankCards(id)) }" in routes, (
        "the token screen must lead to the card selection, not straight to «Підключено»"
    )
    cards = routes.split("case .addBankCards", 1)[1].split("case .addBankConnected", 1)[0]
    assert "path.append(.addBankConnected(id))" in cards
    assert "Task { await store.startSync() }" in cards, (
        "connecting a bank from Settings must start a sync, the way onboarding does"
    )
    assert ".syncDepth" not in cards, "depth is global and stays in Налаштування → Дані"


def test_both_ways_into_privatbank_offer_the_same_two_sources():
    """Board #91. PrivatBank has two ways in — a forwarded letter and an
    exported statement — and the picker row is the same row in onboarding and
    in Налаштування → Банки → Додати банк. A branch that sent one of them
    straight to the file import would leave email connectable from exactly one
    place, and nothing on either screen would say so.

    A source guard for the same reason board #22's is: the missing half is
    invisible on the screen that has it. Both paths look right in isolation,
    and only reading them side by side shows one of them is short a source.
    """
    flow = _code_only((ROOT / APP_SOURCES / "Onboarding/OnboardingFlow.swift").read_text("utf-8"))
    home = _code_only((ROOT / APP_SOURCES / "Home/HomeView.swift").read_text("utf-8"))
    for name, source in (("OnboardingFlow", flow), ("HomeView", home)):
        assert "hasEmailSource" in source, (
            f"{name} must send the PrivatBank row to the two-way choice"
        )
        assert "PrivatSourceView(" in source, f"{name} must be able to draw it"
        assert "PrivatEmailSetupView(" in source, f"{name} must reach the setup screen"
        assert "case .privatSource" in source, f"{name} needs the route itself"


def test_no_income_vocabulary_is_hardcoded_again():
    """Board #94. The bug was a `Set<String>` of three Ukrainian names deciding
    what counted as income, so renaming or deleting one silently re-based the
    budget — the plan divided by a number that no longer matched what the
    person earned, and nothing on screen said so.

    A source guard because the failure is invisible from the outside: a
    reintroduced literal list keeps every test green for the seeded vocabulary
    and only breaks for a category somebody made. Two files are allowed, for
    different reasons, and both are named rather than pattern-matched so a
    third has to be argued for.
    """
    names = {"Зарплата", "Стипендія", "Інші надходження"}
    # `Models.swift` holds `CategoryKind.legacy(for:)` — the answer for a
    # category written before the field existed, which has no other truth to
    # recover. `BudgetMath.canonicalIncomeOrder` decides the ORDER the picker
    # offers a vocabulary in and never membership: dropping a name from it
    # changes what a list looks like, not what counts as income.
    allowed = ("ios/MonitorFinance/Models/Models.swift",
               "ios/MonitorFinance/Budget/BudgetMath.swift")
    found, stray = [], []
    for path in sorted((ROOT / APP_SOURCES).rglob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        source = _code_only(path.read_text("utf-8"))
        for number, line in enumerate(source.splitlines(), 1):
            if sum(1 for name in names if f'"{name}"' in line) < 2:
                continue
            found.append(f"{relative}:{number}")
            if not relative.startswith(allowed):
                stray.append(f"{relative}:{number}")
    assert stray == [], (
        "income must be decided by Category.kind, not by matching names: "
        f"{stray}"
    )
    assert found, "the guard matched nothing — the two allowed tables moved"


def test_every_seeded_category_declares_what_it_is():
    """Board #94. Income used to be decided by matching a category NAME against
    a hardcoded `Set<String>`, so renaming or deleting one silently re-based the
    whole budget — the plan divided by a number that no longer matched what the
    person earned, and nothing on screen said so.

    The seed says it now. These four names are the income vocabulary the base is
    built from, and a change here moves every plan, so they are asserted exactly
    rather than counted.
    """
    reference = json.loads(
        (ROOT / "ios/MonitorFinance/Resources/reference.json").read_text("utf-8")
    )
    by_kind = {}
    for category in reference["categories"]:
        assert "kind" in category, f"{category['name']} does not say what it is"
        by_kind.setdefault(category["kind"], set()).add(category["name"])
    assert by_kind["earned"] == {"Зарплата", "Стипендія", "Інші надходження"}
    assert by_kind["unearned"] == {"Подарунки"}, "a gift is income no plan is built on"
    assert len(by_kind["spending"]) > 10, by_kind["spending"]
    assert set(by_kind) == {"earned", "unearned", "spending"}, sorted(by_kind)


def test_the_donut_and_its_legend_colour_by_rank():
    """Board #24. `Theme.tint(for:)` hashes a name into twelve washes, and two
    of the nineteen seeded spending categories land on the same one — so two
    touching arcs could be a single blob, and the legend, keyed by the same
    hash, repeated the ambiguity instead of resolving it.

    A source guard because colour is invisible to XCUITest: the accessibility
    tree carries identifiers and labels, not fills, so a donut redrawn entirely
    in `tint(for:)` leaves every UI test in this repo green.
    `StatsColourTests` proves the palette is distinct; this proves the screen
    actually asks for it — and that the legend asks with the same INDEX the
    donut used, which is what makes a swatch mean the arc beside it.
    """
    stats = _code_only((ROOT / APP_SOURCES / "StatsView.swift").read_text("utf-8"))
    assert "Theme.tint(for:" not in stats, (
        "Статистика colours by rank now; `tint(for:)` stays for the screens that "
        "want one colour per category everywhere"
    )
    assert ".stroke(Theme.rank(index), lineWidth: 34)" in stats, "the arcs"
    assert ".fill(Theme.rank(index))" in stats, "the legend swatch, by the same index"
    # One `slices`, read by both — the alignment is structural, not a coincidence
    # of two identical expressions.
    assert stats.count("Derived.byProductGroup(scoped)") == 1
    assert stats.count("Derived.byCategory(scoped)") == 1


def test_the_receipts_mode_is_gated_on_there_being_receipts():
    """Board #24. `byProductGroup` files every UNSPLIT purchase under «Без
    чека», so «За чеками» is not empty for somebody with no receipts — it is a
    donut that is 100% «Без чека», the same lie board #20 took off Головна.

    Two halves. The mode is not OFFERED until something has been confirmed
    (`hasReceiptData`, asked of the whole dataset so the control does not
    appear and vanish as the period changes), and the stored flag alone can
    never turn it on — it can be true from a previous session.
    """
    stats = _code_only((ROOT / APP_SOURCES / "StatsView.swift").read_text("utf-8"))
    assert "var showingReceipts: Bool { bySplits && hasReceiptData }" in stats, (
        "a stored flag from a previous session must not select a mode that cannot work"
    )
    assert "if hasReceiptData {" in stats, "the picker itself is gated"
    assert "hasReceiptData: Bool {\n        store.transactions.contains" in stats, (
        "asked of the whole dataset — a picker that appeared and vanished with "
        "the period would be worse than either answer"
    )
    # Nothing CHOOSES on the raw flag any more. It survives only as the
    # `@AppStorage` declaration and the Picker's own binding.
    assert "bySplits ?" not in stats, "the raw flag must not pick which data to slice"
    for reader in ("showingReceipts ? Derived.byProductGroup",
                   "if showingReceipts {",
                   "showingReceipts && !scopedHasReceipts"):
        assert reader in stats, f"the gated value is what decides: {reader!r}"


def test_the_categories_screen_says_what_its_numbers_count():
    """Board #25. Every row ended with a bare number — mostly 0 on a fresh
    install — and nothing on the screen said it was an operation count. On a
    screen whose other figures are money, a right-aligned `0` reads as an
    amount at least as readily as a count.

    The card's other half — "the same Ukrainian sort fix as the picker" —
    turned out to be **already done**: both screens go through
    `Category.alphabetical`, whose collation `CategoryVocabularyTests` already
    pins. Checked against the code rather than taken from the card, and
    guarded here so the two cannot drift into two different sorts.
    """
    view = _code_only(
        (ROOT / APP_SOURCES / "Settings/CategoriesSettingsView.swift").read_text("utf-8")
    )
    assert "Plural.operations(count(name), store.settings.languageChoice)" in view, (
        "the count column must name its own unit"
    )
    assert 'Text("\\(count(name))")' not in view, "the bare number is what this card removed"
    assert "Category.alphabetical(store.categories.map(\\.name))" in view, (
        "the same ordering the picker uses — one function, so they cannot disagree"
    )

    picker = _code_only((ROOT / APP_SOURCES / "Categories/CategoryPicker.swift").read_text("utf-8"))
    assert "Category.alphabetical(store.categories.map(\\.name))" in picker


def test_the_skip_path_is_gone_but_its_stored_value_is_not():
    """Board #26. `store.skip()`, `store.reopen()` and `store.skipped` existed
    with zero UI callers, and a `FeedView` comment justified a rule by pointing
    at a "skipped list" in the queue that had never been built.

    The methods are deleted. **`Resolution.skipped` is deliberately kept**, and
    the distinction is the whole card: it is a PERSISTED raw value, so removing
    the case would make `Transaction`'s synthesised `Decodable` throw on any
    stored row carrying it — and `AppStore.init` loads with `try?`, so one such
    row would silently discard the whole transactions file and fall back to the
    seed. Every categorisation the owner ever made, gone, no error anywhere.

    A guard rather than a test because "there is no caller" is a statement
    about the whole source tree, which no unit test can make.
    """
    sources = sorted((ROOT / APP_SOURCES).rglob("*.swift"))
    assert sources, "no app sources found — the guard would pass vacuously"

    banned = ("func skip(", "func reopen(", "var skipped:")
    for path in sources:
        code = _code_only(path.read_text("utf-8"))
        for name in banned:
            assert name not in code, f"{path.relative_to(ROOT)} still declares {name!r}"

    models = _code_only((ROOT / APP_SOURCES / "Models/Models.swift").read_text("utf-8"))
    assert "case rule, pattern, transfer, user, pending, skipped" in models, (
        "the stored case must stay decodable — see this test's docstring"
    )
    detail = _code_only(
        (ROOT / APP_SOURCES / "Feed/TransactionDetailView.swift").read_text("utf-8")
    )
    assert "case .skipped:" in detail, "a legacy row still has to render as something"


def test_the_queue_tab_is_named_for_the_action_not_the_data_structure():
    """Board #27. «Черга» is what the code calls this screen; it is not what a
    person does there. The tab and the screen title are «Розібрати» now — the
    same verb Головна's card already used («Розібрати за хвилину»), so the
    button and the place it leads finally share a word.

    The CODE keeps «queue»: `QueueView`, `queue.title`, `pendingGroups`,
    `queueCardCount`. Renaming those would be a large diff with no user
    visible in it, and the identifiers are what every test addresses.

    Pins the WORD and the two places it appears, the way board #17's «Готово»
    guard does — a UI test taps the tab by its label, so a rename that missed
    the navigation title would still be green.

    **Board #64 reconsidered it and kept it. The decision, so nobody
    re-litigates it:**

    The complaint is real — «Розібрати» is a verb among four nouns (Головна,
    Стрічка, Бюджет, Статистика), and a tab bar is conventionally a list of
    places. The best noun considered was «Запитання»: it is what Головна's own
    card already counts («61 запитання · 66 покупок»), and it describes the
    screen from the person's side rather than the code's, so it would not
    repeat «Черга»'s mistake.

    It was rejected because the split it causes is worse than the
    inconsistency it fixes. One thing is named in three places — Головна's
    primary button «Розібрати за хвилину», this tab, and the screen title —
    and they share a word today. «Запитання» would leave the button saying one
    word and the tab another for the same destination, which is the kind of
    thing a person notices without being able to say why.

    The verb also earns its oddness: four of these tabs are places to look at,
    and this one is work to do. Naming it differently is honest about that.
    """
    main = _code_only((ROOT / APP_SOURCES / "MainView.swift").read_text("utf-8"))
    assert 'Label("Розібрати", systemImage: "tray.and.arrow.down")' in main

    queue = _code_only((ROOT / APP_SOURCES / "QueueView.swift").read_text("utf-8"))
    assert '.navigationTitle("Розібрати")' in queue, (
        "the screen a person lands on must be called what the tab promised"
    )

    # Scoped to app sources: a UI test naming the old word would be a test
    # asserting it is GONE, which is the opposite of a violation (board #19).
    sources = sorted((ROOT / APP_SOURCES).rglob("*.swift"))
    assert sources, "no app sources found — the guard would pass vacuously"
    stale = [
        str(p.relative_to(ROOT)) for p in sources if "Черга" in _code_only(p.read_text("utf-8"))
    ]
    assert not stale, f"«Черга» is the code's word for this screen, not the user's: {stale}"


def _appstore_loaded_names() -> set[str]:
    """The document names `AppStore.init` reads at launch.

    One reader for the two guards that need it. They were separate until board
    #68 changed the call shape from `try? repository.load("x", …)` to
    `Self.load("x", …, from: repository, …)`, and the #65 guard silently
    matched nothing — its `assert len(...) >= 9` is the only reason that was
    noticed rather than becoming a guard that passes on an empty set.
    """
    store = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))
    return set(re.findall(r'Self\.load\("([A-Za-z]+)"', store))


def test_every_persisted_file_has_an_oldest_shape_fixture():
    """Board #65: the user's data must survive an app update.

    `UpgradeSafetyTests` decodes a hand-written oldest-shape JSON for each
    persisted type, so adding a non-Optional field fails a test instead of an
    install. That only holds while the fixtures keep up with the files, and the
    way it silently stops holding is a NEW `repository.load(...)` in
    `AppStore.init` that nobody wrote a fixture for.

    This reads the load calls out of the source and requires each name to be
    covered. It is deliberately about the FILE names rather than the types:
    those names are the units `AppStore.init` falls back to the seed on, and
    the fallback is whole-file.
    """
    persisted = _appstore_loaded_names()
    assert len(persisted) >= 9, f"expected every persisted file to be found, got {persisted}"

    tests = (ROOT / "ios/MonitorFinanceTests/UpgradeSafetyTests.swift").read_text("utf-8")
    missing = sorted(name for name in persisted if f'"{name}"' not in tests)
    assert not missing, (
        f"persisted with no oldest-shape fixture in UpgradeSafetyTests: {missing}. "
        "A file with no fixture is one non-Optional field away from opening the app "
        "as if the person were new."
    )


def test_nothing_writes_the_users_data_without_file_protection():
    """Board #54. «Підготувати файл» wrote the whole dataset — every merchant,
    amount and category — into `temporaryDirectory` with a bare `.atomic`,
    while `Repository` sets `completeUntilFirstUserAuthentication` on the store
    deliberately and the two categorization exports in the same view set it
    too. Copying the app's own data somewhere weaker than the app keeps it is
    not a trade anybody made on purpose.

    **A source guard is the only gate that actually runs.**
    `ExportProtectionTests` reads the attribute back, which is the better test
    — and it SKIPS on the simulator, which reports no protection class at all,
    so it fires on a device and nowhere in CI. A skipped test is not a gate.

    Every `Data.write(` in app source is checked, so a new one cannot be added
    without a decision. `FileHandle.write(contentsOf:)` is excluded: it appends
    to a file whose protection was set when it was created (`CategorizationLog`
    passes `.protectionKey` to `createFile`).
    """
    sources = sorted((ROOT / APP_SOURCES).rglob("*.swift"))
    assert sources, "no app sources found — the guard would pass vacuously"

    unprotected = []
    for path in sources:
        code = _code_only(path.read_text("utf-8"))
        for match in re.finditer(r"\.write\(\s*(?:contentsOf:)?", code):
            if code[match.start():match.start() + 24].startswith(".write(contentsOf:"):
                continue                     # appending to an already-protected file
            window = code[match.start():match.start() + 320]
            if "completeFileProtectionUntilFirstUserAuthentication" not in window:
                line = code[: match.start()].count("\n") + 1
                unprotected.append(f"{path.relative_to(ROOT)}:{line}")
    assert not unprotected, (
        f"these write the user's data with no file protection: {unprotected}"
    )

    store = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))
    assert "func writeExport(to directory: URL" in store, (
        "the export write lives on the store so a device test can read the attribute back"
    )


def test_the_detail_screen_does_not_call_the_queues_mutation():
    """Board #13. `markNotAnExpense` cascades to every pending row of the
    merchant and teaches a `.transfer` rule; `setNotAnExpense` answers for the
    row in hand. The detail screen must call the second.

    A source guard rather than a UI test, and deliberately: the two calls leave
    the row LOOKING identical — `.transfer`, no category — so the difference is
    only visible in rows the detail screen does not show. Three attempts at a
    queue-count UI test are recorded in `DetailTests`; this is the check that
    cannot go flaky, and the behaviour itself is pinned by `QueueMutationTests`.
    """
    from pathlib import Path
    repo = Path(__file__).resolve().parent.parent
    view = (repo / "ios/MonitorFinance/Feed/TransactionDetailView.swift").read_text("utf-8")
    calls = [line.strip() for line in view.splitlines()
             if "store.markNotAnExpense" in line or "store.setNotAnExpense" in line]
    assert calls == ["case .notAnExpense: store.setNotAnExpense(id)"], calls


def test_the_badge_and_the_home_card_count_the_same_thing():
    """Board #8. The tab badge said 12 while the screen showed 4 cards, because
    the badge counted purchases and the queue asks one question per card.

    A source guard, because **the badge is not in the accessibility tree**:
    SwiftUI surfaces the tab as a plain Button labelled «Розібрати» with an
    empty `value`, so no UI test can read the number it displays. Dumped and
    confirmed, not assumed. `QueueFlowTests` pins Головна against the queue's
    own progress line — the two a test CAN see — and this pins the third to the
    same value they come from.

    Both must be fed the one local `MainView` computes, and neither may be fed
    `pendingRowCount`, which is the purchases and the thing they used to
    disagree over.
    """
    from pathlib import Path
    repo = Path(__file__).resolve().parent.parent
    view = (repo / "ios/MonitorFinance/MainView.swift").read_text("utf-8")

    assert "let cards = store.queueCardCount" in view, "the badge's number must be the card count"
    assert ".badge(cards)" in view, "the badge must show it"
    assert "HomeView(cards: cards," in view, "…and Головна must lead with the same value"

    # The row count reaches Головна as its SECOND number and nowhere else here.
    rows = [line.strip() for line in view.splitlines() if "pendingRowCount" in line]
    assert rows == ["let purchases = store.pendingRowCount"], rows
    assert "purchases: purchases" in view
    assert "badgeCount" not in view, "renamed precisely so this could not come back"


def test_demo_json_is_only_read_behind_a_debug_fence():
    """The file is excluded from Release by build setting; the code must be too,
    so a mistake in either one is caught by the other."""
    from pathlib import Path
    repo = Path(__file__).resolve().parent.parent
    loader = (repo / "ios/MonitorFinance/Models/SeedBundle.swift").read_text("utf-8")
    assert '"demo"' in loader
    before, _, _after = loader.partition('"demo"')
    assert before.count("#if DEBUG") > before.count("#endif"), \
        'the only reference to demo.json must sit inside a #if DEBUG block'


def _app_target_files():
    """Every file the app target's folder actually holds.

    Dotfiles are skipped: Xcode's file-system-synchronized groups do not copy
    them, and a `.DS_Store` appearing the moment anyone opens the folder in
    Finder would make these guards fail for a reason nobody can act on — and a
    test that fails spuriously is a test that gets deleted.
    """
    root = ROOT / "ios" / "MonitorFinance"
    return [
        p for p in root.rglob("*")
        if p.is_file() and not any(part.startswith(".") for part in p.relative_to(root).parts)
    ]


def test_release_excludes_every_bundled_resource_but_the_reference():
    """#if DEBUG hides the code, not the file. Without this build setting the
    owner's 772 transactions ship inside every App Store build.

    An ALLOWLIST, not a denylist of one filename. The target uses
    `PBXFileSystemSynchronizedRootGroup`, so folder membership — not a build
    phase anybody reviews — decides what is copied into the bundle, and
    `EXCLUDED_SOURCE_FILE_NAMES` is the only thing holding anything back. A
    future `demo-receipts.json`, a renamed `demo.v2.json`, or a stray copy of
    the xlsx dropped in the tree would all have shipped silently past a guard
    that only knew the name `demo.json`. So the folder's contents are named
    here, and everything in it that is not `reference.json` must be excluded
    by name.
    """
    resources = {p.name for p in _app_target_files() if p.parent.name == "Resources"}
    assert resources == {"reference.json", "demo.json"}, (
        f"{resources} — a new bundled resource must be decided about here, "
        "not discovered in an App Store build"
    )

    pbx = (ROOT / "ios/MonitorFinance.xcodeproj/project.pbxproj").read_text("utf-8")
    release = pbx.split("1A000000000000000000000E /* Release */")[1]
    settings = release.split("name = Release;")[0]
    assert "EXCLUDED_SOURCE_FILE_NAMES" in settings
    for name in sorted(resources - {"reference.json"}):
        assert name in settings, f"{name} would ship in Release"


def test_the_app_target_holds_nothing_but_swift_and_its_resources():
    """The other half of the allowlist above, and the reason it can be short.

    Everything under `ios/MonitorFinance/` is copied by folder membership, so
    a data file dropped anywhere else in that tree — beside the view that
    reads it, say — would never reach `Resources/` and would never be looked
    at by the resource check. Swift compiles rather than ships; everything
    else belongs in `Resources/`, where it is named and decided about.
    """
    def housed(path):
        # `Resources/` itself, or a `.lproj` inside it — board #85's
        # catalogues. A `.lproj` is the only nesting iOS gives a meaning to,
        # and it is still Resources: named, and decided about.
        if path.parent.name == "Resources":
            return True
        return path.parent.suffix == ".lproj" and path.parent.parent.name == "Resources"

    def compiled(path):
        # An asset catalogue (board #108). `actool` COMPILES a `.xcassets`
        # into `Assets.car` the way swiftc compiles a `.swift` — none of its
        # files reach the bundle as themselves, so none of them is a resource
        # shipping unreviewed. What is allowed INSIDE it is not waved through
        # here: `tests/test_app_icon.py` names every file and every variant.
        return any(part.endswith(".xcassets") for part in path.relative_to(ROOT).parts)

    strays = sorted(
        p.relative_to(ROOT).as_posix()
        for p in _app_target_files()
        if p.suffix != ".swift" and not housed(p) and not compiled(p)
    )
    assert strays == [], (
        f"non-Swift files outside Resources/ ship unreviewed: {strays}"
    )



APP_SOURCES = "ios/MonitorFinance"
ALLOWED_HOSTS = {
    "api.monobank.ua",
    "cabinet.tax.gov.ua",
    "inbound.example.com",
}
# The app contacts three hosts:
# - `api.monobank.ua`: financial transaction data from Monobank (MonobankClient).
# - `cabinet.tax.gov.ua`: fiscal receipt lookup URLs synthesised by ScannerView
#   as QR payload strings for the receipt parser to validate.
# - `inbound.example.com`: the PrivatBank email backend (PrivatEmailClient) —
#   it receives the notification letters Privat forwards, parses them into
#   transactions, and hands them to the app. Board #90 is the decision that
#   put it here; this public copy names a placeholder in place of the deployment.
#
# This guard ensures no third host appears without a documented decision.
# Per file AND per host, not per file alone: exempting a whole file exempts
# every host anyone later writes into it, reviewed or not.
#
# (TokenView used to mention api.monobank.ua in prose with no scheme, so the
# pattern never saw it. Board #18 made that step a real `Link`, so the host is
# now a `https://` literal there and passes on the allowlist, like any other.)
HOST_EXEMPT_FILES: dict[str, set[str]] = {
    # Board #145. `PrivatEmailStub` carries an invented URL for the download
    # link PrivatBank emails instead of a statement file. The app never
    # REQUESTS it — the link is shown to the person, who opens it in their own
    # browser — so this is a host the app displays, not one it contacts.
    #
    # `.test` is a reserved TLD that can never resolve, and the value is
    # deliberately not a privatbank.ua URL: the allowlist that matters lives in
    # the backend, and a stub that looked real would invite somebody to test it
    # from a side where it does not exist.
    #
    # Written here rather than added to ALLOWED_HOSTS, because this guard's
    # point is that a second host is "either a mistake or a decision nobody
    # wrote down" — and one file's stub is not a licence for the whole app.
    "ios/MonitorFinance/Sync/PrivatEmailStub.swift": {"example.test"},
}
# Any scheme, any case — `wss://` and `HTTPS://` are hosts too. The host is
# captured only when it is a *literal*: `"https://\(host)/v1"` and
# `"https://" + host` both capture the empty string, and an empty capture is an
# offender rather than a pass. Without that, putting a host in a variable — the
# normal way anyone would add one — would be invisible to this guard.
HOST_PATTERN = re.compile(r"(?i)\b[a-z][a-z0-9+.\-]*://([a-z0-9.\-]*)(.?)")


def _hosts_in(path):
    """(host, next character) for every `scheme://` literal in the file."""
    return HOST_PATTERN.findall(path.read_text(encoding="utf-8"))


def _host_offenders(rel, path):
    allowed = ALLOWED_HOSTS | HOST_EXEMPT_FILES.get(rel, set())
    out = []
    for host, after in _hosts_in(path):
        if not host:
            out.append(f"{rel}: non-literal host (interpolated or concatenated)")
        elif after == "@":
            out.append(f"{rel}: {host}@... — the real host is whatever follows the @")
        elif host.lower() not in allowed:
            out.append(f"{rel}: {host}")
    return out


def test_the_app_contacts_no_host_but_monobank():
    """There is no server. If a second host appears, it is either a mistake or
    a decision nobody wrote down."""
    sources = sorted(
        p for p in (ROOT / APP_SOURCES).rglob("*") if p.suffix in {".swift", ".json"}
    )
    assert sources, "no app sources found — the guard would pass vacuously"

    offenders, seen_monobank = [], False
    for path in sources:
        rel = path.relative_to(ROOT).as_posix()
        offenders += _host_offenders(rel, path)
        for host, after in _hosts_in(path):
            if host.lower() in ALLOWED_HOSTS and after != "@":
                seen_monobank = True
    assert not offenders, "unexpected hosts in the app target: " + "; ".join(offenders)
    assert seen_monobank, (
        "no api.monobank.ua literal anywhere in the app target — either the base "
        "URL stopped being a literal, or this guard is no longer watching anything"
    )


def test_the_tax_cabinet_host_is_named_literally_somewhere():
    """The mirror of `seen_monobank`. When `ScannerView`'s per-file exemption
    goes (the host is allowed outright now), the rot check below has nothing
    left to iterate and passes having asserted nothing. This is what keeps it
    honest: the second allowed host must actually appear, as a literal, or the
    allowance is standing permission for a host nobody uses."""
    sources = sorted(
        p for p in (ROOT / APP_SOURCES).rglob("*") if p.suffix in {".swift", ".json"}
    )
    found = any(
        host.lower() == "cabinet.tax.gov.ua" and after != "@"
        for path in sources
        for host, after in _hosts_in(path)
    )
    assert found, (
        "no cabinet.tax.gov.ua literal in the app target — either the base URL "
        "stopped being a literal, or this allowance is guarding nothing"
    )


def test_the_host_exemptions_have_not_rotted():
    """An exemption list that outlives its reason becomes standing permission."""
    for rel, exempted in sorted(HOST_EXEMPT_FILES.items()):
        path = ROOT / rel
        assert path.exists(), f"exempted file no longer exists: {rel}"
        found = {
            h.lower() for h, _ in _hosts_in(path)
            if h and h.lower() not in ALLOWED_HOSTS
        }
        assert found == exempted, (
            f"{rel} names {sorted(found)}, the exemption says {sorted(exempted)} — "
            "update it or drop it"
        )


def test_the_app_declares_no_transport_security_exceptions():
    """Info.plist is deliberately not scanned for URLs — its XML doctype names
    apple.com, and exempting that would add an entry guarding nothing. What
    matters in that file is that nothing weakens the connection to monobank."""
    plist = (ROOT / "ios/Info.plist").read_text(encoding="utf-8")
    assert "NSAppTransportSecurity" not in plist


def test_file_storage_asks_for_encryption_at_rest():
    """The simulator does not enforce data protection, so a runtime assertion
    can pass on a device that never encrypted anything. This reads the source
    instead: the option must be there to be honoured, and it must be the level
    background sync can still write through."""
    source = (ROOT / "ios/MonitorFinance/Store/Repository.swift").read_text(encoding="utf-8")
    assert "completeFileProtectionUntilFirstUserAuthentication" in source
    assert "FileProtectionType.completeUntilFirstUserAuthentication" in source
    # `.complete` locks the file whenever the phone is locked, which makes
    # background sync impossible. `\b` does not match inside
    # `completeUntilFirstUserAuthentication`, so these only catch the real thing.
    assert not re.search(r"\.completeFileProtection\b", source), (
        "`.completeFileProtection` locks files while the phone is locked — "
        "background sync cannot write"
    )
    assert not re.search(r"FileProtectionType\.complete\b", source), (
        "`FileProtectionType.complete` locks files while the phone is locked — "
        "background sync cannot write"
    )


def test_the_app_never_reads_the_cashier_attribute():
    """A fetched receipt names the cashier twice: `NDP_CSNM`, an ATTRIBUTE on
    the fiscal footer, and — on a different register — `AT_ON`, an ATTRIBUTE
    on the vendor block. Neither lives in the free-text lines the parser
    already drops (see `test_the_parser_drops_every_free_text_line` in
    `test_check_decode.py`). Nothing in the app may read either: not to
    display, not to store, not to log.

    A text scan, deliberately, matching `test_the_app_contacts_no_host_but_
    monobank` above: a name that appears nowhere in the sources — not even in
    a comment explaining that it is unread — cannot be read by accident. An
    AST or usage check would let a comment name the attribute safely; this
    guard is written to refuse that too, on purpose."""
    sources = [p for p in (ROOT / APP_SOURCES).rglob("*.swift")]
    assert sources, "no app sources found — the guard would pass vacuously"
    cashier_attributes = ("NDP_CSNM", "AT_ON")
    offenders = [
        (p.relative_to(ROOT).as_posix(), attribute)
        for p in sources
        for attribute in cashier_attributes
        if attribute in p.read_text(encoding="utf-8")
    ]
    assert not offenders, f"a cashier attribute is read in: {offenders}"


# Register/document numbers bound to the fiscal lookup key's own field names,
# pre-existing in the tree and deliberately invented — `Receipt`/`FiscalCheck`
# fixtures for scenarios that have nothing to do with a real capture, and the
# malformed-QR cases in `FiscalQRTests`. None was ever derived from a capture;
# `test_the_fiscal_number_exemptions_have_not_rotted` keeps this from quietly
# becoming a place to launder a real one.
PRE_EXISTING_FISCAL_NUMBER_LITERALS = {
    "1", "2",
    "3000000001", "3000000009", "3000000099", "3000000000",
    "4000123456", "1234567890",
    "5000000001", "5000000002",
    "1000000001", "1000000009", "1000000099",
}

# Where the fiscal lookup key's four fields (see `scripts/check_decode.py`:
# `id` <- document number, `fn` <- register number) show up as a literal
# outside the base64-blob fixtures the capture pipeline already scrubs:
# Swift initializer arguments, the Python capture-replay call, the JSON echo
# of `fn`, the query string itself, and assertion-site literals
# (`by["fn"], "…"` / `params["fn"] == "…"`) — the exact shape the leak took
# in the file that leaked it (TaxCabinetClientTests.swift:37-38).
_FISCAL_KEY_LITERAL_PATTERNS = [
    re.compile(r'\bregisterNumber:\s*"(\d+)"'),
    re.compile(r'\bdocumentNumber:\s*"(\d+)"'),
    re.compile(r'\bregister_no="(\d+)"'),
    re.compile(r'\bdoc_no="(\d+)"'),
    re.compile(r'"fn":\s*"(\d+)"'),
    re.compile(r'[?&]fn=(\d+)'),
    re.compile(r'[?&]id=(\d+)'),
    re.compile(r'\[["\'](?:fn|id)["\']\]\s*,\s*"(\d+)"'),
    re.compile(r'\[["\'](?:fn|id)["\']\]\s*==\s*"(\d+)"'),
]
_SCRUBBED_FISCAL_NUMBER_SHAPE = re.compile(r"^(\d)\1*$")


def _fiscal_number_sources():
    # `Generated/` is included, not excluded: it is where a leaked real value
    # would land if a hand-typed source ever leaked one and the generator
    # copied it forward untouched (as happened with the `mac` literal before
    # this branch centralised it into `CheckFixture.mac`). It is regenerated
    # from `tests/fixtures/`, so a hit here means the fixture itself leaked —
    # still worth catching at the point closest to what actually ships.
    return sorted(
        p
        for root in (ROOT / "ios", ROOT / "tests", ROOT / "docs", ROOT / "scripts")
        for p in root.rglob("*")
        if p.suffix in {".swift", ".py", ".md", ".json"}
    )


def test_no_fiscal_lookup_key_literal_escapes_the_scrub():
    """R14/F0: the real fiscal lookup key (`fn`+`id`, with `date`/`sm`) was
    found committed in the clear in four files this branch added — each one
    a real value hand-typed (almost certainly copy-pasted from a raw
    capture) instead of produced by `scripts/capture_check_fixture.py`,
    which always emits a same-length run of one repeated digit. This is the
    guard that catches the next one: every register/document-number literal
    bound to one of the lookup key's own field names must match that shape,
    or be a pre-existing, deliberately-invented placeholder that predates
    this guard and is not a capture."""
    sources = _fiscal_number_sources()
    assert sources, "no source found — the guard would pass vacuously"

    offenders = []
    for path in sources:
        text = path.read_text(encoding="utf-8")
        for pattern in _FISCAL_KEY_LITERAL_PATTERNS:
            for m in pattern.finditer(text):
                value = m.group(1)
                if _SCRUBBED_FISCAL_NUMBER_SHAPE.match(value):
                    continue
                if value in PRE_EXISTING_FISCAL_NUMBER_LITERALS:
                    continue
                offenders.append((path.relative_to(ROOT).as_posix(), value))
    assert offenders == [], f"unscrubbed fiscal lookup-key literal: {offenders}"

    # Two positive partners, because the assertion above would pass just as
    # happily for a scan that can never match anything. The negative control
    # is composed at runtime rather than spelled as a literal: a guard that
    # hardcodes the real register number it exists to keep out of the tree
    # would defeat itself. This produces a real-shaped (10-digit, non-uniform)
    # value that is not any of the eight captured register numbers and is not
    # in the exemption set — it proves the same two properties without ever
    # committing the secret.
    assert _SCRUBBED_FISCAL_NUMBER_SHAPE.match("9999999999")
    non_uniform_control = "".join(str((i * 3 + 1) % 10) for i in range(10))
    assert not _SCRUBBED_FISCAL_NUMBER_SHAPE.match(non_uniform_control)
    assert non_uniform_control not in PRE_EXISTING_FISCAL_NUMBER_LITERALS


def test_the_fiscal_number_exemptions_have_not_rotted():
    """Every exemption in `PRE_EXISTING_FISCAL_NUMBER_LITERALS` must still be
    bound to a fiscal-key field name somewhere, or it is a standing
    permission nobody is using any more."""
    sources = _fiscal_number_sources()
    seen = {
        m.group(1)
        for path in sources
        for pattern in _FISCAL_KEY_LITERAL_PATTERNS
        for m in pattern.finditer(path.read_text(encoding="utf-8"))
    }
    stale = PRE_EXISTING_FISCAL_NUMBER_LITERALS - seen
    assert not stale, f"exempted but no longer present anywhere: {stale}"


def test_the_categorization_log_is_debug_only():
    """The app tells its users their data never leaves the device. The
    categorization log is the one thing in the tree that would send some of it
    somewhere, so it may not exist in a Release binary at all — a telemetry
    path that ships and merely promises not to fire is a weaker promise than
    one the compiler keeps.

    Two halves, because either alone can rot: the file itself is one fence,
    and every reference to it from ordinary app code sits inside a fence of
    its own. The third proof is the `nm` recipe in docs/HANDOFF.md, which
    reads the built product rather than the source.
    """
    log = ROOT / "ios/MonitorFinance/Debug/CategorizationLog.swift"
    text = log.read_text(encoding="utf-8")
    # Line-initial only: the doc comments in that file talk ABOUT the fence,
    # and a substring count would read those as fences of their own.
    fences = [m.start() for m in re.finditer(r"^#if DEBUG$", text, re.MULTILINE)]
    assert len(fences) == 1, "one fence, so there is one thing to check"
    assert text.rstrip().endswith("#endif"), "the fence must close at the end of the file"
    # `CategorizationSource` is deliberately OUTSIDE the fence — it is a
    # parameter type on mutations that exist in every build, and an enum of
    # words carries nothing off the device. Everything that can touch data
    # must come after the fence opens.
    fence = fences[0]
    assert text.index("enum CategorizationSource") < fence
    for declaration in (
        "struct CategorizationEvent",
        "protocol CategorizationLogStore",
        "protocol CategorizationEventSender",
        "final class CategorizationLog",
        "final class CategorizationFileStore",
        "struct CategorizationWebhookSender",
    ):
        assert text.index(declaration) > fence, f"{declaration} is not behind the fence"

    referring = [
        p for p in _app_sources()
        if p != log and "CategorizationLog" in p.read_text(encoding="utf-8")
    ]
    app_referring = [p for p in referring if "/MonitorFinance/" in str(p)
                     and "Tests" not in p.parts[-2]]
    assert app_referring, "no references found — this guard would pass vacuously"
    for path in app_referring:
        body = path.read_text(encoding="utf-8")
        for index in (i for i in range(len(body)) if body.startswith("CategorizationLog", i)):
            before = body[:index]
            assert before.count("#if DEBUG") > before.count("#endif"), (
                f"{path.name} names CategorizationLog outside a #if DEBUG fence"
            )


# `mcc` and `originalMcc` are bank-authored facts about a MERCHANT, not
# spending categories, and board #56's second checkbox is the whole risk: the
# codes look categorical, so the failure mode is somebody reading one straight
# into `Transaction.category`. Nothing chooses a category from them today, and
# the day something should, it will be a card that says so — this guard is what
# makes that a decision rather than a drift.
MCC_READERS = {
    "Models/Models.swift",                # the declarations
    "Sync/MonobankModels.swift",          # the wire shape
    "Sync/MonobankMapper.swift",          # wire -> Transaction, unchanged
    "Sync/MonobankStub.swift",            # the Debug stub's rows
    "Store/AppStore+Sync.swift",          # the re-fetch merge
    "Debug/CategorizationLog.swift",      # training data, Debug-only
    "Import/PrivatMapper.swift",          # explicitly `nil` — the export has no column
    "Sync/PrivatEmailMapper.swift",       # explicitly `nil` — a letter has no code either
}
MCC_PATTERN = re.compile(r"(?<![A-Za-z])(originalMcc|mcc)(?![A-Za-z])")


def test_the_merchant_codes_are_stored_and_read_by_nothing_that_categorises():
    """Board #56. Where the two MCC fields may appear at all, spelled out.

    A file list rather than a search for `category =`: the codes reaching a
    view, a suggestion, `Derived` or the categoriser is the thing to notice,
    and none of those has any business naming the field for any reason. Adding
    a legitimate reader means adding it here, in one line, with a card behind
    it.
    """
    found = {}
    for path in (ROOT / APP_SOURCES).rglob("*.swift"):
        rel = path.relative_to(ROOT / APP_SOURCES).as_posix()
        names = set(MCC_PATTERN.findall(_code_only(path.read_text(encoding="utf-8"))))
        if names:
            found[rel] = names

    assert found, "no MCC references at all — the guard would pass vacuously"
    assert set(found) <= MCC_READERS, (
        f"an MCC code reached a file with no business reading one: "
        f"{sorted(set(found) - MCC_READERS)}"
    )
    # The two fields that must exist, where they must exist. Without this the
    # test above passes just as happily on a tree where board #56 was reverted.
    for rel in ("Models/Models.swift", "Sync/MonobankModels.swift",
                "Sync/MonobankMapper.swift", "Store/AppStore+Sync.swift",
                "Debug/CategorizationLog.swift"):
        assert "originalMcc" in found.get(rel, set()), (
            f"{rel} stopped carrying originalMcc — the 31-day window does not reopen"
        )


def test_a_queue_card_is_named_by_its_identity_not_by_its_merchant():
    """Board #55. `queue.group.<key>` and `queue.suggest.<key>` named a
    MERCHANT, and the queue renders more than one card per merchant two
    different ways: a generic merchant («На картку», 35 rows in the demo seed)
    gets one card per row, and a merchant that both paid and charged gets an
    income card beside its expense one.

    Nothing in the app misbehaved — SwiftUI keys its `ForEach` on
    `MerchantGroup.id`, which is unique. What broke was the accessibility
    tree: `firstMatch` handed back whichever card it reached first, so a test
    naming a particular one passed having exercised a different one.

    A guard rather than a unit test because the defect is in a view's
    interpolation, and no XCUITest can assert the ABSENCE of a name it never
    knew to look for.
    """
    queue = _code_only((ROOT / APP_SOURCES / "QueueView.swift").read_text("utf-8"))
    for banned in ("queue.group.\\(group.key)", "queue.suggest.\\(group.key)"):
        assert banned not in queue, f"{banned} names a merchant, not a card"
    for required in ("queue.group.\\(group.id)", "queue.suggest.\\(group.id)"):
        assert required in queue, f"{required} is gone — the identifiers are ambiguous again"

    # …and `id` has to keep carrying the row, or the line above is satisfied
    # by an `id` that is just the key again.
    model = _code_only((ROOT / APP_SOURCES / "Store/AppStore+Queue.swift").read_text("utf-8"))
    identity = model[model.index("struct MerchantGroup"):]
    identity = identity[identity.index("var id: String"):]
    identity = identity[: identity.index("\n    }")]
    for part in ("kind.rawValue", "rowId"):
        assert part in identity, f"MerchantGroup.id no longer distinguishes by {part}"


def test_no_document_is_loaded_without_being_watched():
    """Board #68. `AppStore.init` must route every load through the path that
    tells a missing file from a corrupt one — and every name it loads must
    have a word a person can read, or the settings screen reports a storage
    key at somebody whose history just went quiet.

    `LoadFailureTests` corrupts each of the nine documents by name and would
    catch a load that skipped the recording path. What it cannot catch is a
    TENTH document added later: the Swift test would keep passing on its own
    nine. This reads the names out of the source instead.
    """
    store = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))

    assert "try? repository.load(" not in store, (
        "a bare `try?` load cannot tell a missing file from a corrupt one"
    )

    loaded = _appstore_loaded_names()
    assert len(loaded) >= 9, f"only {loaded} — the guard would pass vacuously"

    titled = set(re.findall(r'case "([A-Za-z]+)":', store))
    missing = loaded - titled
    assert not missing, (
        f"loaded but with no word for a person to read: {sorted(missing)} — "
        "`AppStore.fileTitle` would print the storage key on a settings screen"
    )


def test_a_corrupt_file_is_moved_aside_before_anything_can_overwrite_it():
    """Board #68's other half, which the card did not name. Reporting a
    corrupt file is worth little if the next `persist()` writes the seed over
    it — the report would name a loss a moment before making it permanent.

    A guard as well as a test because the two `Repository` implementations
    have to keep agreeing, and a conforming type that quietly no-ops
    `quarantine` would satisfy every unit test written against the other one.
    """
    repo = _code_only((ROOT / APP_SOURCES / "Store/Repository.swift").read_text("utf-8"))
    assert "func quarantine(_ name: String) throws" in repo, "the protocol requirement is gone"
    # One shared spelling of the suffix, so the two implementations cannot
    # quarantine under different names.
    assert repo.count("quarantineName") >= 3, (
        "each implementation must use the shared suffix, not spell its own"
    )
    for implementation in ("final class FileRepository", "final class MemoryRepository"):
        body = repo[repo.index(implementation):]
        body = body[: body.index("\n}\n")] if "\n}\n" in body else body
        assert "func quarantine(" in body, f"{implementation} does not implement it"

    store = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))
    catch = store[store.index("failures.append(name)"):]
    assert "repository.quarantine(name)" in catch[:200], (
        "a recorded failure that is not moved aside is still overwritten on the next save"
    )


APPEARANCE_EXEMPT = {
    # Bank BRAND colours. monobank's tile is black because monobank is black,
    # and a brand does not change with the phone's appearance. Legibility is
    # bought with a hairline instead — see the comment at the call site.
    "Banks/BankPickerView.swift",
}


def test_no_screen_hardcodes_a_colour_that_cannot_follow_the_appearance():
    """Board #58. Every `Theme` colour is dynamic, which is what let several
    hundred call sites carry on unchanged. The way that quietly stops being
    true is a NEW screen writing `Color(red:…)` or `.black.opacity(…)` of its
    own: correct in the light scheme, invisible in the dark one, and nothing
    fails — the screen simply looks wrong to whoever has dark on.

    `ScannerView` was doing exactly that with the card shadow, copied from
    `Card` before `Theme.cardShadow` existed.
    """
    banned = ("Color(red:", "Color(white:", "Color.black", "Color.white",
              ".black.opacity(", ".white.opacity(")
    offenders = []
    for path in sorted((ROOT / APP_SOURCES).rglob("*.swift")):
        rel = path.relative_to(ROOT / APP_SOURCES).as_posix()
        if rel in {"Theme.swift"} | APPEARANCE_EXEMPT:
            continue
        code = _code_only(path.read_text(encoding="utf-8"))
        offenders += [f"{rel}: {b}" for b in banned if b in code]

    assert offenders == [], (
        f"a colour that cannot follow the appearance: {offenders}. "
        "Add it to `Theme` as a dynamic colour, or exempt it here with a reason."
    )
    # The exemptions have to still be earning their keep, or they outlive the
    # thing they were written for and quietly widen.
    for rel in APPEARANCE_EXEMPT:
        code = _code_only((ROOT / APP_SOURCES / rel).read_text(encoding="utf-8"))
        assert any(b in code for b in banned), f"{rel} is exempted and no longer needs to be"


def test_the_appearance_choice_is_persisted_and_applied_in_one_place():
    """Board #58. Two halves that are easy to half-do: the scheme is applied
    above every screen, and the choice survives a relaunch.

    `preferredColorScheme` must sit on `RootView` and not on the `WindowGroup`
    — on the scene it is read once at construction, so changing it in
    Налаштування would not repaint until the next launch. That is a
    behavioural difference no unit test can see and a UI test would have to
    catch by comparing pixels.
    """
    app_file = _code_only(
        (ROOT / APP_SOURCES / "MonitorFinanceApp.swift").read_text("utf-8")
    )
    assert ".preferredColorScheme(store.settings.appearanceChoice.colorScheme)" in app_file, (
        "the appearance is not applied, or not from the stored choice"
    )
    root = app_file[app_file.index("struct RootView"):]
    assert ".preferredColorScheme(" in root, (
        "it must be inside RootView — on the WindowGroup it is read once, at launch"
    )

    models = _code_only((ROOT / APP_SOURCES / "Models/Models.swift").read_text("utf-8"))
    assert "var appearance: Appearance? = nil" in models, (
        "a non-Optional persisted field makes every settings.json on a device undecodable"
    )
    # Same protection `BankStatus` carries: a fourth case written by a later
    # build must not take the whole settings file down with it.
    appearance = models[models.index("enum Appearance"):]
    assert "Appearance(rawValue: raw) ?? .system" in appearance[:1600], (
        "an unknown raw value must decode as .system — a throw here takes the whole "
        "settings.json, which AppStore.init loads with a fallback to a blank Settings()"
    )


def test_the_lock_window_takes_the_appearance_override_too():
    """Board #58. `preferredColorScheme` reaches the window SwiftUI owns, and
    the lock is deliberately a SECOND `UIWindow` — high enough to outrank any
    presentation. So the app's own override does not reach it, and a person who
    had pinned the app to dark met a light lock screen on a light phone: the
    first screen the app shows, in the wrong appearance.

    A guard because there is no seam: the window is built inside `present`,
    and a unit test can assert the mapping (`AppearanceTests`) but not that
    anybody applied it.
    """
    lock = _code_only((ROOT / APP_SOURCES / "Auth/LockWindow.swift").read_text("utf-8"))
    assert "overrideUserInterfaceStyle = store.settings.appearanceChoice.uiStyle" in lock, (
        "the lock window ignores the app's appearance"
    )
    # Before `rootViewController`/`isHidden`, or the window is on screen for a
    # frame in the wrong appearance.
    assert lock.index("overrideUserInterfaceStyle") < lock.index("lock.isHidden = false")


def test_the_guide_is_shown_once_and_can_be_opened_again():
    """Board #60. Both criteria, and the coupling that makes them work.

    `-skipOnboarding` has to stamp the guide seen, or every UI test in the
    suite opens under a sheet it did not ask for — and the tests that walk
    onboarding for real still meet the guide, which is the only place it should
    be met.
    """
    store = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))
    assert "if Launch.skipOnboarding || Launch.noGuide { store.markGuideSeen() }" in store, (
        "-skipOnboarding must pretend the first run happened, guide included, and "
        "-noGuide must say the same for a test that walks onboarding for real"
    )

    main = _code_only((ROOT / APP_SOURCES / "MainView.swift").read_text("utf-8"))
    assert "!store.settings.hasSeenGuide" in main, "the guide is shown unconditionally"
    # The lock is a separate window and outranks any presentation, so a sheet
    # raised while locked would be invisible AND would stamp itself seen.
    assert "guard !hideTabs" in main, "the guide must not be raised behind the lock"
    # …and the tabs stay mounted while locked, so `onAppear` alone fires once,
    # possibly behind the lock, and never again for that session.
    assert "onChange(of: hideTabs)" in main, (
        "the guide is never re-offered after the lock lifts"
    )

    about = _code_only((ROOT / APP_SOURCES / "Settings/AboutView.swift").read_text("utf-8"))
    assert 'accessibilityIdentifier("about.guide")' in about, "no way to open it again"
    assert "GuideView()" in about, (
        "re-opening must not pass onFinish — it would rewrite when the guide was first read"
    )


def test_about_does_not_call_a_shipped_feature_unbuilt():
    """Board #60 moved three lines out of «Що ще ні»: a guide explaining the
    budget and the receipt scanner sits two taps from that screen, and all
    three had shipped. A screen whose whole job is to say plainly what is real
    is the worst place in the app to be out of date.

    Named features rather than the heading, so this keeps meaning something if
    a genuinely-unbuilt list ever comes back.
    """
    about = _code_only((ROOT / APP_SOURCES / "Settings/AboutView.swift").read_text("utf-8"))
    unbuilt = about[about.index('Text("Що вже справжнє")'):] if 'Що ще ні' not in about else ""
    assert "Що ще ні" not in about, (
        "the unbuilt list is back — check every line on it is genuinely unbuilt"
    )
    assert unbuilt, "the «Що вже справжнє» card is gone"
    for shipped in ("Бюджет", "чеки", "monobank"):
        assert shipped in unbuilt, f"«{shipped}» has shipped and is not listed as real"


def test_a_budget_plan_belongs_to_a_month():
    """Board #62. The model change and the migration that makes it safe.

    `budget.json` holds ONE plan and `AppStore.init` loads it with a fallback,
    so replacing that file's shape with a month-keyed dictionary would have
    made every plan already on a device fail to decode and vanish. The month
    is an Optional field on the existing shape, and superseded plans go to a
    NEW file whose absence is simply an empty array.
    """
    models = _code_only((ROOT / APP_SOURCES / "Models/Models.swift").read_text("utf-8"))
    assert "var month: MonthKey? = nil" in models, (
        "a non-Optional month makes every budget.json on a device undecodable"
    )

    store = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))
    assert 'Self.load("budgetHistory"' in store, "superseded plans are not loaded"
    # Matched with the receiver left open. Board #132 moved persisting onto a
    # snapshot, so the spelling became `s.budgetHistory` — the guard is about
    # the history being SAVED, not about which variable holds it on the day.
    assert re.search(r'repository\.save\([\w.]*\bbudgetHistory, as: "budgetHistory"\)', store), (
        "…or not saved, which is a past month measured wrong on the next launch"
    )
    # The export is the whole dataset. Carrying only the current plan would
    # export a file that cannot reproduce the months it contains.
    assert "budgetHistory: budgetHistory" in store, "the export drops the earlier plans"
    # A reset is a fresh install.
    #
    # Matched on the open paren, not on `resetEverything()`. Board #168 gave the
    # method a `keepingMailbox` parameter and this guard stopped finding it at
    # all — a `ValueError`, which at least fails loudly, but the same edit one
    # character later would have sliced from somewhere else and gone on passing.
    # The window is generous for the same reason: it is here to catch the line
    # being DELETED, not to police how long the method is.
    reset = store[store.index("func resetEverything("):]
    assert "budgetHistory = []" in reset[:2500], "a reset leaves the old plans behind"

    # nil month = in force for every month. That is not tidiness: it is exactly
    # what the build before #62 did, so nothing anybody has looked at moves.
    assert "$0.month.map { $0 <= month } ?? true" in store, (
        "a plan with no month must stay in force everywhere, or an upgrade "
        "silently empties every past month's budget screen"
    )


def test_a_past_month_is_not_measured_against_a_later_plan():
    """Board #62's third criterion, in the view. `BudgetView` used to read
    `store.budget` — the single current plan — for whatever month was on
    screen, so browsing back to March measured March against a plan written in
    August.
    """
    view = _code_only((ROOT / APP_SOURCES / "Budget/BudgetView.swift").read_text("utf-8"))
    assert "store.plan(for: current)" in view, "the view still reads the single plan"
    assert "store.budget.map" not in view, "…or reads it in the old way somewhere else"
    # …and the screen names the month whose plan it is showing, which is what
    # makes measuring a pre-plan month against the earliest plan honest rather
    # than an implication.
    assert 'accessibilityIdentifier("budget.planMonth")' in view


def test_the_tab_swipe_yields_to_taps_the_edge_and_the_lock():
    """Boards #63 and #132. Each of these is one line that produces no compile
    error when removed, and each was bought the expensive way.

    The MECHANISM changed with #132 — a SwiftUI `DragGesture` cannot decline a
    touch by direction, so it took every fast vertical flick off the
    `ScrollView` and the queue froze — but every reason below survived the
    change unaltered.
    """
    swipe = _code_only((ROOT / APP_SOURCES / "App/WindowSwipe.swift").read_text("utf-8"))
    main = _code_only((ROOT / APP_SOURCES / "MainView.swift").read_text("utf-8"))

    assert "func isMine(velocity: CGPoint" in swipe, (
        "the rule must be asked of the VELOCITY, which has a direction from "
        "the first movement — asking the DISTANCE is the board #132 bug"
    )
    assert "other.require(toFail: pan)" in swipe, (
        "a horizontal drag across one of this app's full-width buttons fires "
        "as a tap otherwise; `cancelsTouchesInView` does not reach a SwiftUI "
        "Button's own recogniser, and three UI tests said so"
    )
    assert "shouldRecognizeSimultaneouslyWith" in swipe, (
        "refusing simultaneous recognition is what made the queue freeze"
    )
    assert "startX > edge" in swipe, (
        "the left edge belongs to NavigationStack's interactive pop"
    )
    assert "abs(velocity.x) > abs(velocity.y) * ratio" in swipe, (
        "without the ratio a scroll that drifted sideways changes tab"
    )
    assert "guard !pushed else { return false }" in swipe, (
        "a covered screen must keep its own gestures and nothing else — the "
        "old per-screen modifier got this free by simply not being there"
    )
    assert "root.presentedViewController != nil { return true }" in swipe, (
        "a SHEET carries its own NavigationStack at depth 1, so a depth test "
        "alone calls it uncovered — and a swipe inside the budget scope "
        "editor would change the tab behind it"
    )
    assert "(0...4).contains(next)" in main, (
        "the ends must not wrap — Розібрати is the badge tab, and the one "
        "place an accidental arrival costs most"
    )
    # The tabs stay mounted behind the lock, so a live closure there would
    # move the app underneath it.
    assert "hideTabs ? nil : move" in main, "the swipe must be inert while locked"


def test_the_tab_swipe_is_installed_exactly_once():
    """Board #132 replaced five gestures with one recogniser, and "one" is
    load-bearing rather than tidy.

    The window recogniser is an ancestor of everything on screen, so a second
    installer would move TWO tabs per swipe. Board #63's original one-line
    version failed the other way — a SwiftUI gesture on the `TabView` beat
    every `List` row's own `swipeActions` — and the placement rule that fixed
    it (inside each stack) is what #132 replaced with an explicit
    `isCovered` check. Both constraints still hold; only the
    mechanism enforcing them changed.
    """
    main = _code_only((ROOT / APP_SOURCES / "MainView.swift").read_text("utf-8"))
    assert main.count("WindowSwipeInstaller(") == 1, (
        "two installers means two recognisers on one window, which is two "
        "tabs per swipe"
    )
    # …and no screen carries one of its own.
    roots = ["Home/HomeView.swift", "Budget/BudgetView.swift", "QueueView.swift",
             "StatsView.swift", "Feed/FeedView.swift"]
    for rel in roots:
        code = _code_only((ROOT / APP_SOURCES / rel).read_text(encoding="utf-8"))
        assert "WindowSwipeInstaller" not in code and ".tabSwipe" not in code, (
            f"{rel} installs its own swipe; there must be exactly one, in MainView"
        )


def test_no_screen_colours_a_category_by_hashing_its_name():
    """Board #57. A category's colour is a property of the category.

    `Theme.tint(for: String)` hashed a name into twelve washes, so nineteen
    seeded categories collided by arithmetic — «Покупки» and «Послуги» were one
    colour on every screen that drew a swatch. The fix is `Category.tintIndex`,
    which means the colour can only be read from the store.

    So the hash must not come back, under its old name or a new one, at a
    render site. `Theme.fallbackIndex` survives for a category the store has
    never heard of; this guard is what stops it quietly becoming the mechanism
    again.
    """
    # Theme defines the fallback; AppStore is the one caller entitled to it,
    # for a name no category holds. Anywhere else is a view that skipped
    # asking the store.
    allowed_fallback = {"Theme.swift", "Store/AppStore.swift"}
    offenders = []
    for path in (ROOT / APP_SOURCES).rglob("*.swift"):
        code = _code_only(path.read_text(encoding="utf-8"))
        rel = path.relative_to(ROOT / APP_SOURCES).as_posix()
        if "Theme.tint(for:" in code or "Theme.tintIndex(" in code:
            offenders.append(rel)
        if rel not in allowed_fallback and "fallbackIndex" in code:
            offenders.append(rel)
    assert not offenders, (
        f"these colour a category by hashing its name again: {sorted(set(offenders))}"
    )
    # …and the fallback really is only reached when nothing else can answer,
    # rather than having quietly become the mechanism again.
    store = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))
    assert store.count("fallbackIndex") == 1, (
        "AppStore reaches for the hash in more than one place"
    )
    lookup = store.split("func tintIndex(for category: String) -> Int {")[1][:400]
    assert "categories.first(where:" in lookup and "fallbackIndex" in lookup, (
        "the lookup no longer asks the category before falling back to a hash"
    )


def test_every_category_swatch_is_drawn_by_one_view():
    """Board #57, the other half: four screens must not each know the rule.

    `FeedView`, `TransactionDetailView`, `CategoryPicker` and
    `CategoriesSettingsView` each drew their own filled rectangle. That was
    survivable while the colour was a pure function of the name; once it is a
    property held by the store, every one of the four has to know how to ask —
    and the day one of them forgets is the day a category is two colours in one
    app.
    """
    swatch = ROOT / APP_SOURCES / "Categories/CategorySwatch.swift"
    assert swatch.exists(), "the one view that draws a category swatch is gone"

    sites = ["Feed/FeedView.swift", "Feed/TransactionDetailView.swift",
             "Categories/CategoryPicker.swift", "Settings/CategoriesSettingsView.swift"]
    for rel in sites:
        code = _code_only((ROOT / APP_SOURCES / rel).read_text(encoding="utf-8"))
        assert "CategorySwatch(" in code, f"{rel} stopped using the shared swatch"

    # And nothing else turns an index into a colour by hand. `Theme.washes
    # .count` is the allocator's business and stays allowed — what is banned is
    # reaching a Color out of the palette anywhere but the one view that draws
    # one.
    for path in (ROOT / APP_SOURCES).rglob("*.swift"):
        rel = path.relative_to(ROOT / APP_SOURCES).as_posix()
        if rel in {"Theme.swift", "Categories/CategorySwatch.swift"}:
            continue
        code = _code_only(path.read_text(encoding="utf-8"))
        for reach in ("Theme.wash(", "Theme.washes["):
            assert reach not in code, (
                f"{rel} reaches a colour out of the palette instead of "
                "drawing a CategorySwatch"
            )


def test_the_category_palette_has_a_wash_for_every_seeded_category():
    """Board #57's first acceptance criterion, at the data level.

    Nineteen categories ship. A palette shorter than that makes two of them
    share a colour on a fresh install however good the allocator is — which is
    the exact defect the card was raised for, so it is worth catching in the
    seed rather than only in a Swift test the seed cannot see.
    """
    seed = json.loads((ROOT / "ios/MonitorFinance/Resources/reference.json")
                      .read_text(encoding="utf-8"))
    theme = _code_only((ROOT / APP_SOURCES / "Theme.swift").read_text(encoding="utf-8"))
    washes = theme.split("static let washes: [Color] = [")[1].split("]")[0]
    count = washes.count("Color(red:")
    assert count >= len(seed["categories"]), (
        f"{count} washes for {len(seed['categories'])} seeded categories — "
        "two of them would share one on a fresh install"
    )


def test_the_colour_a_category_wears_is_written_down_and_not_recomputed():
    """Board #57. Allocation happens once, at load, and is persisted.

    Recomputing on every launch looks equivalent and is not: allocation is
    alphabetical, so creating a category that sorts above an existing one would
    shuffle the colour of everything below it. The migration therefore writes
    straight through `repository.save` rather than through the debounced
    `persist()` — a 300 ms timer means a launch-then-force-quit comes back to a
    different set of colours.
    """
    code = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text(encoding="utf-8"))
    assert "assigningMissingTintIndexes" in code
    migration = code.split("let tinted = Self.assigningMissingTintIndexes(categories)")[1][:400]
    assert 'repository.save(categories, as: "categories")' in migration, (
        "the migration does not write through, so the colours are recomputed "
        "on every launch"
    )
    assert "persist()" not in migration, (
        "the migration leans on the 300 ms debounce, which a force quit outruns"
    )


def test_every_seeded_category_ships_an_icon_the_app_offers():
    """Board #61's first criterion, and the coupling that makes it fragile.

    The seeded icons are written in `scripts/build_ios_seed.py` — reference.json
    is generated, and `test_rebuild_reproduces_the_committed_seed` compares it
    byte-for-byte, so an icon hand-edited into the JSON survives exactly until
    the next rebuild. The offered set lives in Swift. Nothing but this guard
    connects the two, and the failure mode is silent: `Image(systemName:)` draws
    NOTHING for a name it cannot resolve, so a category simply loses its icon.
    """
    seed = json.loads(REFERENCE.read_text(encoding="utf-8"))
    categories = seed["categories"]

    missing = [c["name"] for c in categories if not c.get("icon")]
    assert not missing, f"these ship without an icon: {missing}"

    icons = [c["icon"] for c in categories]
    assert len(set(icons)) == len(icons), (
        "two seeded categories wear the same icon, which carries no more "
        "information than their names already did"
    )

    swift = _code_only((ROOT / APP_SOURCES / "Categories/CategoryIcon.swift")
                       .read_text(encoding="utf-8"))
    offered = set(re.findall(r'"([a-z][a-z0-9.]+)"', swift))
    unreachable = sorted(set(icons) - offered)
    assert not unreachable, (
        f"these ship on a category but the chooser does not offer them, so "
        f"nobody could ever choose them back: {unreachable}"
    )


def test_the_icon_on_a_swatch_does_not_follow_the_colour_scheme():
    """Board #61. The washes are one set for both appearances (board #58's
    decision), so what is drawn ON them must be fixed too.

    `Theme.ink` inverts to near-white in the dark scheme. Near-white on a pale
    wash is not a dark-mode icon, it is a missing one — and it would look
    perfect in every light-mode screenshot. `CategoryWashTests` measures every
    wash at 4.5:1 against `Theme.swatchInk` specifically; this guard is what
    keeps the drawing code pointed at the colour that was measured.
    """
    swatch = _code_only((ROOT / APP_SOURCES / "Categories/CategorySwatch.swift")
                        .read_text(encoding="utf-8"))
    assert "Theme.swatchInk" in swatch, "the icon is no longer drawn in the measured ink"
    assert "Theme.ink" not in swatch.replace("Theme.swatchInk", ""), (
        "the swatch icon follows the colour scheme, so it disappears on dark"
    )


def test_a_category_with_no_icon_still_renders():
    """Board #61's third criterion, held at the one place that can hold it.

    Every category on every phone today has `icon: nil` — the field is new.
    The fallback belongs on the model, not at the four draw sites, because a
    draw site that forgot would render a blank swatch and nothing would say so.
    """
    models = _code_only((ROOT / APP_SOURCES / "Models/Models.swift").read_text("utf-8"))
    assert "var iconName: String { icon ?? CategoryIcon.fallback }" in models, (
        "the nil-icon fallback moved off the model, where every reader gets it"
    )
    for rel in ["Categories/CategorySwatch.swift", "Store/AppStore.swift"]:
        code = _code_only((ROOT / APP_SOURCES / rel).read_text(encoding="utf-8"))
        assert ".icon ??" not in code and "icon ?? \"" not in code, (
            f"{rel} spells the fallback out again instead of reading iconName"
        )


def test_the_store_refuses_an_icon_the_app_does_not_offer():
    """Board #61. An unresolvable symbol name draws nothing, silently.

    The chooser cannot produce one; a restored file, a hand edit, or a build
    with a longer offered list can. `setIcon` is the last place that can say no
    while somebody is still watching, so the membership check is not optional
    politeness — deleting it turns a bad string into a permanently blank
    swatch.
    """
    code = _code_only((ROOT / APP_SOURCES / "Store/AppStore.swift").read_text("utf-8"))
    body = code.split("func setIcon(")[1][:400]
    assert "CategoryIcon.offered.contains(icon)" in body, (
        "setIcon accepts any string, including one that draws nothing"
    )


def test_a_settled_amount_rebuilds_the_splits_that_described_the_old_one():
    """Board #80. `ingestRows` merges a re-fetched row over a stored one.

    Every field it writes is bank-owned; `splits` is not one of them and is
    deliberately left alone — except that a settled amount makes the existing
    splits describe a purchase that no longer exists. `Derived.byProductGroup`
    sums the splits and `Derived.byCategory` sums the amount, so the two halves
    of Статистика then disagree by the settlement difference, silently.

    The guard is on the ORDER as much as the call: the resplit reads the
    transaction back out of the array, so it has to run after every bank-owned
    field has landed, not beside the amount write.
    """
    sync = _code_only((ROOT / APP_SOURCES / "Store/AppStore+Sync.swift").read_text("utf-8"))
    merge = sync.split("if let i = index[row.id] {")[1].split("} else {")[0]

    assert "resplitAfterSettlement(at: i)" in merge, (
        "a settled hold keeps splits describing the amount it was authorised for"
    )
    assert "amountSettledAtANewFigure" in merge, "the resplit is unconditional"
    wrote_amount = merge.index("transactions[i].amount = row.amount")
    assert wrote_amount < merge.index("resplitAfterSettlement"), (
        "the resplit runs before the settled amount is written, so it rebuilds "
        "from the old figure"
    )
    # It must be the LAST thing, after every other bank-owned write.
    tail = merge[merge.index("resplitAfterSettlement"):]
    assert "transactions[i]." not in tail.replace("transactions[i].splits", ""), (
        "a bank-owned field is written after the resplit, which therefore saw "
        "a half-updated row"
    )


def test_the_split_remainder_is_a_line_and_not_a_rescaling():
    """Board #80. The settlement difference becomes its own split.

    Scaling the item amounts to fit the new total would satisfy the sum and
    invent prices nobody paid — into the one structure that holds what a
    receipt actually said. `SplitMath.build` already had the right answer: a
    «Не деталізовано» line for whatever the items do not account for.
    """
    splits = _code_only((ROOT / APP_SOURCES / "Store/AppStore+Splits.swift").read_text("utf-8"))
    body = splits.split("func resplitAfterSettlement(at index: Int) {")[1].split("\n    }")[0]
    assert "SplitMath.build" in body, "the resplit does its own arithmetic"
    for invented in ("* ", "/ ", "Double("):
        assert invented not in body, (
            f"the resplit looks like it rescales item amounts ({invented!r})"
        )


def test_a_receipt_that_no_longer_fits_is_said_so_without_being_asked():
    """Board #80's second criterion: whatever happens must be visible.

    A hold settling BELOW its receipt's own items leaves no honest split, so
    the arithmetic is dropped. `ReceiptItemsView`'s refusal message used to
    appear only as the answer to pressing «Підтвердити», which was fine while
    the only way to reach a mismatch was to cause one. A sync creates one while
    nobody is looking.
    """
    view = _code_only((ROOT / APP_SOURCES / "Receipts/ReceiptItemsView.swift").read_text("utf-8"))
    assert "standingMismatch" in view, "the mismatch is only visible after a tap"
    # The DECISION belongs to the store, not the view. As a private computed
    # property here it was unreachable from any test, and a mutation making it
    # fire on every receipt — «Чек більший за покупку на 0,00 ₴» under all of
    # them — passed the whole suite.
    assert "store.splitMismatch(forReceipt:" in view, (
        "the view derives the mismatch itself again, where no test can reach it"
    )
    assert "SplitMath.build" not in view, "the view is doing the store's arithmetic"
    assert "refusal ?? standingMismatch" in view, (
        "the tap's own answer no longer takes precedence over the standing one"
    )
    # One wording for both paths, or the two drift.
    assert view.count("не можемо розподілити") == 1, (
        "the refusal copy is written twice and can drift between the two paths"
    )
