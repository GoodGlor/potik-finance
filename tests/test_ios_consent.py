"""Board #113 — an irreversible act starts from a tap, never from a screen.

`PrivatEmailSetupView` registered the device in `.onAppear`, so merely opening
the screen minted a server account: «I didn't add the mail, I just clicked done,
and the mail is already tied» described the code exactly. Three things make that
class of call irreversible — the backend shows the secret once, the account then
collects a person's mail, and it spends one of five registrations an hour.

The Swift half (`EmailConsentTests`) tests the RULE: what the screen shows on
arrival. This is the rule about SOURCE, which no test running inside the app can
see — that no view's appear-hook reaches for one of these calls again. A
behaviour test proves today's screen is right; this proves tomorrow's is.
"""

import re

from tests.test_ios_seed import ROOT, _code_only

APP = ROOT / "ios/MonitorFinance"

#: Store calls that cannot be undone by tapping back. Each either creates or
#: destroys something that outlives the view — a server account, or the only
#: copy of a secret. Adding to this list is how the guard grows.
IRREVERSIBLE = (
    "registerPrivatEmail",
    "disconnectPrivatEmail",
    "forgetPrivatEmail",
)

#: `.onAppear {`, `.task {`, `.task(id:` — every hook SwiftUI runs because a
#: view came on screen rather than because a person acted.
APPEAR_HOOK = re.compile(r"\.(onAppear|task)\s*(\(|\{)")

#: A method declared in the same file, which a hook body can name. Only these
#: are followed: the guard resolves indirection WITHIN one view, which is where
#: it hides, and stops rather than pretending to know the whole app.
LOCAL_FUNC = re.compile(r"\bfunc\s+(\w+)\s*\(")

#: `foo()` / `foo(` — a call by name in a body.
CALL = re.compile(r"\b(\w+)\s*\(")


def _block(src: str, at: int, what: str) -> str:
    """The brace-matched block whose `{` is at or after `at`.

    Brace-counted rather than regex-matched: a Swift body is full of nested
    closures and the first `}` on its own line ends nothing reliably. Literals
    are not stripped, so a `{` inside a string would miscount — which is why an
    unbalanced read raises instead of returning a short block that would silently
    hide whatever came after it.
    """
    start = src.find("{", at)
    if start < 0:
        return ""
    depth, i = 0, start
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start : i + 1]
        i += 1
    raise AssertionError(f"an unbalanced `{what}` body — the guard cannot read this file")


def _functions(src: str) -> dict[str, str]:
    return {m.group(1): _block(src, m.end(), m.group(1)) for m in LOCAL_FUNC.finditer(src)}


def _reaches(body: str, functions: dict[str, str]) -> str | None:
    """The irreversible call this body reaches, directly or through a local
    function, or `None`.

    **The indirection is the whole point.** The defect this file guards did not
    put `registerPrivatEmail` inside `.onAppear`; it put `prepare()` there, and
    `prepare()` registered. A scanner that only read the hook body reported the
    screen clean — measured against pre-fix `main`, which is the only way that
    was ever going to surface.
    """
    seen: set[str] = set()
    queue = [body]
    while queue:
        current = queue.pop()
        for call in IRREVERSIBLE:
            if call in current:
                return call
        for name in set(CALL.findall(current)):
            if name in functions and name not in seen:
                seen.add(name)
                queue.append(functions[name])
    return None


def _offenders(sources) -> list[str]:
    found = []
    for path in sources:
        # `is_relative_to`, because the can-fire control feeds this scanner
        # files from a tmp directory — a bare `relative_to` raises there, and a
        # control that errors instead of asserting proves nothing.
        name = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path.name
        src = _code_only(path.read_text("utf-8"))
        if not APPEAR_HOOK.search(src):
            continue
        functions = _functions(src)
        for hook in APPEAR_HOOK.finditer(src):
            body = _block(src, hook.end() - 1, hook.group(1))
            call = _reaches(body, functions)
            if call:
                found.append(f"{name}: .{hook.group(1)} reaches {call}")
    return found


def test_no_screen_creates_or_destroys_an_account_by_appearing():
    """The card, as a rule about every view rather than about one.

    A person who opens a screen and taps back must owe nothing for it. The one
    place this was false is the one the owner found; nothing says a second
    screen cannot repeat it, and the failure is silent — the account exists, the
    letters start arriving, and the screen that made it looks like a page of
    instructions.
    """
    offenders = _offenders(sorted(APP.rglob("*.swift")))
    assert not offenders, (
        "an irreversible account call runs on appear; it belongs behind a tap:\n  "
        + "\n  ".join(offenders)
    )


def test_the_guard_above_can_actually_fire(tmp_path):
    """A guard nobody has watched fail is a guard nobody has tested.

    Three halves, and the middle one is the guard's whole reason to exist.
    """
    direct = tmp_path / "Direct.swift"
    direct.write_text(
        "var body: some View {\n"
        '    Text("hi")\n'
        "        .onAppear {\n"
        "            Task { await store.registerPrivatEmail() }\n"
        "        }\n"
        "}\n",
        "utf-8",
    )
    assert _offenders([direct]), "the scanner cannot see inside an appear hook"

    # **The shape the defect actually had.** The first version of this guard
    # read only the hook body, passed against pre-fix `main`, and would have
    # shipped as a detector for a defect this repo never had.
    indirect = tmp_path / "Indirect.swift"
    indirect.write_text(
        "var body: some View {\n"
        '    Text("hi")\n'
        "        .onAppear {\n"
        "            guard !didStart else { return }\n"
        "            didStart = true\n"
        "            Task { await prepare() }\n"
        "        }\n"
        "}\n"
        "private func prepare() async {\n"
        "    if store.privatEmailCredentials == nil {\n"
        "        _ = await store.registerPrivatEmail()\n"
        "    }\n"
        "}\n",
        "utf-8",
    )
    assert _offenders([indirect]), (
        "the call was one function away from the hook — that is where it hides"
    )

    # A scanner that matched anywhere in the file would call every screen with a
    # disconnect button an offender, and be exempted into uselessness in a week.
    innocent = tmp_path / "Innocent.swift"
    innocent.write_text(
        "var body: some View {\n"
        "    Button { Task { await connect() } } label: {\n"
        '        Text("Створити адресу")\n'
        "    }\n"
        "    .onAppear { Task { await load() } }\n"
        "}\n"
        "private func connect() async { _ = await store.registerPrivatEmail() }\n"
        "private func load() async { await refresh() }\n"
        "private func refresh() async { _ = try? await store.privatEmailStatus() }\n",
        "utf-8",
    )
    assert not _offenders([innocent]), (
        "the same call behind a BUTTON is the fix, not the defect"
    )


def test_the_setup_screen_still_registers_somewhere():
    """The negative above passes just as well if the call is deleted.

    Board #113 asked for the trigger to move, not for the feature to go — and a
    screen that can no longer create an address would satisfy every assertion in
    this file. This is the positive that makes the rest mean something.
    """
    src = _code_only(
        (APP / "Banks/PrivatEmailSetupView.swift").read_text("utf-8")
    )
    assert "registerPrivatEmail" in src, "the setup screen must still be able to register"
    assert 'accessibilityIdentifier("email.connect")' in src, (
        "the tap that registers must be reachable — and identifiable to a UI test"
    )
