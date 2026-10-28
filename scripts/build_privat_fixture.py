"""Build the PrivatBank-import test fixtures. Invented data only —
tests/test_ios_seed.py scans Swift sources for real merchant names.

    uv run python scripts/build_privat_fixture.py

Deterministic: same script -> byte-identical outputs.
"""
from __future__ import annotations

import base64
import io
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "ios" / "MonitorFinanceTests" / "Fixtures"
GENERATED = ROOT / "ios" / "MonitorFinanceTests" / "Generated"
APP_IMPORT = ROOT / "ios" / "MonitorFinance" / "Import"
STAMP = (2026, 1, 1, 0, 0, 0)

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
RELNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKGRELNS = "http://schemas.openxmlformats.org/package/2006/relationships"
CTNS = "http://schemas.openxmlformats.org/package/2006/content-types"
PKG = "application/vnd.openxmlformats-package"
DOC = "application/vnd.openxmlformats-officedocument"

# (part name, the spreadsheetml content-type suffix that part declares)
TYPE_OVERRIDES = [
    ("/xl/workbook.xml", "sheet.main"),
    ("/xl/worksheets/sheet1.xml", "worksheet"),
    ("/xl/sharedStrings.xml", "sharedStrings"),
]

CONTENT_TYPES = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    f'<Types xmlns="{CTNS}">'
    '<Default Extension="xml" ContentType="application/xml"/>'
    f'<Default Extension="rels" ContentType="{PKG}.relationships+xml"/>'
    + "".join(
        f'<Override PartName="{part}" ContentType="{DOC}.spreadsheetml.{kind}+xml"/>'
        for part, kind in TYPE_OVERRIDES
    )
    + "</Types>"
)

ROOT_RELS = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    f'<Relationships xmlns="{PKGRELNS}">'
    f'<Relationship Id="rId1" Type="{RELNS}/officeDocument" Target="xl/workbook.xml"/>'
    "</Relationships>"
)


def workbook_xml(sheet_name):
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n<workbook xmlns="{NS}" xmlns:r="{RELNS}">'
            f'<sheets><sheet name="{sheet_name}" r:id="rId3" sheetId="1"/></sheets></workbook>')


WORKBOOK_RELS = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    f'<Relationships xmlns="{PKGRELNS}">'
    f'<Relationship Id="rId3" Type="{RELNS}/worksheet" Target="worksheets/sheet1.xml"/>'
    f'<Relationship Id="rId4" Type="{RELNS}/sharedStrings" Target="sharedStrings.xml"/>'
    "</Relationships>"
)

HEADER = ["Дата", "Категорія", "Картка", "Опис операції", "Сума в валюті картки",
          "Валюта картки", "Сума в валюті транзакції", "Валюта транзакції",
          "Залишок на кінець періоду", "Валюта залишку"]

CARD_A = "5168 **** **** 1111"
CARD_B = "5168 **** **** 2222"
CARD_USD = "4149 **** **** 3333"
UAH = "UAH"
USD = "USD"

# (date, category, card, description, amount, currency, balance, bal_currency)
SAMPLE_ROWS = [
    ("20.08.2026 18:07:59", "Тварини", CARD_A,
     "Крамниця Хвіст", "-174.5", UAH, "8885.0", UAH),
    ("19.08.2026 12:00:00", "Супермаркети та продукти", CARD_A,
     "Маркет Ромашка", "-1240.5", UAH, "9059.5", UAH),
    ("18.08.2026 09:30:00", "Зарахування", CARD_A,
     "Зарплата, ТОВ Приклад", "30000.0", UAH, "10300.0", UAH),
    ("17.08.2026 10:00:00", "Зарахування переказу", CARD_A,
     "Особа К.", "1200.0", UAH, "-19700.0", UAH),
    ("16.08.2026 14:00:00", "Переказ на свою картку", CARD_A,
     "На свою картку *2222", "-500.0", UAH, "-20900.0", UAH),
    ("16.08.2026 14:00:05", "Зарахування зі своєї картки", CARD_B,
     "Зі своєї картки *1111", "500.0", UAH, "700.0", UAH),
    ("15.08.2026 20:00:00", "Зняття готівки", CARD_A,
     "Зняття готівки в банкоматі", "-100.0", UAH, "-20400.0", UAH),
    ("14.08.2026 13:00:00", "Перекази", CARD_A,
     "Переказ на чужу картку", "-300.0", UAH, "-20300.0", UAH),
    ("13.08.2026 11:00:00", "Послуги", CARD_USD,
     "Сервіс Хмаринка", "-10.8", USD, "89.2", USD),
    ("12.08.2026 11:00:00", "Зарахування зі своєї картки", CARD_USD,
     "Зі своєї картки *1111", "100.0", USD, "100.0", USD),
    ("01.08.2026 00:00:00", "Кредити", "",
     "Списання відсотків за кредитом", "-1500.0", UAH, "-20000.0", UAH),
    ("10.08.2026 09:15:00", "Тварини", CARD_A,
     "Крамниця Хвіст", "-80.0", UAH, "-17080.0", UAH),
    ("09.08.2026 09:15:00", "Ресторани, кафе, бари", CARD_B,
     "Кафе Вечір", "-80.0", UAH, "200.0", UAH),
    ("09.08.2026 09:15:00", "Ресторани, кафе, бари", CARD_B,
     "Кафе Вечір", "-80.0", UAH, "120.0", UAH),
]


