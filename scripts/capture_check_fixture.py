"""Turn real captured checks into committable fixtures.

Every NUMBER, ordinal, attribute name and element stays byte-exact — those are
what the parsers are tested on. Every NAME is replaced: the response carries
the seller's trade name and address, the cashier's surname, and the loyalty
card number printed on the receipt.

Eight raw captures are known: the original fuel receipt (`fiscal-check.local
.json`, kept as its own fixture for the existing single-receipt tests) and
seven more (`fiscal-check-1.local.json` through `-7`, one fixture each). Not
every parser reads `<M>` or `<L>`, but the fixture is scrubbed as if it were:
receipt 4's `<M>` carries a masked PAN and an acquirer RRN, and several others
carry cardholder-ish payment fields alongside it; receipt 1's `<L>` lines
carry EAN barcodes and a loyalty identifier.

Run: uv run python scripts/capture_check_fixture.py
"""
from __future__ import annotations

import base64
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATA = REPO / "data"
FIXTURES = REPO / "tests" / "fixtures"

# (raw capture, output fixture) pairs. The original fuel receipt is also
# receipt 3 of the second capture (same document, fetched twice) but keeps
# its own long-standing fixture name so the single-receipt tests are
# untouched.
CAPTURES = [(DATA / "fiscal-check.local.json", FIXTURES / "fiscal_check_fuel.json")] + [
    (DATA / f"fiscal-check-{i}.local.json", FIXTURES / f"fiscal_check_{i}.json")
    for i in range(1, 8)
]

# Attribute-valued personal data, replaced by shape-equivalent inventions.
# Not confined to goods/payment/footer elements' own attributes — a plain
# text substitution reaches an attribute wherever it sits in the tree,
# including on a CHILD element nested inside a goods line (`CA`, below).
ATTRIBUTE_SCRUBS = {
    "NDP_CSNM": "Тестовий К. .",
    # The cashier attribute on some vendors' registers: an operator code on
    # one receipt, a cashier's full real name, unmasked, on another.
    "AT_ON": "Тестовий Касир",
    # An excise stamp serial on a child `<CA CA="…"/>` of one goods line
    # (an alcohol purchase) — unique per bottle and tied to this exact
    # purchase, the same class of value as the EANs scrubbed out of `<L>`.
    "CA": "AAAA000000",
}
# The seller block and every free-text line are display-only and unread by
# both parsers, so they are replaced wholesale rather than word by word.
NMTP_REPLACEMENT = "ТОВ «ТЕСТОВА МЕРЕЖА» АЗС №00-00 м.Тест, вул. Тестова, 1"
ADRP_REPLACEMENT = "ГАРЯЧА ЛІНІЯ: 0-800-000-000"
LINE_REPLACEMENT = "Службовий рядок"

# `<M>` (payment) attributes that carry cardholder-ish data on some vendors'
# registers: a masked PAN, an acquirer RRN, a terminal id, the printed
# payment label and the card scheme name. Confined to `<M ...>` opening tags
# — none of these attribute names are used outside `<M>` in any of the eight
# captures. `SM`/`T`/`N`/`RM`/`AT_N`/`AT_SING`/`PF` are money, ordinals and
# short numeric codes and stay byte-exact, same as everywhere else.
PAYMENT_ATTRIBUTE_SCRUBS = {
    "PA": "TERM0000",
    "PB": "TERM0000",
    "PC": "ОПЛАТА",
    "PD": "0000XXXXXXXX0000",
    "PE": "000000",
    "PSNM": "CARD",
    "RRN": "000000000000",
}


# The four fields the public lookup is actually keyed on
# (`id` <- `NO`, `fn` <- `FN`, `date` <- `TS`).
# Scrubbing every human name in the document but leaving these byte-exact
# would still let anyone with this repo re-fetch the unscrubbed original —
# cashier name, masked PAN and all — straight from the tax service. Each
# becomes a same-length, same-shape invented digit run instead. A single
# digit per field (not a random value) keeps every internal repeat of the
# same real value (`DAT.FN` == `E.FN`, `DAT.DI` == `MAC.DI`, `E.TS` == the
# duplicate bare `<TS>` element) landing on the identical fake, so nothing
# half-scrubbed leaks through the other copy. `DI` is not itself a request
# parameter, but it is scrambled anyway: it is the same class of per-document
# identifier as the other three, and letting it survive stops meaning
# anything once `FN`/`NO`/`TS` are gone. `NT` (on `<MAC DI="…" NT="…">`) is
# the same class again — a per-document counter carried alongside `DI` — and
# was previously missed: on one capture the unscrubbed `NT` reproduced the
# real `DI` byte for byte, the exact half-scrubbed leak this file's own
# comment above claims cannot happen. Money, quantities, ordinals and tax
# fields are untouched — none of this is what the parsers are tested on.
LOOKUP_KEY_ATTRS = {
    "FN": "9",
    "DI": "8",
    "NO": "7",
    "TS": "6",
    "NT": "2",
}

