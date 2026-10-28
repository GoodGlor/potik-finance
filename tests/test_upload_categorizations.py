"""The Sheets uploader, and the two schemas that have to agree with it.

Nothing here talks to Google: the network half is three `httpx` calls and a
token exchange, and what is worth pinning is the shape of what they carry.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SWIFT_LOG = ROOT / "ios/MonitorFinance/Debug/CategorizationLog.swift"
APPS_SCRIPT = ROOT / "docs/categorization-sheet.gs"


def _uploader():
    spec = importlib.util.spec_from_file_location(
        "upload_categorizations", ROOT / "scripts" / "upload_categorizations.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def uploader():
    return _uploader()


def _swift_fields(struct: str) -> list[str]:
    """A struct's stored properties, in order. `static let`s and `var`s with a
    default that is not part of the payload are excluded by the `var name:`
    shape itself."""
    text = SWIFT_LOG.read_text(encoding="utf-8")
    body = text.split(f"struct {struct}: Codable, Hashable {{", 1)[1].split("\n}", 1)[0]
    return re.findall(r"^\s{4}var (\w+)", body, re.MULTILINE)


def _swift_event_fields() -> list[str]:
    return _swift_fields("CategorizationEvent")


def test_the_columns_are_the_swift_event_plus_one_clock(uploader):
    """A column dropped on this side is a column of training data silently
    thrown away, and nothing else would notice: the app would keep writing the
    field, the upload would keep succeeding, and the sheet would be short a
    column nobody looks for until the categorizer is being trained."""
    fields = _swift_event_fields()
    assert fields, "no fields parsed — this guard would pass vacuously"
    assert uploader.COLUMNS[:-1] == fields
    assert uploader.COLUMNS[-1] == "uploadedAt", "the pusher's own clock goes last"


def test_the_apps_script_agrees_with_the_same_schema():
    """The two delivery paths must not drift apart: a row that arrived by
    webhook and one that arrived by upload have to line up in the same sheet,
    column for column."""
    text = APPS_SCRIPT.read_text(encoding="utf-8")
    listed = re.search(r"const COLUMNS = \[(.*?)\];", text, re.DOTALL)
    assert listed, "no COLUMNS array found in the Apps Script"
    columns = re.findall(r"'([A-Za-z]+)'", listed.group(1))
    assert columns[:-1] == _swift_event_fields()
    assert columns[-1] == "receivedAt", "the script's own clock goes last"


def test_the_apps_script_refuses_a_sheet_whose_header_is_out_of_date():
    """Board #56 inserted `originalMcc` in the MIDDLE of the column list, and
    the script writes rows by position into whatever sheet already exists. An
    older header means every value from `sign` rightwards silently lands under
    the wrong heading — training data that is wrong in a way no later query
    can detect.

    A source guard, and honest about being one: nothing here executes Apps
    Script, so this asserts the check is present and reachable, not that
    Google runs it. The check is inside `sheetForAppending`, after the
    empty-sheet branch returns, which is the only path an existing sheet takes.
    """
    text = APPS_SCRIPT.read_text(encoding="utf-8")
    body = re.search(
        r"function sheetForAppending\(name, columns\) \{(.*?)\n\}", text, re.DOTALL
    )
    assert body, "sheetForAppending is gone or was renamed"
    guarded = body.group(1)
    assert "getRange(1, 1, 1, sheet.getLastColumn())" in guarded, (
        "the existing header is never read, so a mismatch cannot be noticed"
    )
    assert "throw new Error(" in guarded, (
        "a mismatch must fail loudly rather than append into the wrong columns"
    )
    # The empty-sheet branch must still return before the check, or a brand
    # new sheet would throw against the header it just wrote.
    assert guarded.index("setFrozenRows(1)") < guarded.index("throw new Error(")


def test_both_paths_write_into_the_same_tab(uploader):
    text = APPS_SCRIPT.read_text(encoding="utf-8")
    named = re.search(r"const SHEET_NAME = '([^']+)';", text)
    assert named
    assert named.group(1) == uploader.DEFAULT_TAB


def test_a_partial_trailing_line_is_skipped_not_fatal(uploader):
    """The app appends while this reads. Losing the 500 good lines above a
    half-written one would be the worst possible response to a race that
    resolves itself a millisecond later."""
    good = json.dumps({"merchant": "Маркет-Приклад"})
    events = uploader.parse_events(f"{good}\n{good}\n{{\"merchant\": \"Кра")
    assert len(events) == 2
    assert all(e["merchant"] == "Маркет-Приклад" for e in events)


def test_blank_lines_are_not_events(uploader):
    assert uploader.parse_events("\n\n   \n") == []


def test_a_row_follows_the_column_order_and_leaves_absences_empty(uploader):
    """`mcc`, `category` and `bankSuggestion` are legitimately absent. A cell
    reading "None" would have to be cleaned out of every later query."""
    row = uploader.row_for(
        {"at": "2026-08-26T10:00:00Z", "source": "queueConfirm", "choice": "ownTransfer",
         "merchant": "Маркет-Приклад", "merchantKey": "маркет-приклад", "sign": "out",
         "bankId": "monobank", "was": "pending", "kind": "expense"},
        "2026-08-26T11:00:00+00:00",
    )
    assert len(row) == len(uploader.COLUMNS)
    by_name = dict(zip(uploader.COLUMNS, row, strict=True))
    assert by_name["merchant"] == "Маркет-Приклад"
    assert by_name["category"] == "", "absent, not the string None"
    assert by_name["mcc"] == ""
    assert by_name["bankSuggestion"] == ""
    assert by_name["uploadedAt"] == "2026-08-26T11:00:00+00:00"


def test_the_cursor_is_per_file_and_survives_a_reread(uploader, tmp_path):
    state = tmp_path / "state.json"
    first, second = tmp_path / "a.jsonl", tmp_path / "b.jsonl"
    assert uploader.read_cursor(state, first, "aaaa") == (0, None)

    uploader.write_cursor(state, first, 12, "aaaa")
    uploader.write_cursor(state, second, 3, "bbbb")
    assert uploader.read_cursor(state, first, "aaaa") == (12, None)
    assert uploader.read_cursor(state, second, "bbbb") == (3, None), \
        "two logs must not share one cursor"


# --- board #152: the cursor is a count, so it has to name the file it counted ---

def _log(path: Path, first: int, count: int) -> None:
    """`count` events, each distinguishable, starting at ordinal `first`.

    The ordinal stands in for the timestamp every real event carries: what
    matters is that a log which was cleared and grew again does not open with
    the same line it opened with before.
    """
    path.write_text(
        "".join(
            json.dumps({"at": f"2026-08-31T10:00:{n:02d}Z", "merchant": f"Крамниця-{n}"}) + "\n"
            for n in range(first, first + count)
        ),
        encoding="utf-8",
    )


def _run(uploader, tmp_path, log: Path) -> tuple[int, str]:
    """One `--dry-run` upload; returns how many lines it would send, and its output.

    Driven through `main` rather than through `read_cursor` directly, because
    the defect this pins was never in the cursor's arithmetic — it was in what
    `main` did with the number.
    """
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        uploader.main(["--file", str(log), "--state", str(tmp_path / "state.json"),
                       "--sheet-id", "sheet-not-contacted", "--dry-run"])
    printed = out.getvalue()
    said = re.search(rf"in {re.escape(log.name)}, (\d+) new", printed)
    assert said, f"the run said nothing about {log.name}: {printed!r}"
    return int(said.group(1)), printed


def _pretend_uploaded(uploader, tmp_path, log: Path) -> None:
    """What a successful run leaves behind: the cursor at the file's full length."""
    text = log.read_text(encoding="utf-8")
    uploader.write_cursor(tmp_path / "state.json", log, len(uploader.parse_events(text)),
                          uploader.fingerprint(text))


