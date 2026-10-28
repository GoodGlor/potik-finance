"""Guards for the English interface — board #85.

The Swift half is `ios/MonitorFinanceTests/LocalizationTests.swift`, which
tests BEHAVIOUR: that naming a bundle selects a language, that every entry
keeps its format specifiers, that amounts and dates follow the choice.

These are the rules about SOURCE, which no test running inside the app can
see: which literals may never be translated, who is allowed to write the one
piece of global state this feature has, and which launch lists must pin a
language. Every one of them guards a failure that leaves nothing on screen to
say it happened.
"""

import re

from tests.test_ios_seed import ROOT, _code_only

APP = ROOT / "ios/MonitorFinance"
UI_TESTS = ROOT / "ios/MonitorFinanceUITests"
CATALOGUE = APP / "Resources/en.lproj/Localizable.strings"

CYRILLIC = re.compile("[Ѐ-ӿ]")
STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def _catalogue() -> dict[str, str]:
    """The English catalogue as a dict, parsed the way the file is written.

    A crude regex rather than a `.strings` parser: the file is generated in
    one shape and this asserts against that shape, so a file it cannot read
    is a file that has changed shape and should be looked at.
    """
    pairs = re.findall(
        r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;',
        CATALOGUE.read_text("utf-8"),
        re.MULTILINE,
    )
    assert len(pairs) > 300, (
        f"the guard parsed {len(pairs)} entries — the catalogue's shape changed"
    )
    return dict(pairs)


def _swift_sources():
    return sorted(APP.rglob("*.swift"))


# ---------------------------------------------------------------- the trap


def test_the_localized_initializer_that_ignores_its_locale_stays_out_of_the_app():
    """`String(localized:locale:)` does NOT select a localization.

    Measured, and pinned in `LocalizationTests`: it returns "Categories" for
    `locale: uk` on an English device. The `locale:` argument formats numbers
    and dates INSIDE the string; the language comes from the bundle and the
    device's preferred languages. It is the obvious API, it compiles, it runs,
    and it silently returns the wrong language.

    So the app names a bundle instead — `L10n.t` — and this keeps the obvious
    wrong answer from creeping back in beside it.
    """
    offenders = []
    for path in _swift_sources():
        for number, line in enumerate(_code_only(path.read_text("utf-8")).splitlines(), 1):
            if "String(localized:" in line:
                offenders.append(f"{path.relative_to(ROOT)}:{number}")
    assert offenders == [], (
        "String(localized:) ignores its locale: argument — use L10n.t(key, language). "
        f"{offenders}"
    )


def test_the_guard_above_can_actually_fire():
    """Prove the detector before trusting its clean run.

    The scan reads `_code_only`, which strips comments — so a guard written
    against a codebase that documents what it forbids can quietly match
    nothing at all. This feeds it the string it is looking for.
    """
    assert "String(localized:" in _code_only('let x = String(localized: "a")')
    assert "String(localized:" not in _code_only('// String(localized: "a")')

    # …and the identifier boundary the parser guard below matches on: a real
    # `Text(` still fires, a function whose name merely ends in «Text» does not.
    boundary = r"(?<![A-Za-z0-9_])" + re.escape("Text(")
    assert re.search(boundary, 'var body: some View { Text("a") }')
    assert not re.search(boundary, "static func isOwnTransferText(_ text: String) -> Bool {")


# -------------------------------------------------- what is never translated

# The four files whose Ukrainian literals are matched against text PrivatBank
# and the tax service actually SEND. Translating one breaks the importer, and
# the app would look perfectly healthy afterwards — the statement would simply
# import as uncategorised.
PARSER_FILES = [
    "Import/PrivatMapper.swift",
    "Import/PrivatStatementParser.swift",
    "Receipts/FuelGrade.swift",
    "Store/GenericMerchant.swift",
]


def test_the_parsers_hold_no_localisation_machinery():
    """The third boundary of board #85, and the only one nothing on screen
    would report.

    A translated category name would at least look wrong immediately. These
    would not: the app would keep running, the statement would keep importing,
    and every row would land uncategorised.

    **Not "these strings are absent from the catalogue".** A catalogue entry
    cannot reach them — `PrivatStatementParser.header` compares raw Swift
    literals against the spreadsheet, and two of its column names («Картка»,
    «Категорія») are legitimately also labels on the detail screen. The same
    word is copy in one place and data in the other, and only the copy is
    translated. What would actually break the importer is somebody
    translating these files, so this pins that they are not the kind of file
    that gets translated, and the counts below pin that they did not.
    """
    for name in PARSER_FILES:
        path = APP / name
        assert path.exists(), f"{name} moved — this guard now protects nothing"
        source = _code_only(path.read_text("utf-8"))
        for machinery in ("LocalizedStringKey", "L10n.t(", "String(localized:", "Text("):
            # Anchored on an identifier boundary, not a bare substring: these
            # are Swift names, and `Text(` is a suffix of any function whose
            # name ends in «…Text» — `PrivatMapper.isOwnTransferText(_:)` is
            # one, and it is parsing, which is the opposite of what this
            # guard forbids. Matching it would teach whoever hits the failure
            # to rename their parser to please a test.
            found = re.search(r"(?<![A-Za-z0-9_])" + re.escape(machinery), source)
            assert not found, (
                f"{name} matches text the bank and the tax service SEND. "
                f"Nothing here is copy, and `{machinery}` says otherwise."
            )


