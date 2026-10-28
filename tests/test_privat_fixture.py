"""Regeneration guard for scripts/build_privat_fixture.py.

Mirrors test_ios_seed.py::test_rebuild_reproduces_the_committed_seed: rebuild
into a temp directory and diff byte-for-byte against what is committed. Two
things ride on this single test:

- The committed .xlsx fixtures become load-bearing. Every Swift test reads
  the base64 constants in Generated/PrivatFixtureData.swift, not the .xlsx
  files under Fixtures/ — nothing else in the suite ever opens them, so
  without this test they could drift from the generator (or from the base64
  they are supposed to match) with nothing noticing.
- Editing SAMPLE_ROWS without re-running the script leaves the generated
  Swift silently stale and green. This makes that impossible: a changed row
  table that is not followed by a regeneration fails here.
"""

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "ios" / "MonitorFinanceTests" / "Fixtures"
GENERATED = ROOT / "ios" / "MonitorFinanceTests" / "Generated"
APP_IMPORT = ROOT / "ios" / "MonitorFinance" / "Import"


def _builder():
    spec = importlib.util.spec_from_file_location(
        "build_privat_fixture", ROOT / "scripts" / "build_privat_fixture.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_rebuild_reproduces_the_committed_fixtures(tmp_path):
    mod = _builder()
    # Redirect the module's own output paths into the temp dir rather than
    # reimplementing `build()` — the point is to exercise exactly the code
    # path that produced what is committed.
    mod.FIXTURES = tmp_path / "Fixtures"
    mod.GENERATED = tmp_path / "Generated"
    mod.APP_IMPORT = tmp_path / "Import"
    mod.build()

    for name in ("privat-sample.xlsx", "edge-cases.xlsx"):
        rebuilt = (mod.FIXTURES / name).read_bytes()
        committed = (FIXTURES / name).read_bytes()
        assert rebuilt == committed, \
            f"{name} is stale — run: uv run python scripts/build_privat_fixture.py"

    rebuilt_data = (mod.GENERATED / "PrivatFixtureData.swift").read_bytes()
    committed_data = (GENERATED / "PrivatFixtureData.swift").read_bytes()
    assert rebuilt_data == committed_data, \
        "PrivatFixtureData.swift is stale — run: uv run python scripts/build_privat_fixture.py"

    # The stub ships inside the app target, so a stale one is the costliest of
    # the four to miss — it was the only generated artifact left unguarded.
    rebuilt_stub = (mod.APP_IMPORT / "PrivatStatementStub.swift").read_bytes()
    committed_stub = (APP_IMPORT / "PrivatStatementStub.swift").read_bytes()
    assert rebuilt_stub == committed_stub, \
        "PrivatStatementStub.swift is stale — run: uv run python scripts/build_privat_fixture.py"

    rebuilt_stub = (mod.APP_IMPORT / "PrivatStatementStub.swift").read_bytes()
    committed_stub = (APP_IMPORT / "PrivatStatementStub.swift").read_bytes()
    assert rebuilt_stub == committed_stub, \
        "PrivatStatementStub.swift is stale — run: uv run python scripts/build_privat_fixture.py"