def test_a_cleared_log_does_not_have_its_first_rows_sliced_away(uploader, tmp_path):
    """The 50-lost case, exactly as reproduced on the card.

    50 uploaded, «Очистити журнал» (or a reinstall) empties the file, 60 fresh
    categorizations accumulate. Reading the cursor as an offset into the new
    file sends 10 and loses 50 — rows nobody ever gets back, because the phone
    is the only place they existed.
    """
    log = tmp_path / "categorization.jsonl"
    _log(log, first=0, count=50)
    _pretend_uploaded(uploader, tmp_path, log)

    _log(log, first=100, count=60)          # cleared, then grew again
    new, printed = _run(uploader, tmp_path, log)

    assert new == 60, "50 never-uploaded categorizations were sliced away"
    assert "cursor resets" in printed, "a silent reset is the same failure over again"


def test_a_regrown_log_shorter_than_the_cursor_is_not_reported_as_nothing_to_do(
        uploader, tmp_path):
    """The dangerous variant: fewer new entries than the old count.

    `events[50:]` over 30 entries is empty, so the run printed its ordinary
    `nothing new to send` and exited 0. A run that lost everything looked
    exactly like a run with nothing to do — which is why this case gets its own
    test rather than trusting the one above to cover it.
    """
    log = tmp_path / "categorization.jsonl"
    _log(log, first=0, count=50)
    _pretend_uploaded(uploader, tmp_path, log)

    _log(log, first=100, count=30)
    new, printed = _run(uploader, tmp_path, log)

    assert new == 30
    assert "nothing new to send" not in printed