def test_the_parsers_ukrainian_is_still_ukrainian():
    """The count is the tripwire: a translation pass over these files leaves
    it near zero, and every other test in the repo would still pass.

    The importer's own tests cannot catch it — `PrivatStatementParserTests`
    builds its fixture rows FROM `PrivatStatementParser.header`, so a
    translated header changes both sides of the comparison at once and the
    test stays green while no real statement parses again.
    """
    counts = {}
    for name in PARSER_FILES:
        source = _code_only((APP / name).read_text("utf-8"))
        counts[name] = sum(1 for lit in STRING_LITERAL.findall(source) if CYRILLIC.search(lit))

    for name, found in counts.items():
        assert found > 5, f"{name} holds {found} Ukrainian literals — has it been translated?"
    assert sum(counts.values()) > 40, f"{counts} — far fewer Ukrainian literals than expected"


def test_the_statement_header_is_the_row_privatbank_actually_sends():
    """The one literal in the four whose exact contents decide whether any
    statement imports at all, named here rather than left to a test that
    reads it from the source it is checking."""
    source = (APP / "Import/PrivatStatementParser.swift").read_text("utf-8")
    header = re.search(r"static let header = \[(.*?)\]", source, re.DOTALL)
    assert header, "the header row is not where this guard looks for it"
    cells = STRING_LITERAL.findall(header.group(1))
    assert cells[:4] == ["Дата", "Категорія", "Картка", "Опис операції"], cells


def test_the_seeded_category_names_are_never_offered_for_translation():
    """The owner's decision: category names are the person's DATA.

    A transaction, a rule and a budget line each reference a category by its
    name, and the person can rename it. A translated «Продукти» would orphan
    every row pointing at it.
    """
    reference = ROOT / "ios/MonitorFinance/Resources/reference.json"
    import json

    names = {c["name"] for c in json.loads(reference.read_text("utf-8"))["categories"]}
    assert len(names) > 15, f"only {len(names)} categories read — the seed's shape changed"

    translated = sorted(names & set(_catalogue()))
    assert translated == [], f"category names are data, not copy: {translated}"


# ------------------------------------------------------- catalogue coverage

# `.navigationTitle("ПриватБанк")` — the bank's own name, in the same class as
# a category name: `Bank.name` is stored and matched on. Named here rather
# than exempted by pattern, so a second one has to be argued for.
UNTRANSLATED_ON_PURPOSE = {"ПриватБанк"}

DISPLAYS_A_KEY = re.compile(
    r'(?:Text|navigationTitle|Label|Button|Toggle|Section|alert|confirmationDialog)'
    r'\(\s*"((?:[^"\\\n]|\\.)*)"'
)

# The same list, as a lookbehind for the scanner below. A regex cannot read a
# literal that contains an interpolation containing a literal — which is what
# `"Відключити \(bank?.displayName ?? "")?"` is — so the scanner walks.
OPENS_A_DISPLAY = re.compile(
    r'(?:Text|navigationTitle|navigationBarTitle|Label|Button|Toggle|Section|'
    r'alert|confirmationDialog|TextField|SecureField|Picker|NavigationLink|'
    r'Menu|Link|ContentUnavailableView|accessibilityLabel|accessibilityHint)'
    r'\(\s*$'
)

INTERPOLATION = "\\(…)"


def _literals(source: str):
    """Every Swift string literal, as (index, shape, inner_literals).

    `shape` is the literal with each interpolation replaced by a marker, so a
    key's specifier positions survive. `inner_literals` are `(literal, before)`
    pairs for the literals that appear INSIDE those interpolations — each one a
    plain `String` substituted into the key at runtime, and so never translated
    by the catalogue unless `before` shows it reaching `L10n.t` first.

    Written as a scanner rather than a regex because the regex it replaces
    stopped at the first quote inside an interpolation and silently reported a
    literal that does not exist in the source.
    """
    i, n = 0, len(source)
    while i < n:
        if source[i] != '"':
            i += 1
            continue
        start, i = i, i + 1
        shape, inner = [], []
        while i < n and source[i] != '"':
            if source[i] == "\\" and i + 1 < n and source[i + 1] == "(":
                depth, j = 1, i + 2
                while j < n and depth:
                    if source[j] == '"':
                        k = j + 1
                        while k < n and source[k] != '"':
                            k += 2 if source[k] == "\\" else 1
                        # The interpolation's text up to this literal decides
                        # whether it is being SHOWN or handed to `L10n.t` as a
                        # key, so it travels with it.
                        inner.append((source[j + 1:k], source[i + 2:j]))
                        j = k + 1
                        continue
                    depth += {"(": 1, ")": -1}.get(source[j], 0)
                    j += 1
                shape.append(INTERPOLATION)
                i = j
                continue
            if source[i] == "\\":
                shape.append(source[i:i + 2])
                i += 2
                continue
            if source[i] == "\n":
                break
            shape.append(source[i])
            i += 1
        yield start, "".join(shape), inner
        i += 1


