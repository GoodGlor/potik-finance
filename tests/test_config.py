from pathlib import Path

from app.config import Settings

_REPO_ROOT = Path(__file__).resolve().parent.parent


def test_sqlite_path_is_parsed_from_the_url():
    assert Settings(database_url="sqlite:///./x.db").sqlite_path == str(_REPO_ROOT / "x.db")
    assert Settings(database_url="sqlite:///:memory:").sqlite_path == ":memory:"


def test_sqlite_path_is_resolved_against_the_repo_root_not_the_cwd():
    """Launching from a different directory must not silently open (and
    re-seed) a different, empty database — see app/config.py:sqlite_path."""
    settings = Settings(database_url="sqlite:///./monitorfinance.db")
    assert settings.sqlite_path == str(_REPO_ROOT / "monitorfinance.db")
    assert Path(settings.sqlite_path).is_absolute()


def test_sqlite_path_leaves_an_already_absolute_path_alone():
    settings = Settings(database_url="sqlite:////tmp/somewhere/x.db")
    assert settings.sqlite_path == "/tmp/somewhere/x.db"