def test_an_ordinary_append_still_sends_only_what_is_new(uploader, tmp_path):
    """The fix must not turn every run into a full re-upload.

    Without this, «reset whenever unsure» would pass both tests above and
    duplicate the whole log on every run — a failure the sheet, not the phone,
    would be left holding.
    """
    log = tmp_path / "categorization.jsonl"
    _log(log, first=0, count=50)
    _pretend_uploaded(uploader, tmp_path, log)

    _log(log, first=0, count=58)            # same file, eight more lines
    new, printed = _run(uploader, tmp_path, log)

    assert new == 8
    assert "cursor resets" not in printed


def test_a_cursor_written_before_fingerprints_is_trusted_not_discarded(uploader, tmp_path):
    """The upgrade path, and it matters once: the owner's own state file.

    It holds a bare `1270` against a log whose 1270 rows are already in the
    sheet. Treating a missing fingerprint as a mismatch would append every one
    of them a second time — so a legacy entry keeps its count, and the next
    write upgrades it in place.
    """
    log = tmp_path / "categorization.jsonl"
    _log(log, first=0, count=50)
    state = tmp_path / "state.json"
    state.write_text(json.dumps({str(log): 50}), encoding="utf-8")

    new, printed = _run(uploader, tmp_path, log)
    assert new == 0
    assert "cursor resets" not in printed


def test_the_length_floor_catches_a_shrunken_legacy_cursor(uploader, tmp_path):
    """A legacy entry has no fingerprint, so the count is all there is to check.

    `already > len(events)` is the one thing still provable about it, and it
    covers the case that loses data. It is a floor, not the fix.
    """
    log = tmp_path / "categorization.jsonl"
    _log(log, first=100, count=30)
    state = tmp_path / "state.json"
    state.write_text(json.dumps({str(log): 50}), encoding="utf-8")

    new, printed = _run(uploader, tmp_path, log)
    assert new == 30
    assert "cursor resets" in printed


def test_the_fingerprint_ignores_a_leading_blank_line(uploader):
    """`parse_events` skips blanks, so the fingerprint must too — otherwise a
    stray newline at the top of the file reads as a different log and
    re-uploads all of it."""
    body = json.dumps({"merchant": "Крамниця-1"}) + "\n"
    assert uploader.fingerprint(body) == uploader.fingerprint("\n  \n" + body)


def test_no_google_credential_is_committed_anywhere():
    """The credentials live outside this repository and stay there.

    Scoped to JSON files so the uploader's own source — which names these keys
    as dictionary lookups — is not mistaken for a leaked key.
    """
    secrets = ("private_key", "refresh_token", "client_secret")
    offenders = []
    for path in ROOT.rglob("*.json"):
        if any(part in {".venv", "node_modules", ".git", ".worktrees"} for part in path.parts):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if any(f'"{key}"' in text for key in secrets):
            offenders.append(path.relative_to(ROOT).as_posix())
    assert offenders == [], f"credential-shaped json in the repo: {offenders}"