# A property or function DECLARED `LocalizedStringKey` is a display site as
# surely as `Text("…")` is — its literals become catalogue keys the moment it is
# shown. `BudgetView.planLabel` is one, and `"План за \(month.title)"` had no
# English entry for two boards because nothing was looking here.
RETURNS_A_KEY = re.compile(r"(?:var\s+\w+\s*:|->)\s*LocalizedStringKey\s*\{")


def _key_bodies(source: str):
    """The body of every `LocalizedStringKey` property and function."""
    for match in RETURNS_A_KEY.finditer(source):
        start = match.end()
        depth, i = 1, start
        while i < len(source) and depth:
            depth += {"{": 1, "}": -1}.get(source[i], 0)
            i += 1
        yield source[start:i]


def _display_literals(source: str):
    """The shapes of literals written directly at a display site."""
    for index, shape, _ in _literals(source):
        if OPENS_A_DISPLAY.search(source[max(0, index - 40):index]):
            yield shape
    for body in _key_bodies(source):
        for _, shape, _ in _literals(body):
            yield shape


def _key_forms(shape: str) -> list[str]:
    """The catalogue keys SwiftUI could build from this literal.

    Which specifier an interpolation becomes depends on the interpolated
    type — `%lld` for an integer, `%@` for a string — which this cannot see.
    So it generates both for each and the caller accepts any match.
    """
    count = shape.count(INTERPOLATION)
    if not count:
        return [shape]
    forms = []
    for combination in range(2 ** count):
        form = shape
        for bit in range(count):
            spec = "%lld" if (combination >> bit) & 1 else "%@"
            form = form.replace(INTERPOLATION, spec, 1)
        forms.append(form)
    return forms


def test_every_ukrainian_string_on_a_screen_has_an_english_entry():
    """The coverage measure, and the reason a missing one is invisible.

    A key with no entry renders as the key — which is Ukrainian, which is
    correct-looking. So an untranslated screen does not crash, does not warn,
    and does not fail any other test: it simply stays Ukrainian for an English
    reader. This is what notices.

    **Interpolated keys are covered too, since board #96.** They used to be
    skipped, on the true observation that SwiftUI rewrites `\\(count)` into
    `%lld` or `%@` by the interpolated type, so the source literal is not the
    catalogue key. The cost of that skip was two missing entries — `"План за
    %@"` and the queue's coverage footer — sitting in plain sight for two
    boards. `_key_forms` generates the specifier combinations a literal could
    take and the entry is found if any of them is present, which is looser than
    knowing the type and tight enough to have caught both.
    """
    keys = set(_catalogue())
    missing = []
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        for literal in _display_literals(source):
            if not CYRILLIC.search(literal):
                continue
            if literal in UNTRANSLATED_ON_PURPOSE:
                continue
            if any(form in keys for form in _key_forms(literal)):
                continue
            missing.append(f"{path.relative_to(ROOT)}: {literal}")

    assert missing == [], (
        "these render as Ukrainian for an English reader, and nothing says so: "
        f"{sorted(missing)}"
    )


def test_the_coverage_guard_reads_enough_to_be_worth_running():
    """The control for the guard above: a pattern that matched nothing would
    report full coverage. Roughly two hundred literals reach a screen."""
    found = 0
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        found += sum(1 for lit in DISPLAYS_A_KEY.findall(source) if CYRILLIC.search(lit))
    assert found > 150, f"only {found} on-screen literals found — the coverage guard is vacuous"


# ------------------------------------------- the overload that silently loses

# Names that carry COPY. A `String` under one of these, handed to `Text(…)`,
# takes SwiftUI's verbatim overload and renders Ukrainian to an English reader.
# `value` is deliberately absent: `factRow`'s second column is a figure.
COPY_NAMES = {
    "title", "subtitle", "note", "text", "error", "message", "body", "sentence",
    "label", "buttonTitle", "planLabel", "refusal", "logStatus", "countsLine",
    "checkTitle", "emailError", "ruleEffect", "emailNote",
}

TEXT_OF_IDENTIFIER = re.compile(r"Text\(\s*(?!verbatim:)(?!\")([A-Za-z_][A-Za-z0-9_]*)\s*\)")