# Not part of the public lookup key, but each re-identifies something on its
# own: `TN` is the seller's tax number — on receipt 7 it is a natural
# person's РНОКПП, whose first five digits encode that person's date of
# birth — and `ZN` is the register's own serial, which together with `TN`
# names the exact till at the exact store. `NDP_IDNP` repeats the same digit
# run as `TN`'s numeric tail on some vendors' registers. Same shape-preserving
# treatment as `LOOKUP_KEY_ATTRS`, kept in its own dict because these are not
# part of the request signature.
IDENTITY_ATTRS = {
    "TN": "5",
    "ZN": "4",
    "NDP_IDNP": "3",
}


def _fake_digits(real: str, digit: str) -> str:
    return digit * len(real)


def _scrub_attrs(text: str, attrs: dict[str, str]) -> str:
    for attr, digit in attrs.items():
        for real in set(re.findall(rf'\b{attr}="([^"]*)"', text)):
            text = text.replace(f'{attr}="{real}"', f'{attr}="{_fake_digits(real, digit)}"')
    return text


def _scrub_ndp_advr(text: str) -> str:
    """The free-text `<NDP_ADVR>` footer line repeats `NDP_IDNP`'s digits as
    plain text (`"ІД 30603572"`) rather than an attribute, on the same
    vendors that carry `NDP_IDNP` at all. Scrub the digits after an `ІД`/`ПН`
    marker the same way, wherever this element's body carries one."""

    def repl(m: re.Match) -> str:
        opening, body, closing = m.group(1), m.group(2), m.group(3)
        scrubbed_body = re.sub(
            r"(ІД|ПН)(\s+)(\d+)",
            lambda mm: f"{mm.group(1)}{mm.group(2)}{IDENTITY_ATTRS['NDP_IDNP'] * len(mm.group(3))}",
            body,
        )
        return f"{opening}{scrubbed_body}{closing}"

    return re.sub(r"(<NDP_ADVR\b[^>]*>)([^<]*)(</NDP_ADVR>)", repl, text)


def _scrub_lookup_keys(text: str) -> str:
    text = _scrub_attrs(text, LOOKUP_KEY_ATTRS)
    text = _scrub_attrs(text, IDENTITY_ATTRS)
    text = _scrub_ndp_advr(text)
    # The fiscal timestamp is also duplicated as a bare <TS>…</TS> element
    # inside <DAT>, not only as the `<E TS="…">` attribute above.
    for real in set(re.findall(r"<TS>([^<]*)</TS>", text)):
        text = text.replace(f"<TS>{real}</TS>", f"<TS>{_fake_digits(real, '6')}</TS>")
    return text


def _scrub_m_tag(m: re.Match) -> str:
    tag = m.group(0)
    for attr, replacement in PAYMENT_ATTRIBUTE_SCRUBS.items():
        tag = re.sub(rf'\b{attr}="[^"]*"', f'{attr}="{replacement}"', tag)
    return tag


def scrub(text: str) -> str:
    for attr, replacement in ATTRIBUTE_SCRUBS.items():
        # `\b` so a short name (`CA`) can never match as the tail of some
        # longer, unrelated attribute name that happens to end the same way.
        text = re.sub(rf'\b{attr}="[^"]*"', f'{attr}="{replacement}"', text)

    text = re.sub(
        r"(<NDP_NMTP\b[^>]*>)[^<]*(</NDP_NMTP>)",
        rf"\g<1>{NMTP_REPLACEMENT}\g<2>",
        text,
    )
    # The hotline number is also seller-identifying contact info, replaced
    # the same way even though it is not named in the docs' short list.
    text = re.sub(
        r"(<NDP_ADRP\b[^>]*>)[^<]*(</NDP_ADRP>)",
        rf"\g<1>{ADRP_REPLACEMENT}\g<2>",
        text,
    )

    def _scrub_line(m: re.Match) -> str:
        opening, body, closing = m.group(1), m.group(2), m.group(3)
        if not body.strip():
            return m.group(0)
        return f"{opening}{LINE_REPLACEMENT}{closing}"

    text = re.sub(r"(<L\b[^>]*>)([^<]*)(</L>)", _scrub_line, text)
    text = re.sub(r"<M\b[^>]*>", _scrub_m_tag, text)
    text = _scrub_lookup_keys(text)
    return text


def build_fixture(raw_path: Path, out_path: Path) -> None:
    if not raw_path.exists():
        print(f"skipping {out_path.name}: {raw_path} not captured")
        return

    raw = json.loads(raw_path.read_text(encoding="utf-8"))

    xml_bytes = base64.b64decode(raw["checkXml"])
    text = xml_bytes.decode("cp1251")
    scrubbed_text = scrub(text)
    scrubbed_bytes = scrubbed_text.encode("cp1251")

    fixture = {k: v for k, v in raw.items() if k not in ("check", "checkP7s")}
    fixture["checkXml"] = base64.b64encode(scrubbed_bytes).decode("ascii")
    # The top-level `fn` field is the same register number as `<DAT FN>` /
    # `<E FN>`, outside the base64 blob — fake it with the same transform so
    # it doesn't sit there byte-exact as a second copy of the real key.
    if fixture.get("fn"):
        fixture["fn"] = _fake_digits(fixture["fn"], LOOKUP_KEY_ATTRS["FN"])

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(fixture, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {out_path}")


def main() -> None:
    for raw_path, out_path in CAPTURES:
        build_fixture(raw_path, out_path)


if __name__ == "__main__":
    main()
