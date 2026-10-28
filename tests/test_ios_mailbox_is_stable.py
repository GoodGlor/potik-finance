"""Board #158 — only one place in the app may end an issued address.

The owner's complaint was that the mailbox changed whenever they tidied
anything up, and the cause was a call site rather than a policy:
`BankDetailView` ran `disconnectPrivatEmail()` before
`store.disconnect(bankId:)` whenever the bank had an email source. So
"disconnect the bank" destroyed the address, and the two looked like separate
buttons.

**This is a SOURCE guard because the symptom has no reachable screen.** A
disconnected bank leaves `store.connectedBanks`, so `BanksSettingsView` stops
listing it and a UI test cannot walk back to the mailbox to find out whether it
survived — the check would have to reconnect the bank first, which is a
different feature's failure modes borrowed to test this one. What actually
went wrong was that a call existed where it should not, and that is exactly
what a source guard can say.

The rule is not "never delete an address". It is:

    the only functions allowed to end an address are the two that say so.

**Board #170 widened that set and this guard did not follow.** «Видалити
адресу назавжди» is a second deliberate ending, and it calls a store method
whose name was not in `DESTRUCTIVE` — so the guard went on passing while the
surface it guards grew. Adding a destructive store call means adding it here;
a guard that lists yesterday's calls reports on yesterday's code.
"""

import re

from tests.test_ios_seed import ROOT, _code_only

APP = ROOT / "ios" / "MonitorFinance"
DETAIL = APP / "Banks" / "BankDetailView.swift"
SYNC = APP / "Store" / "AppStore+EmailSync.swift"

#: Every store call that ends an issued address, or throws away the secret
#: that is the only way back to one. `pausePrivatEmail` is deliberately absent
#: — it destroys nothing, which is the whole point of board #158.
#: `deletePrivatEmailAddress` joined the list with board #170.
DESTRUCTIVE = ("changePrivatEmailAddress", "forgetPrivatEmail",
               "deletePrivatEmailAccount", "deletePrivatEmailAddress")

#: The functions on the screen that are ALLOWED to make those calls, because
#: each is a button whose label says it ends an address. Board #158 had one;
#: board #170 added the second.
DELIBERATE = ("private func changeAddress(force: Bool)",
              "private func deleteAddress(force: Bool)")


def _function_span(src: str, signature: str) -> tuple[int, int]:
    """The line range of a Swift function body, by brace depth.

    Crude on purpose: a real parser would be more code than the thing it
    guards, and this file's shape is pinned by `test_the_guard_can_fire`.
    """
    lines = src.splitlines()
    start = next(i for i, line in enumerate(lines) if signature in line)
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > start:
            return start, i
    raise AssertionError(f"{signature} never closes")


def test_only_the_deliberate_buttons_can_end_the_mailbox():
    src = _code_only(DETAIL.read_text(encoding="utf-8"))
    allowed: set[int] = set()
    for signature in DELIBERATE:
        start, end = _function_span(src, signature)
        allowed |= set(range(start, end + 1))

    offenders = []
    for number, line in enumerate(src.splitlines()):
        for name in DESTRUCTIVE:
            if name in line and number not in allowed:
                offenders.append(f"BankDetailView.swift:{number + 1} {line.strip()}")

    assert offenders == [], (
        "these end an issued address from outside «Змінити адресу» and "
        "«Видалити адресу назавжди», which are the only two buttons allowed "
        f"to: {offenders}. There is no route back — `POST /register` mints a "
        "NEW random address and the backend has no way to reissue an old one "
        "— so an address destroyed by a button that does not say it destroys "
        "one is gone for good, with the person's forwarding rule still "
        "pointing at it."
    )


def test_the_disconnect_does_not_reset_the_cursor():
    """A pause keeps the address, so it must keep the cursor too.

    Same address means the same rows behind it. Resetting would re-import
    every letter this phone already holds, and the person would watch a resume
    duplicate months of history for no reason they could see.
    """
    src = _code_only(SYNC.read_text(encoding="utf-8"))
    start, end = _function_span(src, "func pausePrivatEmail()")
    body = "\n".join(src.splitlines()[start:end + 1])

    assert "emailCursor" not in body, (
        "`pausePrivatEmail` touches the cursor. The address is unchanged, so "
        "the rows behind it are the same rows."
    )


def test_the_guard_can_fire():
    """A clean run above has to mean something.

    Both tests scan for the ABSENCE of a string, which is the shape of check
    that passes just as happily when it is reading the wrong file, matching
    nothing, or looking at a function whose span it computed as empty.
    """
    src = _code_only(DETAIL.read_text(encoding="utf-8"))
    for signature in DELIBERATE:
        start, end = _function_span(src, signature)
        assert end > start, f"the span walker returned an empty function for {signature}"

        body = "\n".join(src.splitlines()[start:end + 1])
        assert any(name in body for name in DESTRUCTIVE), (
            f"{signature} is exempted from the guard and does not end an "
            "address — either it was renamed, or this guard is now scanning a "
            "file where the destructive call it is looking for cannot appear "
            "at all. An exemption for a function that destroys nothing is a "
            "hole with no test behind it."
        )

    start, end = _function_span(src, DELIBERATE[0])

    # And the span really does exclude the rest of the file: the bank
    # disconnect, which is the call site this card removed, sits outside it.
    assert re.search(r"store\.disconnect\(bankId:", src), "the bank disconnect moved"
    bank_line = next(i for i, line in enumerate(src.splitlines())
                     if "store.disconnect(bankId:" in line)
    assert not (start <= bank_line <= end), (
        "the bank disconnect is inside the span the guard exempts, so the "
        "guard would pass no matter what that code did"
    )
