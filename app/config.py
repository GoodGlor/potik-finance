"""Runtime configuration.

The monobank token is a secret and is read from the environment, never
committed and never logged. It is per-installation, not per-user-device — a
detail that changes if this backend ever serves more than its author.
"""
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

# The parent of the `app` package, i.e. the repo root — the anchor for a
# relative sqlite path, not whatever directory the process happens to be
# launched from.
_REPO_ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="MF_", extra="ignore")

    monobank_token: str = ""
    database_url: str = "sqlite:///./monitorfinance.db"
    log_level: str = "INFO"

    # The LLM tail is off until switched on. The cascade without it resolves
    # 108/111 of the corpus; whether it earns its place is measured, not assumed.
    llm_enabled: bool = False
    openrouter_key: str = ""
    openrouter_model: str = "meta-llama/llama-3.3-70b-instruct:free"

    @property
    def sqlite_path(self) -> str:
        """`sqlite:///./monitorfinance.db` → an absolute path next to the repo.

        Resolved against the repo root rather than left CWD-relative: `main.py`
        builds the store at import time, and launching from a different
        directory would otherwise silently open (and re-seed) an empty
        database, with every confirmation the owner ever made just gone and
        no error to say so. `:memory:` is passed through untouched.
        """
        prefix = "sqlite:///"
        if not self.database_url.startswith(prefix):
            raise ValueError(f"only sqlite URLs are supported, got {self.database_url!r}")
        raw = self.database_url[len(prefix):]
        if raw == ":memory:":
            return raw
        path = Path(raw)
        return str(path if path.is_absolute() else (_REPO_ROOT / path).resolve())


settings = Settings()
