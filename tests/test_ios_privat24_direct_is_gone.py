"""Board #172 — «Спосіб 2: напряму в Приват24» does not work, so it is gone.

The owner tried it against a real Privat24 account and it did not work. That
is the whole of the direct evidence, and it is enough: they are the only
person who has attempted it.

**The card asked whether the app was burying a verification letter**, which
would have made this a bug to fix rather than a method to delete. Two things
were checked before cutting:

1. The live mailbox. Every letter keeps `from` and `subject` indefinitely, so
   anything Privat24 ever sent to an issued address leaves a row. The
   surviving database holds **three** letters — `gmail.com` (transaction),
   `google.com` (forwarding confirmation) and `pb.ua` (statement link). No
   Privat24 sender, ever.

   With one honest caveat: the account the owner actually tried this against
   was deleted at 10:01 UTC on 2026-08-31 by the reset board #168 fixed, and
   its letter rows went with it. That evidence cannot be recovered.

2. `app/inbound.py`'s `classify`. **Nothing is discarded without trace.** A
   letter from an unrecognised sender that carries no Privat markers is filed
   as `kind="other"` and its row is kept; one that carries them but does not
   parse is kept with a visible `parse_error`. So a verification letter would
   have left a row either way, and the "the app is silently eating it"
   hypothesis has no path in the code to be true through.

What the app cannot do is SHOW any of that to the person — a letter arrives
and the count simply fails to move. That is board #175, and it is why this
file records the reasoning rather than leaving it in a merge commit.

This is a source guard because the failure it prevents is a re-appearance:
the instruction lived in two places, and deleting one would leave the other
telling people to do something that does not work.
"""

from tests.test_ios_seed import ROOT, _code_only

APP = ROOT / "ios" / "MonitorFinance"
SETUP = APP / "Banks" / "PrivatEmailSetupView.swift"
CATALOGUE = APP / "Resources" / "en.lproj" / "Localizable.strings"

#: The instruction, in both the places it lived. The second is the one that
#: makes this a guard rather than a deletion: the address card repeated the
#: claim in a single sentence, so removing only the card would have left the
#: dead method advertised one card higher.
GONE = (
    "напряму в Приват24",
    "пошту для сповіщень",
    "Або в Приват24",
    "directCard",
)


def test_the_direct_method_is_not_offered_anywhere():
    swift = _code_only(SETUP.read_text(encoding="utf-8"))
    catalogue = CATALOGUE.read_text(encoding="utf-8")

    offenders = [
        f"{name} in {path}"
        for name in GONE
        for path, text in (("PrivatEmailSetupView.swift", swift),
                           ("en.lproj/Localizable.strings", catalogue))
        if name in text
    ]

    assert offenders == [], (
        f"the direct-notification method is back: {offenders}. It does not "
        "work — a method nobody can complete costs the person a trip into "
        "Privat24 to discover nothing, which is the expensive kind of "
        "clutter. If new evidence says it CAN work, delete this guard "
        "deliberately and say what changed."
    )


def test_the_methods_are_not_numbered():
    """«Спосіб 1» and «Спосіб 3» with nothing between them reads as a missing
    step, and renumbering to 1 and 2 would restore a claim that was never
    true: these are not alternatives. One is how purchases start arriving; the
    other is how everything from before today gets here.
    """
    swift = _code_only(SETUP.read_text(encoding="utf-8"))

    assert "Спосіб" not in swift, (
        "a numbered method is back on the mail screen. A number implies a "
        "sequence to work through and a choice between equals, and neither "
        "is true of the two cards that remain."
    )


def test_the_guard_can_fire():
    """A clean run above has to mean something.

    Both tests scan for the ABSENCE of a string, which passes just as happily
    when it is reading the wrong file. Pin one string that must still be
    there, from each thing being read.
    """
    swift = _code_only(SETUP.read_text(encoding="utf-8"))
    catalogue = CATALOGUE.read_text(encoding="utf-8")

    assert "forwardingCard" in swift, "not reading the mail setup screen"
    assert "Пересилання з вашої пошти" in swift, "the method that DOES work is gone too"
    assert "Історія одним файлом" in swift, "the file import is gone too"
    assert '"Пересилання з вашої пошти" =' in catalogue, "not reading the catalogue"