def _copy_typed_as_string(source: str) -> set[str]:
    """Names in `COPY_NAMES` that this file both declares `String` and shows.

    A name declared BOTH ways in one file is skipped rather than reported: this
    reads text, not a syntax tree, so it cannot tell which declaration a given
    `Text(name)` refers to, and guessing wrong teaches whoever hits the failure
    to silence a guard that was right everywhere else. `Theme.swift` is the
    real case — `Appearance.title` is a `String` (shown through an explicit
    `LocalizedStringKey(_:)`) while `PrimaryButton.title` a few lines down is
    already a `LocalizedStringKey`. The cost of the blind spot is one file
    needing both spellings of one name before it can hide anything.
    """
    shown = {m.group(1) for m in TEXT_OF_IDENTIFIER.finditer(source)} & COPY_NAMES
    guilty = set()
    for name in shown:
        as_string = re.findall(
            rf"(?:var|let)\s+{name}\s*:\s*(String\??)\b", source
        ) + re.findall(rf"\b_?\s*{name}\s*:\s*(String\??)[,)\s]", source)
        as_key = re.search(rf"\b{name}\s*:\s*LocalizedStringKey", source)
        if as_string and not as_key:
            guilty.add(name)
    return guilty


def test_no_copy_reaches_the_screen_as_a_plain_string():
    """`Text(someStringVariable)` binds to the VERBATIM overload.

    It compiles, it runs, it renders — in Ukrainian, on an English phone,
    beside headings that translated correctly because they were written as
    literals. Nothing warns, no other test fails, and the catalogue can even
    hold a perfectly good translation that is never read: «уже підключено» and
    «з файлу виписки» both had entries while the bank picker showed them in
    Ukrainian under an English «Connect a bank».

    `Theme.swift:316` records the same trap for `PrimaryButton.title` — board
    #85 found it there and fixed exactly that one. This is the general rule.

    The fix is never to cast at the call site: type the parameter
    `LocalizedStringKey`, or — when the sentence is assembled at runtime and
    has no literal for the catalogue to match — translate it at the source with
    `String(format: L10n.t(key, language), …)`, the way `Derived`, `BudgetMath`
    and `TransactionDetailView.ruleState` do.
    """
    offenders = []
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        for name in sorted(_copy_typed_as_string(source)):
            offenders.append(f"{path.relative_to(ROOT)}: {name}")
    assert offenders == [], (
        "these render Ukrainian for an English reader — type them "
        f"LocalizedStringKey, or translate at the source with L10n.t: {offenders}"
    )


# ------------------------------- board #96: the three ways round both guards

# `Plural.*` and `L10n.t` return finished, already-translated phrases, so a
# Ukrainian literal beside them in an interpolation is the SOURCE key, not
# something being shown. Nothing else is exempt.
TRANSLATES_AT_THE_SOURCE = re.compile(r"L10n\.t\(|Plural\.|String\(format:")


def test_no_ukrainian_literal_hides_inside_an_interpolation():
    """`"… \\(x ?? "попередній місяць") …"` — the fallback is a plain `String`.

    SwiftUI translates the key and then substitutes the argument verbatim, so
    the sentence around the hole is English and the word in it is Ukrainian.
    The catalogue had held the right translation of that word since board #85;
    nothing ever asked for it. There is nothing on screen to say so — the line
    reads as a translation that someone did badly.
    """
    offenders = []
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        for index, _, inner in _literals(source):
            line = source.count("\n", 0, index) + 1
            for literal, before in inner:
                if CYRILLIC.search(literal) and not TRANSLATES_AT_THE_SOURCE.search(before):
                    offenders.append(f"{path.relative_to(ROOT)}:{line}: {literal}")

    assert offenders == [], (
        "these are substituted into a key verbatim and never translated — "
        f"translate at the source with L10n.t: {offenders}"
    )


# A `String` reaches `Text` two ways the bare-identifier guard cannot see:
# joined with `+`, or unwrapped with `??`. Both produce `String`, both take the
# verbatim overload, and `+` additionally makes the sentence untranslatable in
# principle — half a sentence has no catalogue entry.
TEXT_CALL = re.compile(r"\bText\(\s*(?!verbatim:)(.{0,240}?)\)\s*\n", re.DOTALL)
JOINS_OR_DEFAULTS = re.compile(r"\+|\?\?")


def _outside_literals(expression: str) -> str:
    """`expression` with every string literal — interpolations and all — blanked.

    `+` and `??` mean "this builds a String" only at the top level of the
    argument. Inside a literal's interpolation they are ordinary Swift in a
    value being substituted, which is what `Text("\\(a ?? b) підключено")` is
    and which is correct. Reading the raw text cannot tell the two apart.
    """
    out, i, n = [], 0, len(expression)
    while i < n:
        if expression[i] != '"':
            out.append(expression[i])
            i += 1
            continue
        i += 1
        depth = 0
        while i < n:
            if expression[i] == "\\" and i + 1 < n and expression[i + 1] == "(":
                depth += 1
                i += 2
                continue
            if depth:
                depth += {"(": 1, ")": -1}.get(expression[i], 0)
            elif expression[i] == '"':
                i += 1
                break
            i += 1
    return "".join(out)


