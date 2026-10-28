"""Board #151 — every `Launch` member a Release build reads must exist there.

`Launch` is deliberately two enums in one file: a `#if DEBUG` branch that reads
real launch arguments, and a Release `#else` branch that stubs each flag as a
constant so the argument-reading path compiles out of a shipped binary.

That split has one failure mode, and it shipped. Board #107 added `showGuide`
to the DEBUG branch, gave it no Release stub, and put its call site
(`AppStore.swift`) OUTSIDE any fence — so Release failed to compile with
`type 'Launch' has no member 'showGuide'` and nothing noticed for days.

**No test running inside the app can see this**, which is why the guard lives
here: `ios/test.sh` builds Debug, so all 1290 of its tests pass against a
project that cannot be archived at all.

The rule is deliberately NOT "both branches declare the same names". Several
members are Debug-only on purpose and their call sites are properly fenced —
`emailKeyLost` (inside a `#if DEBUG` in `AppStore`) and `stubStatementDelay`
(inside `MonobankStub.swift`, a file that is `#if DEBUG` end to end). Demanding
symmetry would force meaningless stubs for those. The real rule is the one the
compiler enforces:

    a `Launch.x` reachable in Release must be declared in Release.
"""

import re

from tests.test_ios_seed import ROOT, _code_only

APP = ROOT / "ios" / "MonitorFinance"
LAUNCH = APP / "App" / "Launch.swift"

USE = re.compile(r"\bLaunch\.([A-Za-z_][A-Za-z0-9_]*)")
DECL = re.compile(r"^\s*(?:static\s+(?:var|let|func)|enum)\s+([A-Za-z_][A-Za-z0-9_]*)")


def _release_lines(src: str) -> list[tuple[int, str]]:
    """The lines a Release build compiles, with their 1-based numbers.

    Only a literal `#if DEBUG` opens a Debug-only region; any other condition
    is assumed to compile, and `#else`/`#elseif` always leave one. Both choices
    are deliberately conservative — they can only ever make this guard check
    MORE lines, never fewer, so the guard cannot go quiet by mis-reading a
    directive it has not met before.
    """
    out: list[tuple[int, str]] = []
    debug_only: list[bool] = []
    for number, line in enumerate(src.splitlines(), 1):
        bare = line.strip()
        if bare.startswith("#if"):
            debug_only.append(re.fullmatch(r"#if\s+DEBUG", bare) is not None)
        elif bare.startswith(("#else", "#elseif")):
            if debug_only:
                debug_only[-1] = False
        elif bare.startswith("#endif"):
            if debug_only:
                debug_only.pop()
        elif not any(debug_only):
            out.append((number, line))
    return out


def _declared_in_release() -> set[str]:
    src = LAUNCH.read_text(encoding="utf-8")
    return {
        match.group(1)
        for _, line in _release_lines(src)
        if (match := DECL.match(line))
    }


def test_every_launch_member_reachable_in_release_is_declared_there():
    known = _declared_in_release()
    offenders = []
    for path in sorted(APP.rglob("*.swift")):
        for number, line in _release_lines(_code_only(path.read_text(encoding="utf-8"))):
            for name in USE.findall(line):
                if name not in known:
                    offenders.append(f"{path.relative_to(ROOT).as_posix()}:{number} Launch.{name}")
    assert offenders == [], (
        "these compile in Release but `Launch` only declares them under "
        f"`#if DEBUG` — Release will not build: {offenders}. Either add a "
        "Release stub beside the others, or fence the call site."
    )


def test_the_guard_can_actually_fire():
    """A clean run of the test above must mean something.

    This repo's rule is that a detector is a claim until it has been seen to
    fail, and this one reads source with a hand-written directive walker —
    exactly the kind of thing that quietly matches nothing.
    """
    src = LAUNCH.read_text(encoding="utf-8")
    release = _release_lines(src)
    assert release, "the directive walker found no Release lines at all"

    numbers = {number for number, _ in release}
    debug_side = src.splitlines()[41:100]
    assert any(
        "-resetState" in line for line in debug_side
    ), "expected the Debug branch to still read launch arguments"

    # `resetState` reads `args` and is Debug-only; the walker must exclude it.
    for number, line in enumerate(src.splitlines(), 1):
        if "args.contains(\"-resetState\")" in line:
            assert number not in numbers, (
                "the walker treated a `#if DEBUG` line as Release-reachable, "
                "so the guard above would pass no matter what"
            )
            break
    else:
        raise AssertionError("could not find the Debug-only line this test pins to")
