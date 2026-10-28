"""Reference decoder for a Ukrainian fiscal check, from the tax service's
public lookup. The Swift side is pinned against this file's answers.

Decodes the tax cabinet's public receipt response. Seven
real receipts from six register vendors are what this decoder is now proven
against — see the spec's "Second capture" section (S1-S7).
"""
from __future__ import annotations

import base64
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime
from decimal import ROUND_HALF_UP, Decimal

import httpx

ENDPOINT = "https://cabinet.tax.gov.ua/ws/api_public/rro/chkAllWeb"

# The only goods elements observed across seven receipts from six vendors
# (S1). They never co-occur in one document; both are read, in document
# order, as line items.
GOODS_TAGS = ("P", "PP")

ALLOWED_HOST = "cabinet.tax.gov.ua"


class HostNotAllowed(Exception):
    """A fetcher that follows whatever URL it is handed is one mistake from
    being someone else's tool. This one goes to exactly one host."""


class NotPublished(Exception):
    """The document is not (yet) retrievable. Errors do not use status codes:
    a wrong parameter and an unpublished receipt both return 200 with `error`,
    and nothing in the response distinguishes them."""


class Malformed(Exception):
    """A body that claims to be a check and is not."""


def _check_host(url: str) -> None:
    """Compares the PARSED hostname, never a substring: `"cabinet.tax.gov.ua"
    in url` passes `https://cabinet.tax.gov.ua@evil.com/` and would send
    receipt data to `evil.com`. `.hostname` discards userinfo, so that trick
    resolves to `evil.com`, not the allowed host. It also catches a scheme
    that drops `https`: dropping to plain `http`, or mangling the scheme
    separator (`https:cabinet.tax.gov.ua/…`, no `//`) so the parser treats
    the whole string as an opaque path — `.hostname` is `None` either way,
    never the allowed host, even though the substring is still sitting right
    there in the string."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != ALLOWED_HOST:
        raise HostNotAllowed(
            f"refusing {parsed.hostname!r} via {parsed.scheme!r}; "
            f"this fetches only https://{ALLOWED_HOST}"
        )


def fetch_check(*, doc_no: str, register_no: str, when: datetime, total: str) -> dict:
    """One GET to the tax cabinet's public receipt endpoint. The host check
    runs before the socket opens, not after the URL is built from parts that
    could have been tampered with."""
    _check_host(ENDPOINT)
    params = request_params(doc_no=doc_no, register_no=register_no, when=when, total=total)
    # `_check_host` only ever validates ENDPOINT, never wherever a redirect
    # might point. Left to httpx's default, a redirect would be followed
    # without a second host check — explicit here so a future edit to True
    # has to argue with this comment, not just flip a default.
    response = httpx.get(ENDPOINT, params=params, timeout=10, follow_redirects=False)
    response.raise_for_status()
    return response.json()


def request_params(*, doc_no: str, register_no: str, when: datetime, total: str) -> dict:
    """`when` is Kyiv wall clock from the QR. Seconds are dropped: the QR
    carries HHMM or HHMMSS, and the API matches on the minute either way."""
    return {
        "id": doc_no,
        "fn": register_no,
        "sm": total,
        "date": when.strftime("%Y-%m-%d %H:%M:00"),
        "type": 3,
    }


def parse_check(payload: dict) -> dict:
    raw = payload.get("checkXml")
    if payload.get("error") or not raw:
        raise NotPublished(payload.get("error_description", "no checkXml"))
    return parse_xml(base64.b64decode(raw))


def parse_xml(raw: bytes) -> dict:
    # The bytes are windows-1251 and the declaration says so. Decoding as
    # UTF-8 silently mangles every Cyrillic name; re-declaring after decoding
    # stops the XML parser from re-interpreting bytes that are already text.
    text = raw.decode("cp1251").replace("windows-1251", "utf-8", 1)
    root = ET.fromstring(text)

    footer = next(root.iter("E"), None)
    if footer is None or footer.get("SM") is None:
        raise Malformed("no fiscal footer")
    total = int(footer.get("SM"))

    # `NI` names a goods element's document-wide ordinal `N`, never its
    # position — join by it where present.
    discounts_by_ni: dict[int, int] = {}
    for d in root.iter("D"):
        ni, sm = d.get("NI"), d.get("SM")
        if ni is not None and sm is not None:
            discounts_by_ni[int(ni)] = discounts_by_ni.get(int(ni), 0) + int(sm)

    # A single walk of the whole document, in order: goods elements (`<P>`
    # or `<PP>`, S1) become lines keyed by their ordinal, and a `<D>` that
    # carries no `NI` (S3) joins the nearest preceding one instead.
    #
    # A `<D>` with no `NI` attribute can still carry child `<NI NI="…"/>`
    # elements (receipt 1) — examined and rejected as a source of a clean
    # pro-rata split: they are cumulative, not "which line(s) this discount
    # applies to". `D N="13"` lists NI 5 and 9, which are themselves OTHER
    # discounts' ordinals (the `<D>` elements at N=5 and N=9), not goods
    # ordinals — the list is "everything before me", not an allocation.
    # Nearest-preceding is the least-wrong rule available from what the
    # document actually offers. Receipt 1's total nets out exactly (S3), but
    # its PER-LINE discount attribution is best-effort: nothing in the
    # document distinguishes "this discount belongs to the immediately
    # preceding line" from "it was meant to spread over several", so a
    # receipt with more than one undiscounted goods element between two
    # discounts would attribute the whole thing to just the last of them.
    lines_by_ordinal: dict[int, dict] = {}
    last_ordinal: int | None = None
    for el in root.iter():
        if el.tag in GOODS_TAGS:
            ordinal = int(el.get("N", 0))
            last_ordinal = ordinal
            lines_by_ordinal[ordinal] = {
                "ordinal": ordinal,
                "name": (el.get("NM") or "").strip(),
                # Absent `Q` means one unit (S2): 1000 milli-units, not zero.
                "qty_milli": int(el.get("Q", 1000)),
                "gross_sum": int(el.get("SM", 0)),
                "discount": discounts_by_ni.get(ordinal, 0),
            }
        elif el.tag == "D":
            ni, sm = el.get("NI"), el.get("SM")
            if ni is None and sm is not None and last_ordinal is not None:
                lines_by_ordinal[last_ordinal]["discount"] += int(sm)

    lines = []
    for line in lines_by_ordinal.values():
        net = line["gross_sum"] - line["discount"]
        # Mirrors `CheckXML.parse`'s own guard (Swift): the footer check
        # below only refuses a total ABOVE the receipt, and nothing else
        # refuses a single line's discount exceeding its own gross sum. Two
        # consecutive `<D>` elements with no `NI` both accumulate onto
        # `last_ordinal`, which can drive one line's `net_sum` negative while
        # the document still under-totals its own footer.
        if net < 0:
            raise Malformed("a line's discount exceeds its own sum")
        line["net_sum"] = net
        line["net_unit_price"] = _unit_price(net, line["qty_milli"])
        lines.append(line)

    # S5: lines may total LESS than the footer (receipt 4 falls short by
    # 209.87 ₴) but never more — that would mean a discount was missed.
    if sum(l["net_sum"] for l in lines) > total:
        raise Malformed("lines out-total the receipt")

    mac = next(root.iter("MAC"), None)
    return {
        # `NDv` is the register's model/firmware, not a schema version (S4) —
        # it is absent on at least one real receipt, so it stays optional.
        # The dict key stays `schema_version` here: Step 2's scope is S1-S3,
        # and `scripts/build_ios_test_fixtures.py` (owned by the Swift-half
        # task, which also does the `registerModel` rename) reads this exact
        # key today.
        "schema_version": root.get("NDv"),
        "fiscal_total": total,
        "fiscal_time": footer.get("TS"),
        "mac": (mac.text or "").strip() if mac is not None else None,
        "lines": lines,
    }


def _unit_price(net_sum: int, qty_milli: int) -> int:
    """What the goods actually cost per unit, after the discount. Decimal, never
    float: the fuel log renders this as hryvnia-per-litre."""
    if qty_milli == 0:
        return net_sum
    qty = Decimal(qty_milli) / 1000
    return int((Decimal(net_sum) / qty).quantize(Decimal(1), rounding=ROUND_HALF_UP))