def _text_expressions_building_strings(source: str) -> list[str]:
    found = []
    for match in TEXT_CALL.finditer(source):
        expression = match.group(1)
        if '"' not in expression or not CYRILLIC.search(expression):
            continue
        if not JOINS_OR_DEFAULTS.search(_outside_literals(expression)):
            continue
        found.append(" ".join(expression.split())[:90])
    return found


def test_no_text_builds_its_string_before_showing_it():
    """`Text("a" + "b")` and `Text(x ?? "b")` are both the verbatim overload.

    The queue's coverage footer was the first: two halves joined with `+`, so
    the type was `String` and neither half was a key anything could translate.
    The category delete dialog was the second, and its English text was in the
    catalogue the whole time.
    """
    offenders = []
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        for expression in _text_expressions_building_strings(source):
            offenders.append(f"{path.relative_to(ROOT)}: Text({expression})")

    assert offenders == [], (
        "these build a String before Text sees it, which takes the verbatim "
        f"overload: write one interpolated literal, or translate at the source: {offenders}"
    )


#: `.accessibilityValue("…")` — the SAME overload set as `Text`, biting the
#: other way round. A literal binds to `LocalizedStringKey`, and an
#: interpolated number in one is FORMATTED FOR THE LOCALE.
#: The literal must start immediately after the paren — that is what makes it a
#: `LocalizedStringKey` rather than the `String` a variable would give.
ACCESSIBILITY_VALUE = re.compile(r"\.accessibilityValue\(\s*\"((?:[^\"\\\n]|\\.)*)\"")


def _accessibility_values_that_are_localised(source: str) -> list[str]:
    """Calls whose argument is a literal carrying an interpolation.

    A crude literal match, not the full scanner: an accessibility value is a
    short expression and none in this repo nests a quote inside its
    interpolation. A nested quote would end the match early — which can only
    make this MISS one, never invent one.
    """
    return [
        " ".join(m.group(0).split())[:90]
        for m in ACCESSIBILITY_VALUE.finditer(source)
        if "\\(" in m.group(1)
    ]


def test_no_accessibility_value_is_built_from_an_interpolated_literal():
    """`.accessibilityValue("\\(n)")` groups the digits, and nothing says so.

    Measured, board #109: the feed's new spending total reported
    «1 234 500» — with a NON-BREAKING SPACE — so `Int(element.value)` in a UI
    test came back nil. `Text` and `.accessibilityValue` share an overload set:
    a literal takes `LocalizedStringKey`, which formats an interpolated number
    for the locale. A `String` variable takes the verbatim one.

    `feed.count` had carried this since it was written and no test ever saw it,
    because a feed month holds three digits and three digits never group. A
    month with a thousand rows would have broken four tests at once, and the
    failure — a nil where a number was expected — names neither the cause nor
    the file.

    An accessibility VALUE is data. A LABEL is copy and may stay localised.
    """
    offenders = []
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        for expression in _accessibility_values_that_are_localised(source):
            offenders.append(f"{path.relative_to(ROOT)}: {expression}")

    assert offenders == [], (
        "an interpolated literal here is a LocalizedStringKey, and a number in "
        f"one is formatted for the locale — bind it to a `String` first: {offenders}"
    )


# A function that returns assembled copy needs to be told the language; there
# is no environment to read inside one. `AppLanguage` in the signature is the
# evidence that it was.
COPY_FUNCTION = re.compile(
    r"(?:static\s+)?func\s+(\w+)\s*\(([^)]*)\)\s*->\s*String\b\s*\{", re.DOTALL
)


#: A Ukrainian literal sitting where `L10n.t` expects its key is copy that HAS
#: been told the language. Removed before asking whether any is left stranded.
LOCALISED_KEY = re.compile(r'L10n\.t\(\s*"(?:[^"\\]|\\.)*"')


def _copy_function_candidates(source: str) -> set[str]:
    """Functions in this file that return Ukrainian and never asked which
    language. Whether anybody SHOWS one is a separate question — and,
    since board #128, a question about every file rather than this one."""
    guilty = set()
    for match in COPY_FUNCTION.finditer(source):
        name, parameters = match.group(1), match.group(2)
        if "AppLanguage" in parameters:
            continue
        body_start = match.end()
        depth, i = 1, body_start
        while i < len(source) and depth:
            depth += {"{": 1, "}": -1}.get(source[i], 0)
            i += 1
        # Cyrillic that is already a `L10n.t` KEY is translated copy, not
        # stranded copy. `StatsView.sourceLabel` reads the language off the
        # store instead of taking a parameter, which is just as good and was
        # the first thing the widened guard wrongly accused. What matters is
        # whether a Ukrainian literal can reach the screen untranslated, not
        # how the function learned the language.
        body = LOCALISED_KEY.sub("", source[body_start:i])
        if not CYRILLIC.search(body):
            continue
        guilty.add(name)
    return guilty


