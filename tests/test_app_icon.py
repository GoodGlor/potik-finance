"""Board #108 — the app icon, and the three background rules that differ.

The icon is GENERATED (`scripts/build_app_icon.py`), so the risk here is not a
designer's slip — it is somebody regenerating it later with the wrong
background rule and nobody noticing until it ships. The three variants do NOT
share a rule, which is the whole reason this file exists:

    light   opaque   — the app's own warm off-white
    dark    TRANSPARENT — iOS draws the background itself
    tinted  OPAQUE greyscale on black — iOS tints the LUMINANCE, so a
            transparent tinted variant loses the shape the tint follows

The tinted rule was got wrong on the first pass of this card: it shipped
transparent, like the dark one, because "dark and tinted both get a system
background" is the obvious wrong generalisation. These assertions are what that
mistake cost.
"""

import json

import pytest
from PIL import Image, ImageChops

from tests.test_ios_seed import ROOT

ICONS = ROOT / "ios/MonitorFinance/Assets.xcassets/AppIcon.appiconset"
PBXPROJ = ROOT / "ios/MonitorFinance.xcodeproj/project.pbxproj"

VARIANTS = ("light", "dark", "tinted")


def _icon(name):
    return Image.open(ICONS / f"icon-{name}.png").convert("RGBA")


@pytest.mark.parametrize("name", VARIANTS)
def test_every_variant_is_a_1024_square(name):
    """A single 1024 pt asset, which is all Xcode's single-size icon wants."""
    assert _icon(name).size == (1024, 1024), f"icon-{name}.png is not 1024x1024"


def test_the_light_variant_is_fully_opaque():
    """The light variant is the one iOS does NOT draw a background for."""
    low, _ = _icon("light").getchannel("A").getextrema()
    assert low == 255, "the light icon must be opaque — iOS supplies no background for it"


def test_the_dark_variant_is_transparent():
    """Transparent, because the system fills it. An opaque dark variant would
    paint over the background iOS wants to draw."""
    low, high = _icon("dark").getchannel("A").getextrema()
    assert low == 0, "the dark icon needs a transparent background — iOS draws its own"
    assert high == 255, "the dark icon still needs an opaque mark to draw"


def test_the_tinted_variant_is_opaque_greyscale():
    """**The one that was wrong.** Opaque, and grey — the system reads the
    luminance and composites its own gradient through it."""
    image = _icon("tinted")
    low, _ = image.getchannel("A").getextrema()
    assert low == 255, (
        "the tinted icon must be OPAQUE, not transparent like the dark one — "
        "iOS tints the luminance and needs a filled image to tint through"
    )
    assert _colour_spread(image) == 0, "the tinted icon must be greyscale"


def _colour_spread(image):
    """The largest gap between any two channels — 0 for a greyscale image.

    Channel arithmetic rather than a per-pixel loop: `getdata()` is deprecated
    in Pillow 12 and removed in 14, and its replacement does not exist in the
    version floor this repo pins.
    """
    r, g, b = image.convert("RGB").split()
    return max(
        ImageChops.difference(r, g).getextrema()[1],
        ImageChops.difference(g, b).getextrema()[1],
    )


def test_the_greyscale_check_can_actually_fire():
    """The assertion above passes on any grey image, including a blank one.
    This proves it distinguishes grey from coloured at all — with the app's own
    green, the exact colour that must never reach the tinted variant."""
    coloured = Image.new("RGBA", (8, 8), (52, 139, 113, 255))
    assert _colour_spread(coloured) > 0, (
        "a coloured image must not read as greyscale, or the tinted guard proves nothing"
    )


def test_the_catalogue_declares_all_three_appearances():
    contents = json.loads((ICONS / "Contents.json").read_text("utf-8"))
    by_file = {i["filename"]: i for i in contents["images"]}
    assert set(by_file) == {f"icon-{v}.png" for v in VARIANTS}

    assert "appearances" not in by_file["icon-light.png"], (
        "the light variant is the unqualified default and carries no appearance"
    )
    for name in ("dark", "tinted"):
        appearances = by_file[f"icon-{name}.png"]["appearances"]
        assert appearances == [{"appearance": "luminosity", "value": name}], (
            f"icon-{name}.png must be tagged luminosity/{name} or iOS never uses it"
        )


def test_the_catalogue_holds_only_the_app_icon():
    """The other side of the allowance in `test_ios_seed.py`.

    That file stopped treating `.xcassets` contents as unreviewed resources on
    the grounds that a catalogue is COMPILED, not copied. True — but it means
    anything dropped inside a catalogue is now invisible to the stray check, so
    the catalogue's own contents are named here instead. A second `.imageset`
    appearing without a decision is exactly what this notices.
    """
    catalogue = ICONS.parent
    assert [p.name for p in sorted(catalogue.iterdir())] == ["AppIcon.appiconset", "Contents.json"]
    assert {p.name for p in ICONS.iterdir()} == {
        "Contents.json", *(f"icon-{v}.png" for v in VARIANTS)
    }


def test_both_app_configurations_name_the_icon():
    """Debug AND Release. A setting in one configuration only is how an icon
    ships in TestFlight and is missing from the App Store build.

    The three test targets deliberately do NOT get this — they have no icon.
    """
    source = PBXPROJ.read_text("utf-8")
    named = source.count("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
    app_configs = source.count("PRODUCT_BUNDLE_IDENTIFIER = ua.monitorfinance.app;")
    assert app_configs == 2, f"expected 2 app build configurations, found {app_configs}"
    assert named == 2, (
        f"the icon is named in {named} configuration(s), not both — "
        "Debug and Release each need it"
    )
