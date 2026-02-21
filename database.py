# database.py
"""
SQLite database for all findings: news, images, videos.
Severity stored as 0.0–1.0; display as 0.1–1.0.
"""

import os
import sqlite3
from datetime import datetime
from typing import Optional

from config import DB_FILENAME


def get_db_path(script_dir: str) -> str:
    return os.path.join(script_dir, DB_FILENAME)


def init_db(db_path: str) -> None:
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS findings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT,
                url TEXT NOT NULL,
                source_name TEXT,
                media_type TEXT,
                severity_score REAL,
                published_at TEXT,
                snippet TEXT,
                fetched_at TEXT,
                UNIQUE(url)
            )
        """)
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_findings_severity ON findings(severity_score)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_findings_source ON findings(source_name)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_findings_media_type ON findings(media_type)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_findings_fetched_at ON findings(fetched_at)"
        )
        conn.commit()
    finally:
        conn.close()


def insert(
    db_path: str,
    url: str,
    source_name: str,
    media_type: str,
    severity_score: float,
    title: str = "",
    published_at: str = "",
    snippet: str = "",
) -> None:
    now = datetime.utcnow().isoformat() + "Z"
    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            """
            INSERT OR REPLACE INTO findings
            (title, url, source_name, media_type, severity_score, published_at, snippet, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                (title or "")[:500],
                url[:2000],
                (source_name or "unknown")[:100],
                (media_type or "unknown")[:50],
                max(0.0, min(1.0, severity_score)),
                (published_at or "")[:50],
                (snippet or "")[:2000],
                now,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def query(
    db_path: str,
    score_min: Optional[float] = None,
    score_max: Optional[float] = None,
    source_name: Optional[str] = None,
    media_type: Optional[str] = None,
    limit: int = 500,
) -> list[dict]:
    """Return list of dicts: id, title, url, source_name, media_type, severity_score, published_at, snippet, fetched_at."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        sql = "SELECT id, title, url, source_name, media_type, severity_score, published_at, snippet, fetched_at FROM findings WHERE 1=1"
        params = []
        if score_min is not None:
            sql += " AND severity_score >= ?"
            params.append(score_min)
        if score_max is not None:
            sql += " AND severity_score <= ?"
            params.append(score_max)
        if source_name:
            sql += " AND source_name = ?"
            params.append(source_name)
        if media_type:
            sql += " AND media_type = ?"
            params.append(media_type)
        sql += " ORDER BY fetched_at DESC LIMIT ?"
        params.append(limit)
        cur = conn.execute(sql, params)
        return [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()


def get_stats(db_path: str) -> dict:
    """Total count, by source, by media_type, avg severity."""
    conn = sqlite3.connect(db_path)
    try:
        total = conn.execute("SELECT COUNT(*) FROM findings").fetchone()[0]
        by_source = dict(
            conn.execute(
                "SELECT source_name, COUNT(*) FROM findings GROUP BY source_name"
            ).fetchall()
        )
        by_type = dict(
            conn.execute(
                "SELECT media_type, COUNT(*) FROM findings GROUP BY media_type"
            ).fetchall()
        )
        avg_sev = conn.execute("SELECT AVG(severity_score) FROM findings").fetchone()[0]
        return {
            "total": total,
            "by_source": by_source,
            "by_media_type": by_type,
            "avg_severity": round(avg_sev, 2) if avg_sev is not None else 0.0,
        }
    finally:
        conn.close()


def export_csv(db_path: str, out_path: str) -> int:
    """Export all findings to CSV; return row count."""
    import csv
    rows = query(db_path, limit=10000)
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "title", "url", "source_name", "media_type", "severity_score", "published_at", "snippet", "fetched_at"])
        for r in rows:
            w.writerow([
                r.get("id"),
                r.get("title", ""),
                r.get("url", ""),
                r.get("source_name", ""),
                r.get("media_type", ""),
                r.get("severity_score", ""),
                r.get("published_at", ""),
                (r.get("snippet") or "")[:500],
                r.get("fetched_at", ""),
            ])
    return len(rows)