def _shown_through_text(name: str, corpus: str) -> bool:
    """Is this function drawn through `Text(…)` ANYWHERE in the app?

    **The receiver is left open**, so `Text(Derived.categoryLabel(tx))` and
    `Text(Self.progressText(...))` and a bare `Text(label(...))` all match. A
    guard that required the call to sit in the declaring file is the guard that
    missed board #128 for months: `categoryLabel` lived in `Derived.swift` and
    both screens that drew it are elsewhere.

    `verbatim:` is matched too. It changes which `Text` overload is chosen; it
    does not translate anything, so a Ukrainian string is just as stuck.

    Over-reporting — a same-named function on another type — is the safe
    direction for a guard whose whole job is to notice.
    """
    return bool(re.search(rf"Text\(\s*(?:verbatim:\s*)?(?:\w+\.)*{re.escape(name)}\(", corpus))


def _copy_functions_without_a_language(source: str, corpus: str | None = None) -> set[str]:
    """Board #99's lesson, applied: a guard that reads ONE FILE cannot see a
    defect spread across two. `corpus` is every app source concatenated."""
    haystack = source if corpus is None else corpus
    return {name for name in _copy_function_candidates(source)
            if _shown_through_text(name, haystack)}


def test_a_function_that_returns_copy_is_told_the_language():
    """`Text(Self.progressText(start:remaining:))` — «3 з 27», forever.

    A `String` built inside a function has no `EnvironmentValues.locale` to
    resolve against and no literal left for the catalogue to match, so the only
    place it can be translated is where it is assembled. A function that takes
    no `AppLanguage` and returns Ukrainian cannot have been.
    """
    sources = {path: _code_only(path.read_text("utf-8")) for path in _swift_sources()}
    # Board #128: the search for `Text(…)` runs over EVERY file, not the one
    # the function is declared in.
    corpus = "\n".join(sources.values())

    offenders = []
    for path, source in sources.items():
        for name in sorted(_copy_functions_without_a_language(source, corpus)):
            offenders.append(f"{path.relative_to(ROOT)}: {name}")

    assert offenders == [], (
        "these assemble Ukrainian and are shown through Text, with no language "
        f"to assemble it in: take an AppLanguage and go through L10n.t: {offenders}"
    )


# A notification is assembled copy by construction: there is no view, so there
# is no environment, so `L10n.t` is the only way its text can be translated.
NOTIFICATION_FIELD = re.compile(r"content\.(?:title|body|subtitle)\s*=\s*(.+)")


def test_no_notification_is_written_in_one_language():
    """`content.title` went through `L10n.t`; `content.body` beside it did not.

    An English phone showed "New purchase" over «Сільпо · ₴240 — що це?». No
    view is involved, so nothing in SwiftUI could ever have resolved it, and no
    screenshot walk of the app would show it either — it is on the lock screen.
    """
    offenders = []
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        for line in NOTIFICATION_FIELD.findall(source):
            if CYRILLIC.search(line) and "L10n.t" not in line:
                offenders.append(f"{path.relative_to(ROOT)}: {line.strip()[:70]}")

    assert offenders == [], (
        f"a notification cannot read its environment — translate with L10n.t: {offenders}"
    )


