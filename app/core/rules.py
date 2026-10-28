"""Learned rules and the confirmations they came from.

Three tables, one idea: a confirmation is a fact about what the owner said; a
rule is a consequence. Rules are derived and can be withdrawn — when a
merchant has been confirmed to two different categories it is ambiguous, its
rule is dropped, and from then on it is asked every time. Note rules
(merchant + the owner's own word for the purchase) survive that, because they
are about the purchase, not the shop.

SQLite via the stdlib: no new dependency for a table of a few hundred rows.
"""
import sqlite3
import threading

_SCHEMA = """
CREATE TABLE IF NOT EXISTS rules (
    key TEXT PRIMARY KEY,
    category TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS note_rules (
    key TEXT NOT NULL,
    note_key TEXT NOT NULL,
    category TEXT NOT NULL,
    PRIMARY KEY (key, note_key)
);
CREATE TABLE IF NOT EXISTS ambiguous (
    key TEXT PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS confirmations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    key TEXT NOT NULL,
    category TEXT NOT NULL,
    note_key TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
"""


class RuleStore:
    def __init__(self, path: str = ":memory:") -> None:
        # FastAPI may call from a threadpool thread; a single connection behind
        # a lock is plenty for one owner's rules.
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(_SCHEMA)

    def is_empty(self) -> bool:
        with self._lock:
            n = self._db.execute(
                "SELECT (SELECT COUNT(*) FROM rules) + (SELECT COUNT(*) FROM ambiguous)"
            ).fetchone()[0]
        return n == 0

    def put(self, key: str, category: str) -> None:
        """Write a rule directly — seeding, not a confirmation."""
        with self._lock:
            self._db.execute(
                "INSERT INTO rules(key, category) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET category = excluded.category",
                (key, category),
            )
            self._db.commit()

    def rule(self, key: str) -> str | None:
        with self._lock:
            row = self._db.execute(
                "SELECT category FROM rules WHERE key = ?", (key,)
            ).fetchone()
        return row[0] if row else None

    def note_rule(self, key: str, note_key: str) -> str | None:
        with self._lock:
            row = self._db.execute(
                "SELECT category FROM note_rules WHERE key = ? AND note_key = ?",
                (key, note_key),
            ).fetchone()
        return row[0] if row else None

    def is_ambiguous(self, key: str) -> bool:
        with self._lock:
            row = self._db.execute(
                "SELECT 1 FROM ambiguous WHERE key = ?", (key,)
            ).fetchone()
        return row is not None

    def mark_ambiguous(self, key: str) -> None:
        with self._lock:
            self._db.execute("INSERT OR IGNORE INTO ambiguous(key) VALUES (?)", (key,))
            self._db.execute("DELETE FROM rules WHERE key = ?", (key,))
            self._db.commit()

    def confirm(self, key: str, category: str, note_key: str | None = None) -> None:
        """Record what the owner said and derive the consequences.

        Every confirmation counts toward ambiguity, note or not: Rozetka
        confirmed as Техніка (чайник) and then Подарунки (подарунок) is two
        categories for one merchant. Only a note-less confirmation writes a
        merchant rule — a note is the owner saying this was item-specific.
        """
        with self._lock:
            self._db.execute(
                "INSERT INTO confirmations(key, category, note_key) VALUES (?, ?, ?)",
                (key, category, note_key),
            )
            if note_key:
                self._db.execute(
                    "INSERT INTO note_rules(key, note_key, category) VALUES (?, ?, ?) "
                    "ON CONFLICT(key, note_key) DO UPDATE SET category = excluded.category",
                    (key, note_key, category),
                )
            distinct = self._db.execute(
                "SELECT COUNT(DISTINCT category) FROM confirmations WHERE key = ?", (key,)
            ).fetchone()[0]
            already_ambiguous = self._db.execute(
                "SELECT 1 FROM ambiguous WHERE key = ?", (key,)
            ).fetchone()
            ambiguous = distinct >= 2 or already_ambiguous
            if ambiguous:
                self._db.execute("INSERT OR IGNORE INTO ambiguous(key) VALUES (?)", (key,))
                self._db.execute("DELETE FROM rules WHERE key = ?", (key,))
            elif not note_key:
                self._db.execute(
                    "INSERT INTO rules(key, category) VALUES (?, ?) "
                    "ON CONFLICT(key) DO UPDATE SET category = excluded.category",
                    (key, category),
                )
            self._db.commit()
