from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from local_llm.contracts import RetrievalResult, SupportMetadata, WarningItem
from local_llm.store.migrations import SCHEMA_SQL


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


@dataclass(frozen=True)
class ActiveDocument:
    document_id: str
    file_hash: str


class SQLiteStore:
    def __init__(self, db_path: Path):
        self.db_path = db_path

    def init(self) -> None:
        with connect(self.db_path) as db:
            db.executescript(SCHEMA_SQL)

    def fts5_available(self) -> bool:
        with connect(self.db_path) as db:
            try:
                db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS temp.fts_probe USING fts5(x)")
                return True
            except sqlite3.DatabaseError:
                return False

    def get_active_document_for_source(self, source_id: str) -> ActiveDocument | None:
        with connect(self.db_path) as db:
            row = db.execute(
                "SELECT document_id, file_hash FROM documents WHERE source_id = ? AND is_active = 1 ORDER BY indexed_at DESC LIMIT 1",
                (source_id,),
            ).fetchone()
        return ActiveDocument(**dict(row)) if row else None

    def upsert_document_with_chunks(self, *, source: dict[str, Any], document: dict[str, Any], chunks: list[dict[str, Any]]) -> None:
        now = utc_now()
        with connect(self.db_path) as db:
            db.execute("BEGIN")
            try:
                db.execute("UPDATE sources SET is_active = 0 WHERE source_id = ?", (source["source_id"],))
                db.execute(
                    """
                    INSERT OR REPLACE INTO sources
                    (source_id, corpus_id, source_type, title, origin_uri_or_path, source_version,
                     content_hash, fetched_or_indexed_at, license_label, metadata_json, is_active)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                    (
                        source["source_id"], source["corpus_id"], source["source_type"],
                        source["title"], source["origin_uri_or_path"], source.get("source_version"),
                        source["content_hash"], now, source.get("license_label"),
                        json.dumps(source.get("metadata", {})),
                    ),
                )

                old_chunks = db.execute(
                    "SELECT chunk_id FROM chunks WHERE source_id = ? AND is_active = 1",
                    (source["source_id"],),
                ).fetchall()
                old_chunk_ids = [row["chunk_id"] for row in old_chunks]

                db.execute("UPDATE documents SET is_active = 0 WHERE source_id = ?", (source["source_id"],))
                db.execute("UPDATE chunks SET is_active = 0 WHERE source_id = ?", (source["source_id"],))
                if old_chunk_ids:
                    db.executemany("DELETE FROM chunks_fts WHERE chunk_id = ?", [(cid,) for cid in old_chunk_ids])

                db.execute(
                    """
                    INSERT OR REPLACE INTO documents
                    (document_id, source_id, corpus_id, path, relative_path, file_hash,
                     mtime_ns, size_bytes, extension, indexed_at, metadata_json, is_active)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                    (
                        document["document_id"], document["source_id"], document["corpus_id"],
                        document["path"], document["relative_path"], document["file_hash"],
                        document["mtime_ns"], document["size_bytes"], document["extension"],
                        now, json.dumps(document.get("metadata", {})),
                    ),
                )

                for chunk in chunks:
                    db.execute(
                        """
                        INSERT OR REPLACE INTO chunks
                        (chunk_id, document_id, source_id, corpus_id, ordinal, text, text_hash,
                         char_start, char_end, token_estimate, metadata_json, is_active)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                        """,
                        (
                            chunk["chunk_id"], chunk["document_id"], chunk["source_id"],
                            chunk["corpus_id"], chunk["ordinal"], chunk["text"], chunk["text_hash"],
                            chunk["char_start"], chunk["char_end"], chunk["token_estimate"],
                            json.dumps(chunk.get("metadata", {})),
                        ),
                    )
                    db.execute("INSERT INTO chunks_fts (chunk_id, text) VALUES (?, ?)", (chunk["chunk_id"], chunk["text"]))

                db.commit()
            except Exception:
                db.rollback()
                raise

    def mark_missing_sources_inactive(self, corpus_id: str, active_source_ids: set[str]) -> None:
        with connect(self.db_path) as db:
            rows = db.execute("SELECT source_id FROM sources WHERE corpus_id = ? AND is_active = 1", (corpus_id,)).fetchall()
            missing = [row["source_id"] for row in rows if row["source_id"] not in active_source_ids]
            if not missing:
                return
            db.execute("BEGIN")
            try:
                for source_id in missing:
                    chunk_rows = db.execute("SELECT chunk_id FROM chunks WHERE source_id = ? AND is_active = 1", (source_id,)).fetchall()
                    chunk_ids = [row["chunk_id"] for row in chunk_rows]
                    db.execute("UPDATE sources SET is_active = 0 WHERE source_id = ?", (source_id,))
                    db.execute("UPDATE documents SET is_active = 0 WHERE source_id = ?", (source_id,))
                    db.execute("UPDATE chunks SET is_active = 0 WHERE source_id = ?", (source_id,))
                    if chunk_ids:
                        db.executemany("DELETE FROM chunks_fts WHERE chunk_id = ?", [(cid,) for cid in chunk_ids])
                db.commit()
            except Exception:
                db.rollback()
                raise

    def search_chunks(self, query: str, corpus_id: str, top_k: int) -> list[RetrievalResult]:
        fts_query = make_fts_query(query)
        if not fts_query:
            return []
        with connect(self.db_path) as db:
            rows = db.execute(
                """
                SELECT c.chunk_id, c.document_id, c.source_id, d.path AS document_path,
                       s.title AS source_title, s.source_version AS source_version,
                       f.text AS text, bm25(chunks_fts) AS score
                FROM chunks_fts f
                JOIN chunks c ON c.chunk_id = f.chunk_id
                JOIN documents d ON d.document_id = c.document_id
                JOIN sources s ON s.source_id = c.source_id
                WHERE chunks_fts MATCH ?
                  AND c.corpus_id = ?
                  AND c.is_active = 1
                  AND d.is_active = 1
                  AND s.is_active = 1
                ORDER BY score ASC
                LIMIT ?
                """,
                (fts_query, corpus_id, top_k),
            ).fetchall()
        return [
            RetrievalResult(
                rank=i,
                method="sqlite_fts",
                chunk_id=row["chunk_id"],
                document_id=row["document_id"],
                source_id=row["source_id"],
                document_path=row["document_path"],
                source_title=row["source_title"],
                source_version=row["source_version"],
                score=float(row["score"]),
                raw_score=float(row["score"]),
                normalized_score=None,
                text=row["text"],
            )
            for i, row in enumerate(rows, start=1)
        ]

    def insert_run(self, *, run_id: str, workflow_id: str, workflow_kind: str, model_profile: str, rag_profile: str, prompt_profile: str, user_input: str, final_prompt: str, response_text: str, latency_ms: int, support: SupportMetadata, warnings: list[WarningItem], metadata: dict[str, Any], retrievals: list[RetrievalResult]) -> None:
        with connect(self.db_path) as db:
            db.execute("BEGIN")
            try:
                db.execute(
                    """
                    INSERT INTO runs
                    (run_id, workflow_id, workflow_kind, model_profile, rag_profile, prompt_profile,
                     user_input, final_prompt, response_text, created_at, latency_ms, support_json,
                     warnings_json, metadata_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        run_id, workflow_id, workflow_kind, model_profile, rag_profile, prompt_profile,
                        user_input, final_prompt, response_text, utc_now(), latency_ms,
                        support.model_dump_json(), json.dumps([w.model_dump() for w in warnings]),
                        json.dumps(metadata),
                    ),
                )
                for r in retrievals:
                    db.execute(
                        """
                        INSERT INTO run_retrievals
                        (run_id, chunk_id, source_id, document_id, rank, method, score, raw_score,
                         normalized_score, document_path, source_title, source_version, chunk_text_snapshot)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            run_id, r.chunk_id, r.source_id, r.document_id, r.rank, r.method,
                            r.score, r.raw_score, r.normalized_score, r.document_path,
                            r.source_title, r.source_version, r.text,
                        ),
                    )
                db.commit()
            except Exception:
                db.rollback()
                raise

    def insert_run_artifact(self, *, run_id: str, artifact_type: str, path: str, content_hash: str, metadata: dict[str, Any] | None = None) -> None:
        with connect(self.db_path) as db:
            db.execute(
                """
                INSERT OR REPLACE INTO run_artifacts
                (run_id, artifact_type, path, content_hash, created_at, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (run_id, artifact_type, path, content_hash, utc_now(), json.dumps(metadata or {})),
            )

    def summary(self) -> dict[str, int]:
        with connect(self.db_path) as db:
            return {
                "sources": db.execute("SELECT COUNT(*) AS n FROM sources WHERE is_active = 1").fetchone()["n"],
                "documents": db.execute("SELECT COUNT(*) AS n FROM documents WHERE is_active = 1").fetchone()["n"],
                "chunks": db.execute("SELECT COUNT(*) AS n FROM chunks WHERE is_active = 1").fetchone()["n"],
                "runs": db.execute("SELECT COUNT(*) AS n FROM runs").fetchone()["n"],
                "run_retrievals": db.execute("SELECT COUNT(*) AS n FROM run_retrievals").fetchone()["n"],
                "run_artifacts": db.execute("SELECT COUNT(*) AS n FROM run_artifacts").fetchone()["n"],
            }

    def get_run(self, run_id: str) -> dict[str, object] | None:
        with connect(self.db_path) as db:
            row = db.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()
        return dict(row) if row else None

    def get_run_retrievals(self, run_id: str) -> list[dict[str, object]]:
        with connect(self.db_path) as db:
            rows = db.execute("SELECT * FROM run_retrievals WHERE run_id = ? ORDER BY rank", (run_id,)).fetchall()
        return [dict(row) for row in rows]

    def get_run_artifacts(self, run_id: str) -> list[dict[str, object]]:
        with connect(self.db_path) as db:
            rows = db.execute("SELECT * FROM run_artifacts WHERE run_id = ? ORDER BY artifact_type", (run_id,)).fetchall()
        return [dict(row) for row in rows]

    def _session_from_row(self, row: sqlite3.Row) -> dict[str, object]:
        data = dict(row)
        raw_metadata = data.pop("metadata_json", "{}") or "{}"
        try:
            data["metadata"] = json.loads(raw_metadata)
        except json.JSONDecodeError:
            data["metadata"] = {}
        data["turn_count"] = int(data.get("turn_count") or 0)
        return data

    def _turn_from_row(self, row: sqlite3.Row) -> dict[str, object]:
        data = dict(row)
        raw_metadata = data.pop("metadata_json", "{}") or "{}"
        try:
            data["metadata"] = json.loads(raw_metadata)
        except json.JSONDecodeError:
            data["metadata"] = {}
        return data

    def create_session(
        self,
        *,
        session_id: str,
        title: str,
        description: str,
        default_workflow_id: str,
        default_model_profile: str | None,
        default_rag_profile: str | None,
        default_prompt_profile: str | None,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, object]:
        now = utc_now()
        with connect(self.db_path) as db:
            db.execute(
                """
                INSERT INTO sessions
                (session_id, title, description, default_workflow_id, default_model_profile,
                 default_rag_profile, default_prompt_profile, created_at, updated_at, archived_at, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                """,
                (
                    session_id, title, description, default_workflow_id, default_model_profile,
                    default_rag_profile, default_prompt_profile, now, now, json.dumps(metadata or {}),
                ),
            )
        session = self.get_session(session_id)
        if session is None:
            raise RuntimeError("created session was not found")
        return session

    def list_sessions(self, *, include_archived: bool = False) -> list[dict[str, object]]:
        where = "" if include_archived else "WHERE s.archived_at IS NULL"
        with connect(self.db_path) as db:
            rows = db.execute(
                f"""
                SELECT s.*,
                       COUNT(t.turn_id) AS turn_count,
                       (SELECT t2.run_id FROM turns t2 WHERE t2.session_id = s.session_id ORDER BY t2.ordinal DESC LIMIT 1) AS latest_run_id,
                       (SELECT t3.created_at FROM turns t3 WHERE t3.session_id = s.session_id ORDER BY t3.ordinal DESC LIMIT 1) AS latest_turn_at
                FROM sessions s
                LEFT JOIN turns t ON t.session_id = s.session_id
                {where}
                GROUP BY s.session_id
                ORDER BY COALESCE(latest_turn_at, s.updated_at) DESC
                """
            ).fetchall()
        return [self._session_from_row(row) for row in rows]

    def get_session(self, session_id: str) -> dict[str, object] | None:
        with connect(self.db_path) as db:
            row = db.execute(
                """
                SELECT s.*,
                       COUNT(t.turn_id) AS turn_count,
                       (SELECT t2.run_id FROM turns t2 WHERE t2.session_id = s.session_id ORDER BY t2.ordinal DESC LIMIT 1) AS latest_run_id,
                       (SELECT t3.created_at FROM turns t3 WHERE t3.session_id = s.session_id ORDER BY t3.ordinal DESC LIMIT 1) AS latest_turn_at
                FROM sessions s
                LEFT JOIN turns t ON t.session_id = s.session_id
                WHERE s.session_id = ?
                GROUP BY s.session_id
                """,
                (session_id,),
            ).fetchone()
        return self._session_from_row(row) if row else None

    def update_session(
        self,
        *,
        session_id: str,
        title: str | None = None,
        description: str | None = None,
        default_workflow_id: str | None = None,
        default_model_profile: str | None = None,
        default_rag_profile: str | None = None,
        default_prompt_profile: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, object] | None:
        assignments: list[str] = []
        values: list[Any] = []
        fields = {
            "title": title,
            "description": description,
            "default_workflow_id": default_workflow_id,
            "default_model_profile": default_model_profile,
            "default_rag_profile": default_rag_profile,
            "default_prompt_profile": default_prompt_profile,
        }
        for name, value in fields.items():
            if value is not None:
                assignments.append(f"{name} = ?")
                values.append(value)
        if metadata is not None:
            assignments.append("metadata_json = ?")
            values.append(json.dumps(metadata))
        assignments.append("updated_at = ?")
        values.append(utc_now())
        values.append(session_id)
        with connect(self.db_path) as db:
            db.execute(f"UPDATE sessions SET {', '.join(assignments)} WHERE session_id = ?", values)
        return self.get_session(session_id)

    def archive_session(self, session_id: str) -> dict[str, object] | None:
        now = utc_now()
        with connect(self.db_path) as db:
            db.execute("UPDATE sessions SET archived_at = ?, updated_at = ? WHERE session_id = ?", (now, now, session_id))
        return self.get_session(session_id)

    def create_turn(self, *, turn_id: str, session_id: str, user_input: str, metadata: dict[str, Any] | None = None) -> dict[str, object]:
        now = utc_now()
        with connect(self.db_path) as db:
            row = db.execute("SELECT COALESCE(MAX(ordinal), 0) + 1 AS next_ordinal FROM turns WHERE session_id = ?", (session_id,)).fetchone()
            ordinal = int(row["next_ordinal"])
            db.execute(
                """
                INSERT INTO turns
                (turn_id, session_id, ordinal, user_input, run_id, created_at, metadata_json)
                VALUES (?, ?, ?, ?, NULL, ?, ?)
                """,
                (turn_id, session_id, ordinal, user_input, now, json.dumps(metadata or {})),
            )
            db.execute("UPDATE sessions SET updated_at = ? WHERE session_id = ?", (now, session_id))
        turn = self.get_turn(turn_id)
        if turn is None:
            raise RuntimeError("created turn was not found")
        return turn

    def link_turn_run(self, turn_id: str, run_id: str) -> None:
        with connect(self.db_path) as db:
            db.execute("UPDATE turns SET run_id = ? WHERE turn_id = ?", (run_id, turn_id))

    def get_turn(self, turn_id: str) -> dict[str, object] | None:
        with connect(self.db_path) as db:
            row = db.execute("SELECT * FROM turns WHERE turn_id = ?", (turn_id,)).fetchone()
        return self._turn_from_row(row) if row else None

    def list_turns(self, session_id: str) -> list[dict[str, object]]:
        with connect(self.db_path) as db:
            rows = db.execute("SELECT * FROM turns WHERE session_id = ? ORDER BY ordinal", (session_id,)).fetchall()
        return [self._turn_from_row(row) for row in rows]

    def list_runs(self, *, limit: int = 50) -> list[dict[str, object]]:
        with connect(self.db_path) as db:
            rows = db.execute(
                """
                SELECT run_id, workflow_id, workflow_kind, model_profile, rag_profile, prompt_profile,
                       user_input, response_text, created_at, latency_ms, support_json, warnings_json
                FROM runs
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        out: list[dict[str, object]] = []
        for row in rows:
            data = dict(row)
            response_text = str(data.pop("response_text") or "")
            data["response_preview"] = response_text[:240]
            try:
                data["support"] = json.loads(str(data.pop("support_json") or "{}"))
            except json.JSONDecodeError:
                data["support"] = {}
            try:
                data["warnings"] = json.loads(str(data.pop("warnings_json") or "[]"))
            except json.JSONDecodeError:
                data["warnings"] = []
            out.append(data)
        return out


def make_fts_query(query: str) -> str:
    import re
    terms = re.findall(r"[\w-]+", query.lower())
    terms = [term for term in terms if len(term) > 1]
    if not terms:
        return ""
    return " OR ".join(f'"{term}"' for term in terms[:24])