def test_the_board_96_guards_can_actually_fire():
    """The controls. Each of the three guards above passed for the whole app
    while the app was showing Ukrainian to English readers, so each needs a
    fixture that proves the detector distinguishes the two."""
    # The interpolation scanner reads a literal that contains a literal.
    scanned = list(_literals('let x = "Відключити \\(bank?.name ?? "")?"'))
    assert scanned[0][1] == "Відключити \\(…)?", scanned
    assert scanned[0][2] == [("", "bank?.name ?? ")], scanned
    assert _key_forms("Відключити \\(…)?") == ["Відключити %@?", "Відключити %lld?"]

    # A Ukrainian fallback inside an interpolation is found; the same word
    # handed to `L10n.t` first is not.
    def hidden(src):
        return [lit for _, _, inner in _literals(src) for lit, before in inner
                if CYRILLIC.search(lit) and not TRANSLATES_AT_THE_SOURCE.search(before)]

    assert hidden('Text("на \\(m ?? "минулий")")') == ["минулий"]
    assert hidden('Text("на \\(m ?? L10n.t("минулий", l))")') == []

    # Both String-building shapes are caught, a plain literal is not, and `??`
    # INSIDE an interpolation is not — that one is ordinary and correct.
    assert _text_expressions_building_strings('Text("Перші " + "карток")\n')
    assert _text_expressions_building_strings('Text(x.map { "\\($0) операцій" } ?? "")\n')
    assert _text_expressions_building_strings('Text("Перші карток")\n') == []
    assert _text_expressions_building_strings('Text(verbatim: a + "карток")\n') == []
    assert _text_expressions_building_strings('Text("\\(a ?? b) підключено")\n') == []

    # A `LocalizedStringKey` property is a display site: its literals become
    # catalogue keys. This is the shape `planLabel` hid in.
    assert list(_display_literals(
        'var planLabel: LocalizedStringKey { "План за \\(m.title)" }')) == ["План за \\(…)"]
    assert list(_display_literals('var x: String { "План за \\(m.title)" }')) == []

    # A notification's copy is caught unless it went through `L10n.t`.
    assert CYRILLIC.search(NOTIFICATION_FIELD.findall('content.body = "що це?"')[0])
    assert "L10n.t" in NOTIFICATION_FIELD.findall('content.body = L10n.t("що це?", l)')[0]

    # Board #109's trap, the same overload set facing the other way: an
    # interpolated literal is caught, a fixed one is not, and a `String`
    # variable — which is the fix — is not.
    assert _accessibility_values_that_are_localised('.accessibilityValue("\\(rows.count)")')
    assert _accessibility_values_that_are_localised('.accessibilityValue("100%")') == []
    assert _accessibility_values_that_are_localised(".accessibilityValue(count)") == []

    # A copy function is caught only when it is both untold and shown.
    shown = 'static func f(_ n: Int) -> String { "\\(n) з 5" }\nText(Self.f(2))'
    assert _copy_functions_without_a_language(shown) == {"f"}
    told = ('static func f(_ n: Int, _ l: AppLanguage) -> String { "\\(n) з 5" }\n'
            'Text(Self.f(2, l))')
    assert _copy_functions_without_a_language(told) == set()
    unshown = 'static func f(_ n: Int) -> String { "\\(n) з 5" }'
    assert _copy_functions_without_a_language(unshown) == set()


def test_the_verbatim_guard_can_actually_fire():
    """The control. A detector that matched nothing would pass the guard above
    for every file in the app, which is precisely the state the app was in."""
    shown = 'let title: String\nvar body: some View { Text(title) }'
    assert _copy_typed_as_string(shown) == {"title"}
    assert _copy_typed_as_string('var message: String?\nText(message)') == {"message"}
    # Typed correctly, or explicitly data: both must pass.
    assert _copy_typed_as_string('let title: LocalizedStringKey\nText(title)') == set()
    assert _copy_typed_as_string('let title: String\nText(verbatim: title)') == set()
    # Both spellings in one file: the blind spot, asserted so it stays known.
    assert _copy_typed_as_string(
        'var title: String\nlet title: LocalizedStringKey\nText(title)') == set()


# ------------------------------------------------- the one piece of global state


def test_only_l10n_assigns_the_formatting_language():
    """`L10n.formatting` is process-wide, and one writer is what makes it safe.

    Forty-one call sites read it — `Int.uah`, `MonthKey.title`, `BudgetMath` —
    because threading a language through pure functions over `[Transaction]`
    to build a thousands separator was the wrong shape. That is defensible
    exactly as long as assignment stays in one place.
    """
    writers = []
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        for number, line in enumerate(source.splitlines(), 1):
            if re.search(r"\bformatting\s*=(?!=)", line):
                writers.append(f"{path.relative_to(ROOT)}:{number}")
    assert writers == ["ios/MonitorFinance/L10n.swift:88"] or all(
        w.startswith("ios/MonitorFinance/L10n.swift") for w in writers
    ), f"L10n.formatting must be written only by L10n.setFormatting: {writers}"
    assert writers, "the guard matched no assignment at all — it is reading the wrong name"


def test_only_the_store_sets_the_formatting_language():
    """`AppStore` sets it at launch and on every change of the setting. A
    second caller means two answers to "what language is this app in"."""
    callers = set()
    for path in _swift_sources():
        if "L10n.setFormatting" in _code_only(path.read_text("utf-8")):
            callers.add(path.relative_to(APP).as_posix())
    assert callers == {"Store/AppStore.swift"}, (
        f"setFormatting is AppStore's to call: {sorted(callers)}"
    )


def test_the_formatting_language_is_never_compared_without_resolving():
    """`.system` is a real case of the enum and `resolved` is what turns it
    into a language.

    A bare `L10n.formatting == .en` read `.system` as "not English" while
    `MonthKey.title`, which goes through `.locale`, resolved it — so an
    English phone drew "August 2026" above «1 240,50 ₴» for the length of one
    launch. The initial value now resolves too, which makes the state
    unreachable; this keeps the reader honest anyway, because the next such
    comparison would not have that protection.
    """
    offenders = []
    for path in _swift_sources():
        source = _code_only(path.read_text("utf-8"))
        for number, line in enumerate(source.splitlines(), 1):
            if re.search(r"L10n\.formatting\s*[=!]=", line):
                offenders.append(f"{path.relative_to(ROOT)}:{number}")
    assert offenders == [], (
        "compare L10n.formatting.resolved, not the raw case — .system is not a language. "
        f"{offenders}"
    )