def test_the_product_columns_are_the_swift_product_event_plus_one_clock(uploader):
    """The same pin as the spending columns, one namespace over."""
    fields = _swift_fields("ProductGroupEvent")
    assert fields, "no fields parsed — this guard would pass vacuously"
    # `type` is the routing marker, not data anyone charts; it does not earn a
    # column, and the tab it selects already says what it says.
    payload = [f for f in fields if f != "type"]
    assert uploader.PRODUCT_COLUMNS[:-1] == payload
    assert uploader.PRODUCT_COLUMNS[-1] == "uploadedAt"


def test_the_apps_script_routes_products_to_their_own_tab(uploader):
    """Two destinations, and neither may quietly become the other."""
    text = APPS_SCRIPT.read_text(encoding="utf-8")
    listed = re.search(r"const PRODUCT_COLUMNS = \[(.*?)\];", text, re.DOTALL)
    assert listed, "no PRODUCT_COLUMNS array in the Apps Script"
    columns = re.findall(r"'([A-Za-z]+)'", listed.group(1))
    assert columns[:-1] == uploader.PRODUCT_COLUMNS[:-1]
    assert columns[-1] == "receivedAt"

    named = re.search(r"const PRODUCTS_SHEET_NAME = '([^']+)';", text)
    assert named
    assert named.group(1) == uploader.DEFAULT_PRODUCT_TAB

    # Routed on an explicit marker, never on which keys happen to be present.
    assert "event.type === 'productGroup'" in text


def test_the_two_destinations_are_not_the_same_tab(uploader):
    assert uploader.DEFAULT_TAB != uploader.DEFAULT_PRODUCT_TAB


def test_the_product_log_sits_beside_the_spending_one(uploader, tmp_path):
    source = tmp_path / "categorization.jsonl"
    assert uploader.product_log_path(source) == tmp_path / "product-groups.jsonl"


def test_a_product_row_follows_its_own_column_order(uploader):
    row = uploader.row_for(
        {"at": "2026-08-26T10:00:00Z", "source": "receiptItem", "type": "productGroup",
         "name": "Хліб український", "guessed": "Інше", "chosen": "Хлібобулочні",
         "agreed": False, "seller": "Крамниця Приклад"},
        "2026-08-26T11:00:00+00:00",
        uploader.PRODUCT_COLUMNS,
    )
    by_name = dict(zip(uploader.PRODUCT_COLUMNS, row, strict=True))
    assert by_name["name"] == "Хліб український"
    assert by_name["guessed"] == "Інше"
    assert by_name["agreed"] is False
    assert by_name["uploadedAt"] == "2026-08-26T11:00:00+00:00"
    assert "type" not in by_name, "the routing marker is not a column"


# --------------------------------------------------- board #146: the two new modes


def test_a_service_account_key_is_told_apart_from_an_oauth_client(uploader, tmp_path):
    """The two json files look alike and are downloaded from the same console.

    Handing over the OAuth client where a service account belongs produces a
    signature failure from Google that names neither file, so the check is
    here where it can name one.
    """
    client = tmp_path / "client.json"
    client.write_text(json.dumps({"installed": {"client_id": "x", "client_secret": "y"}}))
    with pytest.raises(SystemExit) as refused:
        uploader.service_account_token(client)
    assert "not a service account" in str(refused.value)


def test_the_service_account_scope_is_sheets_and_only_sheets(uploader):
    """Half of why board #146 moved to a service account.

    The OAuth client this script started with carries a Gmail scope from
    another project — recorded in the script's own docstring. Widening this
    back to a broader scope would hand a spreadsheet uploader reach over
    somebody's mail.
    """
    assert uploader.SHEETS_SCOPE == "https://www.googleapis.com/auth/spreadsheets"


