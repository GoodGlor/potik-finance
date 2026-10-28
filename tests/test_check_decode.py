"""The reference decoder, pinned to one real (scrubbed) fiscal document.

Golden numbers, not shapes: a parser that returns plausible-looking output for
every input is the failure mode worth guarding, and only exact values catch it.
"""

import base64
import importlib.util
import json
import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "tests" / "fixtures" / "fiscal_check_fuel.json"
FIXTURES_DIR = ROOT / "tests" / "fixtures"

# The seven real receipts (S1-S7), one per vendor's register, and what each
# one's own footer says. Receipt 4 is the only one whose lines fall short of
# the footer (S5) — every other receipt's lines total it exactly, receipt 1
# only because the NI-less discount fallback (S3) is applied.
GOLDEN = {
    1: {"lines": 5, "total": 126400, "exact": True},
    2: {"lines": 1, "total": 6800, "exact": True},
    3: {"lines": 1, "total": 79923, "exact": True},
    4: {"lines": 12, "total": 124050, "exact": False},
    5: {"lines": 1, "total": 99987, "exact": True},
    6: {"lines": 5, "total": 49056, "exact": True},
    7: {"lines": 3, "total": 61207, "exact": True},
}


def _decoder():
    spec = importlib.util.spec_from_file_location(
        "check_decode", ROOT / "scripts" / "check_decode.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def _load_seven(n: int) -> dict:
    return json.loads((FIXTURES_DIR / f"fiscal_check_{n}.json").read_text(encoding="utf-8"))


def test_the_fuel_receipt_decodes_to_one_line_net_of_its_discount():
    check_decode = _decoder()
    out = check_decode.parse_check(load())

    assert out["schema_version"] == "ND-74"
    assert out["fiscal_total"] == 79923
    assert out["mac"] == "ABoAAAddAAAAABYAEwdiAAOWwXRxIIB2lGgd9+w="
    assert len(out["lines"]) == 1

    line = out["lines"][0]
    # The document-wide ordinal, NOT an item index: four vendor and loyalty
    # lines took 1-4 before the first real line.
    assert line["ordinal"] == 5
    assert line["qty_milli"] == 10530
    assert line["gross_sum"] == 80976
    assert line["discount"] == 1053
    # 809.76 - 10.53 = 799.23, which is the receipt's own total.
    assert line["net_sum"] == 79923
    # And the unit price follows the money: 799.23 / 10.530 l = 75.90/l,
    # exactly the 1.00/l the receipt itself printed as its discount, off a
    # 76.90 pump price.
    assert line["net_unit_price"] == 7590


def test_the_parser_drops_every_free_text_line():
    """The loyalty card number is an <L> line, alongside a dozen lines of
    loyalty balance. None of it is a product and none of it may become one:
    the reference decoder must never fold `<L>` text into a line's `name`."""
    check_decode = _decoder()
    payload = load()
    xml = base64.b64decode(payload["checkXml"]).decode("cp1251")
    free_text = [t.strip() for t in re.findall(r"<L[^>]*>([^<]*)</L>", xml) if t.strip()]
    assert len(free_text) >= 5, (
        "the fixture must actually contain free text, or this proves nothing"
    )

    names = " ".join(l["name"] for l in check_decode.parse_check(payload)["lines"])
    assert names.strip(), "no line names parsed — the negative assertions below would be vacuous"
    for text in free_text:
        assert text not in names


def test_the_lines_never_out_total_the_receipt():
    check_decode = _decoder()
    out = check_decode.parse_check(load())
    assert sum(l["net_sum"] for l in out["lines"]) <= out["fiscal_total"]


def _doubled_discount_payload(gross_sum: int, discount_each: int) -> dict:
    """Mirrors `CheckXMLFixtures.doubledDiscount` in
    `ios/MonitorFinanceTests/CheckXMLTests.swift`: one goods line followed by
    two NI-less `<D>` elements. S3's fallback joins both onto the same
    preceding line, so with `discount_each` more than half of `gross_sum`
    the combined discount drives that line's own `net_sum` negative."""
    xml = (
        '<?xml version="1.0" encoding="windows-1251"?><RQ NDv="ND-74"><DAT><C T="0">'
        f'<PP N="1" NM="Тестова позиція" Q="1000" SM="{gross_sum}"></PP>'
        f'<D N="2" SM="{discount_each}" TR="0" TX="0" TY="0"></D>'
        f'<D N="3" SM="{discount_each}" TR="0" TX="0" TY="0"></D>'
        '<E FN="0" N="4" NO="0" SM="0" TS="20260101000000"></E></C></DAT>'
        "<MAC>TEST</MAC></RQ>"
    )
    return {"checkXml": base64.b64encode(xml.encode("cp1251")).decode("ascii")}


def test_a_lines_discount_driving_its_sum_negative_is_refused():
    """Python mirror of `CheckXMLTests.testALinesDiscountDrivingItsSumNegativeIsRefused`
    (Swift) — pins `scripts/check_decode.py:160-161`'s `if net < 0` guard,
    which none of the eight pinned fixtures exercises (none has a negative
    line), so nothing else in this suite reddens if it is deleted."""
    check_decode = _decoder()
    payload = _doubled_discount_payload(gross_sum=100_00, discount_each=60_00)
    with pytest.raises(check_decode.Malformed):
        check_decode.parse_check(payload)


def test_a_missing_or_errored_body_is_refused_rather_than_half_parsed():
    check_decode = _decoder()
    for body in [
        {"error": "Помилка", "error_description": "Інформація відсутня Не знайдено."},
        {"checkXml": ""},
        {},
    ]:
        try:
            check_decode.parse_check(body)
        except check_decode.NotPublished:
            continue
        raise AssertionError(f"must refuse: {body}")


def test_the_request_asks_for_the_minute_and_never_the_second():
    check_decode = _decoder()

    params = check_decode.request_params(
        doc_no="777777", register_no="9999999999",
        # Naive-in-spirit: request_params only ever formats these fields with
        # strftime, never converts by offset, so the zone is attached purely
        # to satisfy DTZ001 and does not change the output.
        when=datetime(2026, 1, 1, 0, 0, 52, tzinfo=ZoneInfo("Europe/Kyiv")),
        total="799.23",
    )
    # The QR truncates to the minute and the API matches on it. A fiscal
    # time with non-zero seconds sends only the minute; sending seconds
    # returns "not found" for a receipt that exists.
    assert params["date"] == "2026-01-01 00:00:00"
    assert params["type"] == 3
    assert params["id"] == "777777"
    assert params["fn"] == "9999999999"
    assert params["sm"] == "799.23"
    # Only the receipt's own fields are sent.
    assert "captcha" not in params


# --- Seven receipts, six vendors (S1-S7) ------------------------------------


def test_all_seven_receipts_decode_to_their_own_golden_counts_and_totals():
    """Golden numbers, not shapes, same discipline as the single fuel
    receipt above — for all seven real captures at once."""
    check_decode = _decoder()
    for n, expected in GOLDEN.items():
        out = check_decode.parse_check(_load_seven(n))
        assert len(out["lines"]) == expected["lines"], n
        assert out["fiscal_total"] == expected["total"], n
        lines_sum = sum(line["net_sum"] for line in out["lines"])
        if expected["exact"]:
            assert lines_sum == expected["total"], n
        else:
            # Receipt 4 (S5): lines under-total the footer by exactly
            # 209.87 UAH (20987 minor units) — named, not just "<=".
            assert lines_sum < expected["total"], n
            assert expected["total"] - lines_sum == 20987, n


def test_receipt_one_proves_the_ni_less_discount_fallback():
    """S3: none of receipt 1's discounts carry `NI`. Without joining them to
    the nearest preceding goods element in document order, this receipt's
    lines out-total its own footer and the whole document is refused."""
    check_decode = _decoder()
    out = check_decode.parse_check(_load_seven(1))
    assert len(out["lines"]) == 5
    # Gross 3104.00, discounts 1840.00, net 1264.00 — the receipt's own total.
    assert sum(line["gross_sum"] for line in out["lines"]) == 310400
    assert sum(line["discount"] for line in out["lines"]) == 184000
    assert sum(line["net_sum"] for line in out["lines"]) == out["fiscal_total"] == 126400


def test_receipt_two_survives_a_literal_newline_in_the_goods_name():
    """S6: receipt 2's `NM` contains a literal newline — product names are
    not single-line, and decoding must not choke on it or truncate the line.
    `.strip()` only trims the ends, so the newline is expected to survive
    inside the name; the receipt must still decode to exactly one line."""
    check_decode = _decoder()
    out = check_decode.parse_check(_load_seven(2))
    assert len(out["lines"]) == 1
    assert out["fiscal_total"] == 6800
    assert "\n" in out["lines"][0]["name"]
    assert out["lines"][0]["net_sum"] == 6800


def test_goods_read_from_either_p_or_pp():
    """S1: a parser that reads only `<PP>` returns nothing for five of the
    seven receipts — every shop but the two fuel stations (receipts 3, 5,
    both `<PP>`; the rest are `<P>`). Both are read, so every receipt yields
    at least one line."""
    check_decode = _decoder()
    for n in GOLDEN:
        out = check_decode.parse_check(_load_seven(n))
        assert len(out["lines"]) > 0, n


def test_goods_without_q_default_to_one_unit():
    """S2: most of receipt 1's, 4's and 6's goods elements carry only `C`,
    `NM`, `SM`, `TX` — no `Q`. Absent `Q` means one unit (1000 milli-units),
    and the unit price then equals the line's own net sum. A minority of
    lines in receipts 4 and 6 DO carry an explicit `Q` (sold by weight) and
    must keep it rather than being defaulted."""
    check_decode = _decoder()
    # All five of receipt 1's lines lack Q.
    out = check_decode.parse_check(_load_seven(1))
    for line in out["lines"]:
        assert line["qty_milli"] == 1000, line["ordinal"]
        assert line["net_unit_price"] == line["net_sum"], line["ordinal"]

    # Receipt 4: ordinals 12 and 15 carry an explicit Q; every other line
    # does not and must default to one unit.
    out = check_decode.parse_check(_load_seven(4))
    explicit = {line["ordinal"]: line["qty_milli"] for line in out["lines"]}
    assert explicit[12] == 2000
    assert explicit[15] == 2000
    for line in out["lines"]:
        if line["ordinal"] not in (12, 15):
            assert line["qty_milli"] == 1000, line["ordinal"]

    # Receipt 6: only the produce sold by weight (ordinal 6) carries Q.
    out = check_decode.parse_check(_load_seven(6))
    explicit = {line["ordinal"]: line["qty_milli"] for line in out["lines"]}
    assert explicit[6] == 5764
    for line in out["lines"]:
        if line["ordinal"] != 6:
            assert line["qty_milli"] == 1000, line["ordinal"]


def test_the_unit_price_is_decimal_and_rounds_half_up_not_bankers():
    """None of the seven real receipts' own numbers happen to fall on a
    rounding boundary, so a `float` implementation passes every golden-value
    test above unnoticed. This is the case that tells the two apart."""
    check_decode = _decoder()
    # 65.81 over 2 units is 32.905 exactly: Decimal ROUND_HALF_UP says 3291,
    # float + round() says 3290 (banker's rounding to even).
    assert check_decode._unit_price(6581, 2000) == 3291


# --- Step 1: the fetch path goes to exactly one host (S7) -------------------


def test_the_real_endpoint_is_allowed():
    check_decode = _decoder()
    check_decode._check_host("https://cabinet.tax.gov.ua/ws/api_public/rro/chkAllWeb")


def test_the_host_comparison_is_case_insensitive():
    """`.hostname` lowercases; a refactor to `.netloc` (which does not) would
    start silently refusing the real endpoint whenever a URL arrives
    upper-cased. Pinned here so that regression fails loudly instead."""
    check_decode = _decoder()
    check_decode._check_host("https://CABINET.TAX.GOV.UA/ws/api_public/rro/chkAllWeb")


def test_a_third_party_host_is_refused():
    check_decode = _decoder()
    with pytest.raises(check_decode.HostNotAllowed):
        check_decode._check_host("http://evil.example.com/ws/api_public/rro/chkAllWeb")


def test_a_lookalike_host_is_refused():
    check_decode = _decoder()
    with pytest.raises(check_decode.HostNotAllowed):
        check_decode._check_host("https://cabinet.tax.gov.ua.evil.com/")


def test_a_userinfo_trick_is_refused():
    """`"cabinet.tax.gov.ua" in url` would pass this — the real host is
    whatever follows the `@`. `.hostname` is what makes the check safe."""
    check_decode = _decoder()
    with pytest.raises(check_decode.HostNotAllowed):
        check_decode._check_host("https://cabinet.tax.gov.ua@evil.com/")


def test_a_scheme_change_is_refused():
    """Same host, downgraded scheme — a substring check would pass this,
    since the allowed host is still sitting right there in the string."""
    check_decode = _decoder()
    with pytest.raises(check_decode.HostNotAllowed):
        check_decode._check_host("http://cabinet.tax.gov.ua/ws/api_public/rro/chkAllWeb")