# --------------------------------------------------------- the UI test suite


LAUNCH_LIST = re.compile(r"launchArguments\s*=\s*(.*?)]", re.DOTALL)


def test_every_ui_test_launch_list_pins_a_language():
    """Three hundred UI assertions read Ukrainian copy off the screen.

    The app's default is «як у системі» and a simulator's system language is
    English, so without `-lang uk` every one of those depends on a device
    setting no test names — and two classes were in exactly that state when
    this guard was written. `SplitTests` and `ReceiptTests` asserted the
    Ukrainian tab bar and would have failed the moment the suite ran on a
    fresh simulator.
    """
    unpinned = []
    for path in sorted(UI_TESTS.glob("*.swift")):
        source = _code_only(path.read_text("utf-8"))
        for match in LAUNCH_LIST.finditer(source):
            if '"-lang"' not in match.group(1):
                line = source[: match.start()].count("\n") + 1
                unpinned.append(f"{path.relative_to(ROOT)}:{line}")
    assert unpinned == [], (
        "a launch list with no -lang runs in the simulator's language, not the app's: "
        f"{unpinned}"
    )


def test_the_launch_list_guard_reads_every_class():
    """The control: a regex that matched nothing would pass the guard above
    for every file in the target."""
    found = sum(
        len(LAUNCH_LIST.findall(_code_only(p.read_text("utf-8"))))
        for p in UI_TESTS.glob("*.swift")
    )
    assert found > 25, f"only {found} launch lists found — the pin guard is vacuous"


# ------------------------------------------------------------- what ships


def test_both_catalogues_ship_in_every_configuration():
    """The `.lproj` folders are copied by folder membership rather than by a
    build phase anybody reviews, and `EXCLUDED_SOURCE_FILE_NAMES` is the one
    thing that can hold a resource back.

    Excluding `Localizable.strings` would make the App Store build
    Ukrainian-only, with every key falling through to itself — which looks
    exactly like a working Ukrainian app.
    """
    for language in ("uk", "en"):
        path = APP / f"Resources/{language}.lproj/Localizable.strings"
        assert path.exists(), f"{language}.lproj is missing — that language falls back to its keys"

    pbx = (ROOT / "ios/MonitorFinance.xcodeproj/project.pbxproj").read_text("utf-8")
    excluded = re.findall(r"EXCLUDED_SOURCE_FILE_NAMES = ([^;]+);", pbx)
    assert excluded, "the exclusion setting vanished — test_release_excludes… covers why it matters"
    for value in excluded:
        assert "Localizable" not in value and ".lproj" not in value, (
            f"a catalogue is excluded from a build configuration: {value}"
        )


def test_the_cross_file_copy_guard_can_actually_fire():
    """Board #128's third criterion, and the reason it is written down.

    The guard above passed for months while `Derived.categoryLabel` returned
    «Переказ між своїми картками» to two screens in two other files. It read
    one file at a time, so it could see the function or the `Text`, never both
    — board #99's lesson arriving a third time.

    Three halves. The middle one is the shape that shipped.
    """
    derived = '''
    static func categoryLabel(_ tx: Transaction) -> String {
        guard tx.category.isEmpty else { return tx.category }
        return tx.kind == .transfer ? "Переказ між своїми картками" : "Без категорії"
    }
    '''
    view = 'Text(Derived.categoryLabel(tx))'

    # Same file: the old guard caught this much.
    assert _copy_functions_without_a_language(derived + view) == {"categoryLabel"}

    # SPLIT ACROSS TWO FILES — where it actually hid, and where the old guard
    # reported the app clean.
    assert _copy_functions_without_a_language(derived, derived + view) == {"categoryLabel"}, (
        "a guard that reads one file cannot see a defect spread across two"
    )

    # `verbatim:` chooses a different Text overload; it translates nothing, so
    # the Ukrainian is just as stuck.
    assert _copy_functions_without_a_language(
        derived, derived + "Text(verbatim: Derived.categoryLabel(tx))") == {"categoryLabel"}

    # The fix: told the language, and the literals go through the catalogue.
    fixed = '''
    static func categoryLabel(_ tx: Transaction, _ language: AppLanguage) -> String {
        guard tx.category.isEmpty else { return tx.category }
        return L10n.t(tx.kind == .transfer ? "Переказ між своїми картками" : "Без категорії",
                      language)
    }
    '''
    assert _copy_functions_without_a_language(fixed, fixed + view) == set()

    # And a function that reads the language off the store rather than taking
    # it — `StatsView.sourceLabel`'s shape, which the first widening wrongly
    # accused. Correct code must not be flagged, or the guard trains people to
    # ignore it.
    from_store = '''
    private func sourceLabel(_ source: StatsSource) -> String {
        return L10n.t("Усі банки", store.settings.languageChoice)
    }
    '''
    assert _copy_functions_without_a_language(
        from_store, from_store + "Text(verbatim: sourceLabel(option))") == set()