def test_an_uninvited_service_account_is_told_to_share_the_sheet(uploader):
    """Google answers an uninvited service account with a bare 403.

    That reads like a broken key, and sends people back to re-download one
    that was always fine. The address to share with has to be in the message.
    """
    import httpx

    refused = httpx.HTTPStatusError(
        "403", request=httpx.Request("GET", "https://sheets.googleapis.com"),
        response=httpx.Response(403),
    )
    hint = uploader.sheets_failure_hint(refused, "potik@example.iam.gserviceaccount.com")
    assert "potik@example.iam.gserviceaccount.com" in hint
    assert "share" in hint.lower()

    missing = httpx.HTTPStatusError(
        "404", request=httpx.Request("GET", "https://sheets.googleapis.com"),
        response=httpx.Response(404),
    )
    assert "MF_SHEET_ID" in uploader.sheets_failure_hint(missing, None)


def test_the_device_cache_is_stable_so_the_cursor_survives_a_second_run(uploader, tmp_path,
                                                                       monkeypatch):
    """**The bug this design avoids, stated as a test.**

    `read_cursor` keys on the file's absolute path. A `mkdtemp()` per run
    would therefore look like a brand-new log every time and re-upload the
    whole thing — silently, because duplicated rows in a sheet read as data
    rather than as a fault. Two pulls of the same device must land on the
    same path.
    """
    calls = []

    def fake_copy(device, source, destination):
        calls.append(source)
        destination.write_text("{}\n", encoding="utf-8")
        return True

    monkeypatch.setattr(uploader, "_copy_from_device", fake_copy)
    first = uploader.device_log_path("UDID-1", cache=tmp_path)
    second = uploader.device_log_path("UDID-1", cache=tmp_path)
    assert first == second, "the same phone must resolve to the same path every run"
    assert uploader.product_log_path(first).exists(), "the product log rides along"
    assert first.name == "categorization.jsonl"


def test_two_phones_do_not_share_one_log(uploader, tmp_path, monkeypatch):
    """Two devices are paired with this machine. Merging their logs would file
    one person's spending under the other's."""
    monkeypatch.setattr(uploader, "_copy_from_device",
                        lambda device, source, destination: destination.write_text("{}\n") or True)
    assert (uploader.device_log_path("UDID-1", cache=tmp_path)
            != uploader.device_log_path("UDID-2", cache=tmp_path))


def test_a_device_with_no_log_yet_is_not_an_error(uploader, tmp_path, monkeypatch):
    """The log is off by default in the app, so "no file yet" is the ordinary
    state of a phone nobody has switched it on for — and preparing the tabs
    does not need one."""
    monkeypatch.setattr(uploader, "_copy_from_device",
                        lambda device, source, destination: False)
    assert uploader.device_log_path("UDID-1", cache=tmp_path) is None


def test_the_named_key_beats_the_default_one(uploader, tmp_path, monkeypatch):
    """`MF_GOOGLE_SERVICE_ACCOUNT` has to win, or a machine with a key in the
    default place could never be pointed at a different one."""
    named = tmp_path / "other.json"
    named.write_text("{}")
    monkeypatch.setenv("MF_GOOGLE_SERVICE_ACCOUNT", str(named))
    assert uploader.default_service_account() == named

    monkeypatch.delenv("MF_GOOGLE_SERVICE_ACCOUNT")
    monkeypatch.setattr(uploader, "DEFAULT_SERVICE_ACCOUNT", tmp_path / "absent.json")
    assert uploader.default_service_account() is None, (
        "no key must leave the older refresh-token flow reachable"
    )


def test_the_service_account_key_lives_outside_this_repository(uploader):
    """Board #146's location decision, pinned where a later tidy-up will see it.

    `test_no_google_credential_is_committed_anywhere` walks the working tree,
    so a key moved under the project fails the suite whatever `.gitignore`
    says. This asserts the default never points inside the repo in the first
    place.
    """
    default = uploader.DEFAULT_SERVICE_ACCOUNT.resolve()
    assert not default.is_relative_to(ROOT), f"{default} is inside the repository"