def col_letter(i):
    out = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        out = chr(65 + r) + out
    return out


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def is_number(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def sample_sheet_and_shared():
    shared, index = [], {}

    def sref(s):
        if s not in index:
            index[s] = len(shared)
            shared.append(s)
        return index[s]

    def cell(ref, value):
        if is_number(value):
            return f'<c r="{ref}"><v>{value}</v></c>'
        return f'<c r="{ref}" t="s"><v>{sref(value)}</v></c>'

    rows_xml = []
    title = "Історія операцій за період 01.08.2026 - 20.08.2026"
    rows_xml.append(f'<row r="1">{cell("A1", title)}</row>')
    hdr = "".join(cell(f"{col_letter(i)}2", h) for i, h in enumerate(HEADER))
    rows_xml.append(f'<row r="2">{hdr}</row>')
    for n, (d, cat, card, desc, amt, cur, bal, balcur) in enumerate(SAMPLE_ROWS, start=3):
        vals = [d, cat, card, desc, amt, cur, amt.lstrip("-"), cur, bal, balcur]
        cells = "".join(cell(f"{col_letter(i)}{n}", v) for i, v in enumerate(vals) if v != "")
        rows_xml.append(f'<row r="{n}">{cells}</row>')
    sheet = (f'<?xml version="1.0" encoding="UTF-8"?>\n<worksheet xmlns="{NS}">'
             f'<sheetData>{"".join(rows_xml)}</sheetData></worksheet>')
    shared_xml = (f'<?xml version="1.0" encoding="UTF-8"?>\n'
                  f'<sst xmlns="{NS}" count="{len(shared)}" uniqueCount="{len(shared)}">'
                  + "".join(f"<si><t>{esc(s)}</t></si>" for s in shared) + "</sst>")
    return sheet, shared_xml


EDGE_SHEET = (f'<?xml version="1.0" encoding="UTF-8"?>\n<worksheet xmlns="{NS}"><sheetData>'
              '<row r="1"><c r="A1" t="inlineStr"><is><t>перший</t></is></c>'
              '<c r="C1"><v>42</v></c></row>'
              '<row r="2"><c r="A2" t="s"><v>0</v></c></row>'
              '</sheetData></worksheet>')
EDGE_SHARED = (f'<?xml version="1.0" encoding="UTF-8"?>\n'
               f'<sst xmlns="{NS}" count="1" uniqueCount="1">'
               '<si><t>спільний</t></si></sst>')


def make_zip(entries, compression):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, text in entries:
            info = zipfile.ZipInfo(name, date_time=STAMP)
            z.writestr(info, text, compress_type=compression)
    return buf.getvalue()


def build():
    sheet, shared = sample_sheet_and_shared()
    sample = make_zip([
        ("[Content_Types].xml", CONTENT_TYPES),
        ("_rels/.rels", ROOT_RELS),
        ("xl/workbook.xml", workbook_xml("Виписки")),
        ("xl/_rels/workbook.xml.rels", WORKBOOK_RELS),
        ("xl/sharedStrings.xml", shared),
        ("xl/worksheets/sheet1.xml", sheet),
    ], zipfile.ZIP_DEFLATED)
    edge = make_zip([
        ("[Content_Types].xml", CONTENT_TYPES),
        ("_rels/.rels", ROOT_RELS),
        ("xl/workbook.xml", workbook_xml("Аркуш")),
        ("xl/_rels/workbook.xml.rels", WORKBOOK_RELS),
        ("xl/sharedStrings.xml", EDGE_SHARED),
        ("xl/worksheets/sheet1.xml", EDGE_SHEET),
    ], zipfile.ZIP_STORED)

    # The sample with the encryption bit raised in every local (offset 6)
    # and central (offset 8) header's general-purpose flags — a zip the
    # reader must REFUSE. Flipping bytes on the finished archive keeps it
    # structurally valid, which is the point: only the flag says no.
    encrypted = bytearray(sample)
    for sig, flag_off in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
        i = 0
        while (i := bytes(encrypted).find(sig, i)) != -1:
            encrypted[i + flag_off] |= 0x01
            i += 4

    FIXTURES.mkdir(parents=True, exist_ok=True)
    GENERATED.mkdir(parents=True, exist_ok=True)
    APP_IMPORT.mkdir(parents=True, exist_ok=True)
    (FIXTURES / "privat-sample.xlsx").write_bytes(sample)
    (FIXTURES / "edge-cases.xlsx").write_bytes(edge)

    b64s = base64.b64encode(sample).decode()
    b64e = base64.b64encode(edge).decode()
    b64x = base64.b64encode(bytes(encrypted)).decode()
    (GENERATED / "PrivatFixtureData.swift").write_text(
        "// Generated by scripts/build_privat_fixture.py — do not edit.\n"
        "// Invented data only; see the script for the row table.\n"
        "enum PrivatFixtureData {\n"
        f'    static let sampleBase64 = "{b64s}"\n'
        f'    static let edgeCasesBase64 = "{b64e}"\n'
        f'    static let encryptedBase64 = "{b64x}"\n'
        "}\n", encoding="utf-8")
    (APP_IMPORT / "PrivatStatementStub.swift").write_text(
        "#if DEBUG\n"
        "import Foundation\n\n"
        "/// The invented statement `-stubPrivatStatement` feeds past the file\n"
        "/// picker. Generated by scripts/build_privat_fixture.py — do not edit.\n"
        "/// Compiled, never bundled, so the Release-resource guards hold.\n"
        "enum PrivatStatementStub {\n"
        "    static var sampleData: Data { Data(base64Encoded: base64)! }\n\n"
        f'    private static let base64 = "{b64s}"\n'
        "}\n"
        "#endif\n", encoding="utf-8")
    print(f"fixtures -> {FIXTURES}")


if __name__ == "__main__":
    build()
