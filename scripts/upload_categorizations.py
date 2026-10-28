"""Push the app's categorization log into the Google Sheet.

The phone writes an append-only JSONL (board card #5, Debug builds only); this
reads it and appends the new lines to a sheet. Temporary, for the testing
phase: the point is to accumulate real "what arrived → how it was
categorized" pairs so a base categorizer can later be trained on them.

**Why this runs on the machine and not in the app.** A Google credential —
service account key or OAuth refresh token — inside an iOS binary is
extractable by anyone holding the .app, and the credential in use here also
carries a Gmail scope from another project. So no Google credential ever goes
near the phone: the phone writes a file, this pushes the file. The webhook
path (`docs/categorization-sheet.gs`) exists for the same reason — there, the
only thing the app holds is a URL.

Nothing here is committed but the code. The spreadsheet id and both
credential paths come from the environment or the command line, because an id
written into a repository outlives every later decision to keep it private.

Run — a service account (board #146, the mode the owner chose):

    export MF_SHEET_ID=...                  # from the spreadsheet URL
    export MF_GOOGLE_SERVICE_ACCOUNT=...    # the service account key json

    uv run python scripts/upload_categorizations.py --device   # a real iPhone
    uv run python scripts/upload_categorizations.py            # booted simulator

**Share the spreadsheet with the key's `client_email` as an Editor.** A
service account is a stranger to a document until it is invited, and Google
answers an uninvited one with a bare 403 — which is why this script names the
address in that error instead of re-printing the status code.

Or the original OAuth flow, still supported:

    export MF_GOOGLE_CREDENTIALS=...  # the OAuth client json
    export MF_GOOGLE_TOKEN=...        # where the refreshable token lives
    uv run python scripts/upload_categorizations.py --file x.jsonl --all

`--device` copies the phone's log into `~/.cache/monitorfinance/device-logs/`
and works from there. That path is STABLE on purpose: the upload cursor is
keyed on the file's location, so a temp directory would re-upload the whole
log on every run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path

import httpx
import jwt

BUNDLE_ID = "ua.monitorfinance.app"
API = "https://sheets.googleapis.com/v4/spreadsheets"

# The tab the owner set aside for this. Overridable, because the tab name is
# the one piece of the destination that is not secret and does change.
DEFAULT_TAB = "Swift"

# Product groups from scanned receipts land in their own tab. A receipt item's
# group is what was BOUGHT; a transaction's category is where the money WENT.
# The app keeps those namespaces apart everywhere, and one shared sheet would
# be an invitation to join them and quietly poison both training sets.
DEFAULT_PRODUCT_TAB = "Swift — товари"

# The event exactly as the app encodes it, then this script's own clock.
# `uploadedAt` is what makes a delivery gap visible: a run of rows whose `at`
# marches on while `uploadedAt` does not means the phone was writing its file
# and nobody was pushing it.
COLUMNS = [
    "at",
    "source",
    "choice",
    "category",
    "merchant",
    "merchantKey",
    "mcc",
    "originalMcc",
    "sign",
    "bankId",
    "bankSuggestion",
    "was",
    "kind",
    "uploadedAt",
]

PRODUCT_COLUMNS = [
    "at",
    "source",
    "name",
    "guessed",
    "chosen",
    "agreed",
    "seller",
    "uploadedAt",
]


def parse_events(text: str) -> list[dict]:
    """One JSON object per line.

    A trailing partial line is skipped rather than raising: the file is being
    appended to by a running app, and a read that lands mid-write must not
    lose the 500 good lines above it.
    """
    events = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def row_for(event: dict, uploaded_at: str, columns: list[str] | None = None) -> list:
    """Fixed column order, and absent means empty.

    `mcc`, `category` and `bankSuggestion` are legitimately absent — a literal
    "None" in a cell would have to be cleaned out of every later query.
    """
    out = []
    for column in columns or COLUMNS:
        if column == "uploadedAt":
            out.append(uploaded_at)
            continue
        value = event.get(column)
        out.append("" if value is None else value)
    return out


def product_log_path(source: Path) -> Path:
    """The product-group log beside the spending one."""
    return source.with_name("product-groups.jsonl")


def simulator_log_path() -> Path | None:
    """The JSONL inside the booted simulator's app container, if there is one.

    None rather than an exception on every way this can be absent — no
    simulator booted, the app not installed, `xcrun` unable to find `simctl`
    because DEVELOPER_DIR is unset. Preparing the sheet does not need a
    simulator, and a traceback for "nothing to upload yet" is noise.
    """
    try:
        found = subprocess.run(
            ["xcrun", "simctl", "get_app_container", "booted", BUNDLE_ID, "data"],
            capture_output=True, text=True, check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    container = found.stdout.strip()
    if not container:
        return None
    return Path(container) / "Library/Application Support/MonitorFinance/categorization.jsonl"


#: A service account can be given exactly this and nothing else. The OAuth
#: client this script started with is recorded above as carrying a Gmail scope
#: from another project; narrowing the credential is half the point of board
#: #146, so the scope is named here rather than inherited from a consent screen.
SHEETS_SCOPE = "https://www.googleapis.com/auth/spreadsheets"

GOOGLE_TOKEN_URI = "https://oauth2.googleapis.com/token"


def service_account_token(key_file: Path) -> tuple[str, str]:
    """Sign a JWT with the service account's key and trade it for a token.

    Returns the token AND the account's email, because the email is what the
    spreadsheet has to be shared with — and a 403 that does not name it sends
    people to the wrong place. See `sheets_failure_hint`.

    Unlike the refresh-token flow above, this needs no consent screen and no
    seven-day expiry: the key file IS the credential, so it stays on the
    machine like every other one, and never goes near the phone.
    """
    key = json.loads(key_file.read_text(encoding="utf-8"))
    if key.get("type") != "service_account":
        raise SystemExit(
            f"{key_file} is not a service account key (its \"type\" is "
            f"{key.get('type')!r}). Download the JSON key from the service "
            "account itself, not the OAuth client."
        )
    for field in ("client_email", "private_key"):
        if not key.get(field):
            raise SystemExit(f"{key_file} has no {field}")

    audience = key.get("token_uri", GOOGLE_TOKEN_URI)
    issued = int(time.time())
    assertion = jwt.encode(
        {
            "iss": key["client_email"],
            "scope": SHEETS_SCOPE,
            "aud": audience,
            "iat": issued,
            # An hour is Google's maximum for this grant; the script runs for
            # seconds, so nothing here needs refreshing mid-run.
            "exp": issued + 3600,
        },
        key["private_key"],
        algorithm="RS256",
    )
    response = httpx.post(
        audience,
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        },
        timeout=30,
    )
    if response.status_code != 200:
        raise SystemExit(
            f"service account sign-in failed ({response.status_code}): {response.text}\n"
            "If this says invalid_grant, check the machine's clock — a JWT is "
            "signed against it."
        )
    return response.json()["access_token"], key["client_email"]


def sheets_failure_hint(error: httpx.HTTPStatusError, account: str | None) -> str:
    """The one mistake everybody makes with a service account, said out loud.

    A service account is a stranger to the spreadsheet until it is invited.
    Google answers that with a bare 403, which reads like a broken credential
    and sends people back to re-download a key that was always fine.
    """
    status = error.response.status_code
    if status == 403 and account:
        return (
            f"\nGoogle refused access (403). A service account has no rights to a "
            f"spreadsheet by default:\n  share the sheet with  {account}  as an "
            "Editor, then run this again."
        )
    if status == 404:
        return "\nNo spreadsheet with that id — check MF_SHEET_ID against the URL."
    return ""


#: Where a phone's logs are copied to. **Stable, and deliberately not a temp
#: directory**: `read_cursor` keys on the absolute path, so a fresh
#: `mkdtemp()` per run would reset the cursor every time and re-upload the
#: whole log on every run — silently, since duplicates in a sheet look like
#: data rather than like a bug.
DEVICE_CACHE = Path.home() / ".cache" / "monitorfinance" / "device-logs"

CONTAINER_SUBPATH = "Library/Application Support/MonitorFinance"


def device_log_path(device: str, cache: Path | None = None) -> Path | None:
    """Copy the app's logs off a connected iPhone; return the local JSONL.

    Both files are pulled into one directory so `product_log_path`'s "the
    sibling beside it" keeps working unchanged — the rest of this script never
    learns that the source was a phone.

    A device that answers nothing is not an error for the same reason an
    absent simulator is not: preparing the tabs does not need a phone.
    """
    destination = (cache or DEVICE_CACHE) / device
    destination.mkdir(parents=True, exist_ok=True)

    copied = False
    for name in ("categorization.jsonl", "product-groups.jsonl"):
        if _copy_from_device(device, f"{CONTAINER_SUBPATH}/{name}", destination / name):
            copied = True
    if not copied:
        return None
    return destination / "categorization.jsonl"


#: Where the service account key lives — OUTSIDE this repository, and that is
#: not an inconvenience to be tidied away later. `tests/test_upload_
#: categorizations.py::test_no_google_credential_is_committed_anywhere` walks
#: the whole working tree, so a key anywhere under the project fails the suite
#: whatever `.gitignore` says. The guard is right: this repo has already had a
#: real key reach git history once, and history is the part you cannot redact.
DEFAULT_SERVICE_ACCOUNT = Path.home() / ".config" / "monitorfinance" / "service-account.json"


def default_service_account() -> Path | None:
    """The key to use when nobody names one.

    `MF_GOOGLE_SERVICE_ACCOUNT` still wins; the default only exists so the
    ordinary run is `--device` and nothing else. Returns None when there is no
    key, so the older refresh-token flow stays reachable on a machine that
    never had one.
    """
    if named := os.environ.get("MF_GOOGLE_SERVICE_ACCOUNT"):
        return Path(named)
    return DEFAULT_SERVICE_ACCOUNT if DEFAULT_SERVICE_ACCOUNT.exists() else None


def sole_device() -> str:
    """The one connected iPhone's identifier, or an error naming the choice.

    Asked for by `--device` with no value. Refusing to pick when there are two
    is the point: this repo's owner has two phones paired, and guessing would
    upload one person's spending history under the other's.
    """
    with tempfile.TemporaryDirectory() as work:
        report = Path(work) / "devices.json"
        try:
            subprocess.run(
                ["xcrun", "devicectl", "list", "devices", "--json-output", str(report)],
                capture_output=True, text=True, check=True,
            )
        except FileNotFoundError:
            raise SystemExit("xcrun not found — set DEVELOPER_DIR") from None
        except subprocess.CalledProcessError as failed:
            raise SystemExit(f"could not list devices: {failed.stderr.strip()}") from None
        found = json.loads(report.read_text(encoding="utf-8"))

    devices = [
        (d.get("identifier", ""), d.get("deviceProperties", {}).get("name", "?"))
        for d in found.get("result", {}).get("devices", [])
    ]
    if not devices:
        raise SystemExit("no devices are paired with this Mac")
    if len(devices) > 1:
        listed = "\n".join(f"  {ident}  {name}" for ident, name in devices)
        raise SystemExit(f"more than one device is paired — name one:\n{listed}")
    return devices[0][0]


def _copy_from_device(device: str, source: str, destination: Path) -> bool:
    """One `devicectl` copy. False when the file is simply not there yet.

    `devicectl` writes the file INTO the destination when handed a directory
    and fails on a path whose parent it cannot see, so the parent is made
    first and the destination named explicitly.
    """
    try:
        done = subprocess.run(
            [
                "xcrun", "devicectl", "device", "copy", "from",
                "--device", device,
                "--domain-type", "appDataContainer",
                "--domain-identifier", BUNDLE_ID,
                "--source", source,
                "--destination", str(destination),
            ],
            capture_output=True, text=True, check=True,
        )
    except FileNotFoundError:
        raise SystemExit(
            "xcrun not found — set DEVELOPER_DIR, e.g.\n"
            "  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
        ) from None
    except subprocess.CalledProcessError as failed:
        text = (failed.stderr or "") + (failed.stdout or "")
        # A phone that is listed but locked resets the connection rather than
        # refusing cleanly, and the message says nothing about the screen —
        # measured on 2026-08-30, twice, before anyone thought to unlock it.
        if "could not be established" in text or "Connection reset" in text:
            raise SystemExit(
                f"could not reach device {device}: unlock it and connect over USB.\n"
                "`xcrun devicectl list devices` can call a locked phone "
                "\"available\" and still fail to open a channel."
            ) from None
        return False
    return done.returncode == 0


def access_token(credentials: Path, token: Path) -> str:
    """Exchange the stored refresh token for an access token.

    Hand-rolled over `httpx` rather than pulling in `google-auth`: it is one
    POST, and this repo already hand-rolls an xlsx reader to avoid a
    dependency. Nothing about the credential is printed, here or anywhere.
    """
    client = json.loads(credentials.read_text(encoding="utf-8"))
    client = client.get("installed") or client.get("web") or client
    stored = json.loads(token.read_text(encoding="utf-8"))
    if "refresh_token" not in stored:
        raise SystemExit(f"{token} holds no refresh_token — re-run your Google consent flow")

    response = httpx.post(
        stored.get("token_uri", "https://oauth2.googleapis.com/token"),
        data={
            "client_id": client["client_id"],
            "client_secret": client["client_secret"],
            "refresh_token": stored["refresh_token"],
            "grant_type": "refresh_token",
        },
        timeout=30,
    )
    if response.status_code != 200:
        # The body names the cause — `invalid_grant` means the refresh token
        # was revoked or expired (a Google project still in "Testing" expires
        # them in seven days), and the only fix is a fresh consent.
        raise SystemExit(
            f"token refresh failed ({response.status_code}): {response.text}\n"
            "If this says invalid_grant, re-authorise the Google project and "
            "replace the token file."
        )
    return response.json()["access_token"]


def ensure_tab(sheet_id: str, tab: str, columns: list[str], headers: dict) -> None:
    """Create the tab and its header row if the sheet has neither."""
    meta = httpx.get(
        f"{API}/{sheet_id}", params={"fields": "sheets.properties.title"},
        headers=headers, timeout=30,
    )
    meta.raise_for_status()
    titles = [s["properties"]["title"] for s in meta.json().get("sheets", [])]
    if tab not in titles:
        add = httpx.post(
            f"{API}/{sheet_id}:batchUpdate",
            json={"requests": [{"addSheet": {"properties": {"title": tab}}}]},
            headers=headers, timeout=30,
        )
        add.raise_for_status()

    first = httpx.get(
        f"{API}/{sheet_id}/values/{tab}!A1:{chr(ord('A') + len(columns) - 1)}1",
        headers=headers, timeout=30,
    )
    first.raise_for_status()
    if not first.json().get("values"):
        written = httpx.put(
            f"{API}/{sheet_id}/values/{tab}!A1",
            params={"valueInputOption": "RAW"},
            json={"values": [columns]},
            headers=headers, timeout=30,
        )
        written.raise_for_status()


def append(sheet_id: str, tab: str, rows: list[list], headers: dict) -> int:
    response = httpx.post(
        f"{API}/{sheet_id}/values/{tab}!A1:append",
        params={"valueInputOption": "RAW", "insertDataOption": "INSERT_ROWS"},
        json={"values": rows},
        headers=headers, timeout=60,
    )
    response.raise_for_status()
    return response.json().get("updates", {}).get("updatedRows", 0)


def fingerprint(text: str) -> str:
    """Identifies the log a cursor was counted against (board #152).

    The first line of an append-only file never changes while it is the same
    file, and every event carries a timestamp — so a log that was cleared and
    grew again has a different first line, and the count taken against the old
    one has to be thrown away rather than used as an offset into the new one.

    The first NON-BLANK line, because that is what `parse_events` counts as
    event zero; a leading blank would otherwise make two identical logs look
    different and re-upload everything.
    """
    first = next((line for line in text.splitlines() if line.strip()), "")
    return hashlib.sha256(first.encode("utf-8")).hexdigest()[:16]


def read_cursor(state: Path, source: Path, fingerprint: str) -> tuple[int, int | None]:
    """How many lines of this file have already gone up, and what was discarded.

    A cursor, not a dedupe-by-content pass: the log is append-only, so the
    count is exact and a re-run costs one number rather than a full read of
    the sheet. `--all` ignores it.

    Returns `(already, reset_from)`. `reset_from` is the count that was thrown
    away because it belonged to a different log — the caller must SAY so.
    Board #152: a silent reset re-uploads duplicates, which is a different
    failure wearing the same silence as the one this fixes.

    An entry written before fingerprints existed is a bare int. It is trusted:
    its count is real, and resetting on the strength of a missing field would
    duplicate every row already in the sheet. `main`'s length floor is the only
    guard such an entry gets, and the next write upgrades it in place.
    """
    if not state.exists():
        return 0, None
    entry = json.loads(state.read_text(encoding="utf-8")).get(str(source), 0)
    if isinstance(entry, int):
        return entry, None
    if entry.get("fingerprint") != fingerprint:
        return 0, entry.get("lines", 0)
    return entry.get("lines", 0), None


def write_cursor(state: Path, source: Path, lines: int, fingerprint: str) -> None:
    data = json.loads(state.read_text(encoding="utf-8")) if state.exists() else {}
    data[str(source)] = {"lines": lines, "fingerprint": fingerprint}
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps(data, indent=2), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, help="the JSONL (default: the booted simulator's)")
    parser.add_argument("--device", nargs="?", const="", default=None,
                        help="read from a connected iPhone instead of a simulator; "
                             "takes a device id, or none to use the only one connected")
    parser.add_argument("--sheet-id", default=os.environ.get("MF_SHEET_ID", ""))
    parser.add_argument("--service-account", type=Path, default=default_service_account(),
                        help="a service account key json; the spreadsheet must be "
                             "shared with its client_email")
    parser.add_argument("--credentials", type=Path,
                        default=Path(os.environ.get("MF_GOOGLE_CREDENTIALS", "")))
    parser.add_argument("--token", type=Path,
                        default=Path(os.environ.get("MF_GOOGLE_TOKEN", "")))
    parser.add_argument("--state", type=Path, default=Path(".categorization-upload.json"),
                        help="where the per-file cursor is kept")
    parser.add_argument("--tab", default=os.environ.get("MF_SHEET_TAB", DEFAULT_TAB))
    parser.add_argument("--product-tab",
                        default=os.environ.get("MF_SHEET_PRODUCT_TAB", DEFAULT_PRODUCT_TAB))
    parser.add_argument("--all", action="store_true", help="re-upload every line")
    parser.add_argument("--dry-run", action="store_true", help="say what would go up")
    args = parser.parse_args(argv)

    if not args.sheet_id:
        raise SystemExit("no spreadsheet id — set MF_SHEET_ID or pass --sheet-id")

    if args.file:
        source = args.file
    elif args.device is not None:
        source = device_log_path(args.device or sole_device())
    else:
        source = simulator_log_path()
    # A missing log is not an error: running this before anything has been
    # categorized is how the tabs and their headers get created, and doing that
    # first means the sheet is ready before the first real row exists.
    channels = []
    if source is not None:
        channels = [
            (source, args.tab, COLUMNS),
            (product_log_path(source), args.product_tab, PRODUCT_COLUMNS),
        ]

    pending = []
    for path, tab, columns in channels:
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        events = parse_events(text)
        mark = fingerprint(text)
        already, reset_from = (0, None) if args.all else read_cursor(args.state, path, mark)
        # The floor, and the only guard a pre-fingerprint entry gets: a count
        # larger than the file cannot be a count OF this file. It catches the
        # shrink case alone, which is why it is a fallback and not the fix.
        if already > len(events):
            already, reset_from = 0, already
        if reset_from is not None:
            print(f"{path.name}: this is not the log those {reset_from} lines came "
                  f"from — the cursor resets, sending it from the first line")
        fresh = events[already:]
        print(f"{len(events)} in {path.name}, {len(fresh)} new → «{tab}»")
        pending.append((path, tab, columns, events, fresh, mark))
    if not channels:
        print("no log found")
    if args.dry_run:
        return 0

    account = None
    if args.service_account:
        token, account = service_account_token(args.service_account)
    else:
        token = access_token(args.credentials, args.token)
    headers = {"Authorization": f"Bearer {token}"}

    try:
        # Both tabs are prepared even when only one has rows: a header that only
        # appears once data arrives is a sheet that looks broken until it is not.
        for tab, columns in ((args.tab, COLUMNS), (args.product_tab, PRODUCT_COLUMNS)):
            ensure_tab(args.sheet_id, tab, columns, headers)

        uploaded_at = datetime.now(UTC).isoformat(timespec="seconds")
        total = 0
        for path, tab, columns, events, fresh, mark in pending:
            if not fresh:
                continue
            rows = [row_for(e, uploaded_at, columns) for e in fresh]
            total += append(args.sheet_id, tab, rows, headers)
            # Written per channel as it lands, not once at the end: if the
            # product tab fails after the spending tab succeeded, the rows
            # already in the sheet must not come back on the next run.
            write_cursor(args.state, path, len(events), mark)
    except httpx.HTTPStatusError as refused:
        raise SystemExit(
            f"Google refused the request ({refused.response.status_code})."
            + sheets_failure_hint(refused, account)
        ) from None
    print(f"appended {total} rows" if total else "both tabs are ready; nothing new to send")
    return 0


if __name__ == "__main__":
    sys.exit(main())
