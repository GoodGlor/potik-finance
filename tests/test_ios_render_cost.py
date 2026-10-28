"""Board #105 — what a scroll is allowed to do per row.

The freeze the owner hit is a main-thread cost repeated once per visible card.
Two shapes produce it, and this file guards the second; the first — building a
`DateFormatter` per call — is measured in `ScrollCostTests` instead, because
"is this expensive" is a question about time and not about text.

The shape here is a WHOLE-DATASET walk evaluated inside a per-row body. Board
#8 established the rule for `QueueView` and wrote it into that file's own
comments: build the list once per render and hand it down. Board #103 broke it
within the hour — `canSelect` read `store.pendingGroups`, and `canSelect` runs
twice per card, so one render in selection mode walked all 772 transactions,
normalized every pending merchant and sorted the result sixty times.

Nothing on screen says that is happening. It is a dropped frame, then a hang.
"""

import re

from tests.test_ios_seed import ROOT, _code_only

APP = ROOT / "ios/MonitorFinance"

#: Store properties that walk EVERY transaction to answer. Each is cheap once
#: per render and ruinous once per row.
WHOLE_DATASET = (
    "pendingGroups",
    "queuedGroups",
    "pendingCardCount",
    "queueCardCount",
    "pendingRowCount",
)

FOR_EACH = re.compile(r"\bForEach\s*\(")
#: Functions AND computed properties. Both, because board #103's walk was
#: behind `private var selectionKind` — a version of this scanner that followed
#: only `func` reported the defect clean, which is how this line came to be
#: written down rather than assumed.
LOCAL_FUNC = re.compile(r"\bfunc\s+(\w+)\s*\(")
LOCAL_VAR = re.compile(r"\bvar\s+(\w+)\s*:\s*[^={\n]+\{")


def _block(src: str, at: int, what: str) -> str:
    """The brace-matched block whose `{` is at or after `at`.

    Literals are not stripped, so a `{` inside a string would miscount — which
    is why an unbalanced read raises rather than returning a short block that
    would silently hide whatever came after it.
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
    members = {m.group(1): _block(src, m.end(), m.group(1)) for m in LOCAL_FUNC.finditer(src)}
    for m in LOCAL_VAR.finditer(src):
        members[m.group(1)] = _block(src, m.end() - 1, m.group(1))
    return members


def _reaches(body: str, functions: dict[str, str]) -> str | None:
    """The whole-dataset read this body reaches, directly or through a
    same-file function, or `None`.

    **The indirection is the whole point.** Board #103's defect did not put
    `store.pendingGroups` inside the `ForEach`; it put `canSelect(group)` there,
    and `canSelect` read it. A scanner that only looked at the loop body would
    have reported the screen clean.
    """
    seen: set[str] = set()
    queue = [body]
    while queue:
        current = queue.pop()
        for name in WHOLE_DATASET:
            if f"store.{name}" in current or f"self.{name}" in current:
                return name
        # Matched as bare identifiers, not as `name(`: a computed property is
        # referenced without parentheses, and that is exactly the shape the
        # walk hid behind. Over-reporting (a local sharing a member's name) is
        # the safe direction for a guard whose whole job is to notice.
        for name, member in functions.items():
            if name in seen or not re.search(rf"\b{re.escape(name)}\b", current):
                continue
            seen.add(name)
            queue.append(member)
    return None


def _offenders(sources) -> list[str]:
    found = []
    for path in sources:
        name = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path.name
        src = _code_only(path.read_text("utf-8"))
        if not FOR_EACH.search(src):
            continue
        functions = _functions(src)
        for loop in FOR_EACH.finditer(src):
            hit = _reaches(_block(src, loop.end(), "ForEach"), functions)
            if hit:
                found.append(f"{name}: a ForEach body reaches store.{hit}")
    return found


def test_no_row_body_walks_the_whole_dataset():
    """One render, one walk — board #8's rule, guarded.

    Each of these properties reads every transaction the app holds. Once per
    render that is the cost of drawing a screen; once per row it is the cost of
    drawing a screen squared, on the main thread, while a finger is moving.
    """
    offenders = _offenders(sorted(APP.rglob("*.swift")))
    assert not offenders, (
        "build it once per render and hand it down:\n  " + "\n  ".join(offenders)
    )


def test_the_guard_above_can_actually_fire(tmp_path):
    """Three halves, and the middle one is the shape board #103 shipped."""
    direct = tmp_path / "Direct.swift"
    direct.write_text(
        "var body: some View {\n"
        "    ForEach(shown) { group in\n"
        "        Text(verbatim: String(store.pendingGroups.count))\n"
        "    }\n"
        "}\n",
        "utf-8",
    )
    assert _offenders([direct]), "the scanner cannot see inside a ForEach"

    # One function away — where it actually hid, and where the first version of
    # this scanner would have reported the screen clean.
    indirect = tmp_path / "Indirect.swift"
    indirect.write_text(
        "var body: some View {\n"
        "    ForEach(shown) { group in\n"
        "        Card { Text(group.merchant) }.disabled(!canSelect(group))\n"
        "    }\n"
        "}\n"
        "private func canSelect(_ group: MerchantGroup) -> Bool {\n"
        "    selectionKind == nil\n"
        "}\n"
        "private var selectionKind: TxKind? {\n"
        "    store.pendingGroups.first { selected.contains($0.id) }?.kind\n"
        "}\n",
        "utf-8",
    )
    assert _offenders([indirect]), (
        "the walk was one function away from the loop — that is where it hides"
    )

    # The fix: the same helper, told what to look at. A scanner that matched
    # anywhere in the file would condemn every screen that reads the list once
    # at the top, which is the correct thing to do.
    innocent = tmp_path / "Innocent.swift"
    innocent.write_text(
        "var body: some View {\n"
        "    let all = store.pendingGroups\n"
        "    return ForEach(all) { group in\n"
        "        Card { Text(group.merchant) }.disabled(!canSelect(group, kind))\n"
        "    }\n"
        "}\n"
        "private func canSelect(_ group: MerchantGroup, _ kind: TxKind?) -> Bool {\n"
        "    kind.map { $0 == group.kind } ?? true\n"
        "}\n",
        "utf-8",
    )
    assert not _offenders([innocent]), (
        "reading the list ONCE at the top of a body is the rule, not the defect"
    )


def test_the_queue_still_builds_its_list_once():
    """The negative above passes just as well if the screen stops reading the
    queue at all. This is the positive that makes it mean something.
    """
    src = _code_only((APP / "QueueView.swift").read_text("utf-8"))
    assert "store.pendingGroups" in src, "the queue must still read its own queue"
    assert "let all = store.pendingGroups" in src, (
        "board #8's shape: read it once into a local and hand it down"
    )
