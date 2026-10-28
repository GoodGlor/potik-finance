"""Board #130 — the app is called Potik, and two names that must NOT follow.

The rename itself is cheap and visible: if the welcome screen still said
`MonitorFinance`, anybody opening the app would see it. **The risk this file
guards is the opposite one** — two identifiers that nobody can read, that look
exactly like leftovers from the old name, and that a later tidying pass would
rename for consistency without knowing what they cost.

Both failures are silent and neither is recoverable by the app:

    ua.monitorfinance.app          the installed app's identity AND the
                                   Keychain access group. Change it and every
                                   existing install becomes a different app,
                                   so the device secret in the Keychain goes
                                   unreachable — the one piece of state the
                                   app cannot re-derive.

    Application Support/MonitorFinance   change it and every existing
                                   install's data is stranded on disk.

So these tests assert a name is *unchanged*, which is a strange thing for a
test to do until you notice that the diff which breaks them will look like
tidying.
"""

import re

from tests.test_ios_seed import ROOT

PBXPROJ = ROOT / "ios/MonitorFinance.xcodeproj/project.pbxproj"
REPOSITORY = ROOT / "ios/MonitorFinance/Store/Repository.swift"
EN = ROOT / "ios/MonitorFinance/Resources/en.lproj/Localizable.strings"

# The app target's two configurations are the ones carrying the bundle id;
# the three test targets have their own and are not what ships.
APP_BUNDLE_ID = "PRODUCT_BUNDLE_IDENTIFIER = ua.monitorfinance.app;"


def _pbxproj():
    return PBXPROJ.read_text(encoding="utf-8")


def test_the_two_load_bearing_names_are_not_renamed():
    """The Keychain access group and the data directory keep the old name.

    If this fails, read the module docstring before "fixing" it — the fix is
    almost certainly to put the name back, not to update the test.
    """
    assert _pbxproj().count(APP_BUNDLE_ID) == 2, (
        "the app's bundle id must stay ua.monitorfinance.app in BOTH "
        "configurations — it is the Keychain access group, and changing it "
        "makes the device secret unreachable on every existing install"
    )
    assert 'appendingPathComponent("MonitorFinance"' in REPOSITORY.read_text(
        encoding="utf-8"
    ), (
        "Application Support/MonitorFinance must keep its name — renaming the "
        "directory strands every existing install's data"
    )


def test_the_home_screen_label_is_set_in_both_configurations():
    """A display name set only in Debug reads as working, then ships wrong.

    The simulator and the owner's phone both run Debug builds, so a Release
    build is the first place the omission would show — after review.
    """
    names = re.findall(r"INFOPLIST_KEY_CFBundleDisplayName = (.+);", _pbxproj())
    assert names == ["Potik", "Potik"], (
        f"expected the display name in both app configurations, found {names}"
    )


def test_the_home_screen_label_is_localised_for_both_languages():
    """The one surface iOS picks the language for, not us.

    The home-screen label exists before the app runs, so it cannot read the
    choice made in Settings — it follows the PHONE. That makes
    `InfoPlist.strings` the only mechanism, and the build setting above the
    fallback for a phone set to neither language.
    """
    for language, expected in (("uk", "Потік"), ("en", "Potik")):
        path = ROOT / f"ios/MonitorFinance/Resources/{language}.lproj/InfoPlist.strings"
        assert path.exists(), f"{language}.lproj has no InfoPlist.strings"
        assert f'"CFBundleDisplayName" = "{expected}";' in path.read_text(
            encoding="utf-8"
        ), f"the {language} home-screen label must read «{expected}»"


def test_the_name_is_transliterated_not_translated():
    """«Потік» stays that word for an English reader; only the script changes.

    The catalogue's own idiom does the work: the Ukrainian source text is the
    key, so the app's name is one ordinary row and degrades the same safe way
    as every other string.
    """
    catalogue = EN.read_text(encoding="utf-8")
    assert '"Потік" = "Potik";' in catalogue
    assert '"Увійти в Потік" = "Sign in to Potik";' in catalogue


def test_no_screen_still_says_the_working_title():
    """The four surfaces from the card, checked as an absence.

    `MonitorFinanceApp`, the test targets and the data directory legitimately
    keep the old word; a `Text` or a Face ID reason does not.
    """
    offenders = []
    for path in (ROOT / "ios/MonitorFinance").rglob("*.swift"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "MonitorFinance" not in line:
                continue
            if re.search(r'(Text\(|reason:|navigationTitle\()[^)]*"[^"]*MonitorFinance', line):
                offenders.append(f"{path.relative_to(ROOT)}:{number}")
    assert not offenders, (
        "these still show the working title to a person: " + ", ".join(offenders)
    )
