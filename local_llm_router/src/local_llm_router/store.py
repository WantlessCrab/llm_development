from __future__ import annotations

import json
import re
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .format_capture import FormatCapture, model_to_dict
from .models import CaptureEvent, DraftItem, QueueGroupItem

DEFAULT_QUEUE_GROUP_ID = "default"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


def _json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, default=str)


def _json_loads_dict(value: str | None) -> dict[str, Any]:
    if not value:
        return {}
    try:
        parsed = json.loads(value)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return {}


def _slugish(value: str) -> str:
    text = re.sub(r"[^a-zA-Z0-9]+", "-", value.strip().lower()).strip("-")
    return text[:36] or "queue"


def _queue_group_name_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.strip().casefold())


class Store:
    def __init__(self, db_path: Path):
        self.db_path = db_path

    def init(self) -> None:
        with connect(self.db_path) as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS sessions
                (
                    session_id
                    TEXT
                    PRIMARY
                    KEY,
                    provider
                    TEXT
                    NOT
                    NULL,
                    conversation_id
                    TEXT,
                    gizmo_id
                    TEXT,
                    url
                    TEXT,
                    title
                    TEXT,
                    first_seen_at
                    TEXT
                    NOT
                    NULL,
                    last_seen_at
                    TEXT
                    NOT
                    NULL,
                    status
                    TEXT
                    NOT
                    NULL
                    DEFAULT
                    'active',
                    metadata_json
                    TEXT
                    NOT
                    NULL
                    DEFAULT
                    '{}'
                );

                CREATE TABLE IF NOT EXISTS messages
                (
                    message_id
                    TEXT
                    PRIMARY
                    KEY,
                    source_session_id
                    TEXT
                    NOT
                    NULL,
                    provider
                    TEXT
                    NOT
                    NULL,
                    conversation_id
                    TEXT,
                    gizmo_id
                    TEXT,
                    role
                    TEXT
                    NOT
                    NULL,
                    turn_testid
                    TEXT,
                    capture_source
                    TEXT
                    NOT
                    NULL,
                    body
                    TEXT
                    NOT
                    NULL,
                    body_hash
                    TEXT
                    NOT
                    NULL,
                    body_length
                    INTEGER
                    NOT
                    NULL,
                    captured_at
                    TEXT
                    NOT
                    NULL,
                    created_at
                    TEXT
                    NOT
                    NULL,
                    dedupe_key
                    TEXT
                    NOT
                    NULL
                    UNIQUE,
                    metadata_json
                    TEXT
                    NOT
                    NULL
                    DEFAULT
                    '{}',
                    FOREIGN
                    KEY
                (
                    source_session_id
                ) REFERENCES sessions
                (
                    session_id
                )
                    );

                CREATE TABLE IF NOT EXISTS deliveries
                (
                    delivery_id
                    TEXT
                    PRIMARY
                    KEY,
                    message_id
                    TEXT
                    NOT
                    NULL,
                    route_id
                    TEXT
                    NOT
                    NULL,
                    target_type
                    TEXT
                    NOT
                    NULL,
                    target_id
                    TEXT
                    NOT
                    NULL,
                    status
                    TEXT
                    NOT
                    NULL,
                    wrapped_body
                    TEXT
                    NOT
                    NULL,
                    attempt_count
                    INTEGER
                    NOT
                    NULL
                    DEFAULT
                    0,
                    queued_at
                    TEXT
                    NOT
                    NULL,
                    delivered_at
                    TEXT,
                    acknowledged_at
                    TEXT,
                    error
                    TEXT,
                    metadata_json
                    TEXT
                    NOT
                    NULL
                    DEFAULT
                    '{}',
                    FOREIGN
                    KEY
                (
                    message_id
                ) REFERENCES messages
                (
                    message_id
                )
                    );

                CREATE TABLE IF NOT EXISTS audit_events
                (
                    event_id
                    TEXT
                    PRIMARY
                    KEY,
                    event_type
                    TEXT
                    NOT
                    NULL,
                    entity_type
                    TEXT
                    NOT
                    NULL,
                    entity_id
                    TEXT
                    NOT
                    NULL,
                    created_at
                    TEXT
                    NOT
                    NULL,
                    payload_json
                    TEXT
                    NOT
                    NULL
                );

                CREATE INDEX IF NOT EXISTS idx_messages_session_created
                    ON messages(source_session_id, created_at);

                CREATE INDEX IF NOT EXISTS idx_deliveries_status
                    ON deliveries(status, queued_at);

                CREATE INDEX IF NOT EXISTS idx_deliveries_target_status
                    ON deliveries(target_type, target_id, status, queued_at);
                """
            )
            self._migrate_format_capture_columns(db)
            self._migrate_queue_group_schema(db)

    def _table_columns(self, db: sqlite3.Connection, table: str) -> set[str]:
        rows = db.execute(f"PRAGMA table_info({table})").fetchall()
        return {str(row["name"]) for row in rows}

    def _add_column_if_missing(
            self,
            db: sqlite3.Connection,
            *,
            table: str,
            column: str,
            definition: str,
    ) -> None:
        if column not in self._table_columns(db, table):
            db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")

    def _migrate_format_capture_columns(self, db: sqlite3.Connection) -> None:
        for column, definition in {
            "body_markdown": "TEXT",
            "body_plain": "TEXT",
            "body_html": "TEXT",
            "format_capture_json": "TEXT NOT NULL DEFAULT '{}'",
            "format_version": "TEXT",
            "format_diagnostics_json": "TEXT NOT NULL DEFAULT '{}'",
        }.items():
            self._add_column_if_missing(db, table="messages", column=column, definition=definition)

        for column, definition in {
            "wrapped_body_markdown": "TEXT",
            "wrapped_body_plain": "TEXT",
            "wrapped_body_html": "TEXT",
            "wrapped_format_capture_json": "TEXT NOT NULL DEFAULT '{}'",
            "format_version": "TEXT",
            "format_diagnostics_json": "TEXT NOT NULL DEFAULT '{}'",
        }.items():
            self._add_column_if_missing(db, table="deliveries", column=column,
                                        definition=definition)

        db.execute("UPDATE messages SET body_markdown = body WHERE body_markdown IS NULL")
        db.execute("UPDATE messages SET body_plain = body WHERE body_plain IS NULL")
        db.execute(
            "UPDATE deliveries SET wrapped_body_markdown = wrapped_body "
            "WHERE wrapped_body_markdown IS NULL"
        )
        db.execute(
            "UPDATE deliveries SET wrapped_body_plain = wrapped_body "
            "WHERE wrapped_body_plain IS NULL"
        )

    def _migrate_queue_group_schema(self, db: sqlite3.Connection) -> None:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS queue_groups
            (
                queue_group_id
                TEXT
                PRIMARY
                KEY,
                name
                TEXT
                NOT
                NULL,
                status
                TEXT
                NOT
                NULL
                DEFAULT
                'active',
                is_default
                INTEGER
                NOT
                NULL
                DEFAULT
                0,
                created_at
                TEXT
                NOT
                NULL,
                updated_at
                TEXT
                NOT
                NULL
            );

            CREATE TABLE IF NOT EXISTS session_queue_groups
            (
                source_session_id
                TEXT
                PRIMARY
                KEY,
                provider
                TEXT,
                label
                TEXT,
                queue_group_id
                TEXT
                NOT
                NULL,
                assigned_at
                TEXT
                NOT
                NULL
            );
            """
        )

        now = utc_now()
        db.execute(
            """
            INSERT
            OR IGNORE INTO queue_groups
            (queue_group_id, name, status, is_default, created_at, updated_at)
            VALUES ('default', 'Default queue', 'active', 1, ?, ?)
            """,
            (now, now),
        )

        for column, definition in {
            "queue_group_id": "TEXT NOT NULL DEFAULT 'default'",
            "cancelled_at": "TEXT",
        }.items():
            self._add_column_if_missing(db, table="deliveries", column=column,
                                        definition=definition)

        db.execute(
            "UPDATE deliveries SET queue_group_id = 'default' "
            "WHERE queue_group_id IS NULL OR queue_group_id = ''"
        )

        db.executescript(
            """
            CREATE INDEX IF NOT EXISTS idx_deliveries_queue_group_status
                ON deliveries(queue_group_id, status, queued_at);

            CREATE INDEX IF NOT EXISTS idx_session_queue_groups_group
                ON session_queue_groups(queue_group_id);
            """
        )

    def _queue_group_item_from_row(self, row: sqlite3.Row) -> QueueGroupItem:
        return QueueGroupItem(
            queue_group_id=str(row["queue_group_id"]),
            name=str(row["name"]),
            status=str(row["status"]),
            is_default=bool(row["is_default"]),
            created_at=str(row["created_at"]),
            updated_at=str(row["updated_at"]),
        )

    def _get_queue_group_with_db(
            self,
            db: sqlite3.Connection,
            queue_group_id: str,
            *,
            active_only: bool = True,
    ) -> QueueGroupItem | None:
        clause = "AND status='active'" if active_only else ""
        row = db.execute(
            f"""
            SELECT queue_group_id, name, status, is_default, created_at, updated_at
            FROM queue_groups
            WHERE queue_group_id = ? {clause}
            """,
            (queue_group_id,),
        ).fetchone()
        return self._queue_group_item_from_row(row) if row else None

    def get_queue_group(self, queue_group_id: str = DEFAULT_QUEUE_GROUP_ID) -> QueueGroupItem:
        with connect(self.db_path) as db:
            group = self._get_queue_group_with_db(db, queue_group_id)
            if group:
                return group
            return self._get_queue_group_with_db(db, DEFAULT_QUEUE_GROUP_ID,
                                                 active_only=False)  # type: ignore[return-value]

    def list_queue_groups(self, include_deleted: bool = False) -> list[QueueGroupItem]:
        clause = "" if include_deleted else "WHERE status='active'"
        with connect(self.db_path) as db:
            rows = db.execute(
                f"""
                SELECT queue_group_id, name, status, is_default, created_at, updated_at
                FROM queue_groups
                {clause}
                ORDER BY is_default DESC, lower(name) ASC
                """
            ).fetchall()
        return [self._queue_group_item_from_row(row) for row in rows]

    def create_queue_group(self, name: str) -> QueueGroupItem:
        clean_name = " ".join((name or "").strip().split()) or "New queue"
        requested_key = _queue_group_name_key(clean_name)
        base = _slugish(clean_name)
        now = utc_now()

        with connect(self.db_path) as db:
            existing_rows = db.execute(
                """
                SELECT queue_group_id, name, status, is_default, created_at, updated_at
                FROM queue_groups
                WHERE status='active'
                ORDER BY is_default DESC, created_at ASC
                """
            ).fetchall()

            for row in existing_rows:
                if _queue_group_name_key(str(row["name"])) == requested_key:
                    existing = self._queue_group_item_from_row(row)
                    self._audit_with_db(
                        db,
                        "queue_group.reused",
                        "queue_group",
                        existing.queue_group_id,
                        {"requested_name": clean_name, "existing_name": existing.name},
                    )
                    return existing

            queue_group_id = f"{base}-{uuid.uuid4().hex[:8]}"
            db.execute(
                """
                INSERT INTO queue_groups
                    (queue_group_id, name, status, is_default, created_at, updated_at)
                VALUES (?, ?, 'active', 0, ?, ?)
                """,
                (queue_group_id, clean_name, now, now),
            )
            self._audit_with_db(
                db,
                "queue_group.created",
                "queue_group",
                queue_group_id,
                {"name": clean_name},
            )
            return self._get_queue_group_with_db(db, queue_group_id)  # type: ignore[return-value]

    def rename_queue_group(self, queue_group_id: str, name: str) -> QueueGroupItem | None:
        if queue_group_id == DEFAULT_QUEUE_GROUP_ID:
            return self.get_queue_group(DEFAULT_QUEUE_GROUP_ID)

        clean_name = name.strip()
        if not clean_name:
            return None

        now = utc_now()
        with connect(self.db_path) as db:
            db.execute(
                """
                UPDATE queue_groups
                SET name=?,
                    updated_at=?
                WHERE queue_group_id = ?
                  AND status = 'active'
                  AND is_default = 0
                """,
                (clean_name, now, queue_group_id),
            )
            group = self._get_queue_group_with_db(db, queue_group_id)
            if group:
                self._audit_with_db(
                    db,
                    "queue_group.renamed",
                    "queue_group",
                    queue_group_id,
                    {"name": clean_name},
                )
            return group

    def delete_queue_group(
            self,
            queue_group_id: str,
            *,
            cancel_queued: bool = True,
            reason: str = "queue group deleted",
    ) -> tuple[bool, int]:
        if queue_group_id == DEFAULT_QUEUE_GROUP_ID:
            return False, 0

        now = utc_now()
        cancelled = 0

        with connect(self.db_path) as db:
            group = self._get_queue_group_with_db(db, queue_group_id)
            if not group:
                return False, 0

            if cancel_queued:
                cur = db.execute(
                    """
                    UPDATE deliveries
                    SET status='cancelled',
                        cancelled_at=?,
                        acknowledged_at=?,
                        error=?
                    WHERE queue_group_id = ?
                      AND status = 'queued'
                    """,
                    (now, now, reason, queue_group_id),
                )
                cancelled = cur.rowcount

            db.execute(
                """
                UPDATE session_queue_groups
                SET queue_group_id='default',
                    assigned_at=?
                WHERE queue_group_id = ?
                """,
                (now, queue_group_id),
            )

            db.execute(
                """
                UPDATE queue_groups
                SET status='deleted',
                    updated_at=?
                WHERE queue_group_id = ?
                  AND is_default = 0
                """,
                (now, queue_group_id),
            )

            self._audit_with_db(
                db,
                "queue_group.deleted",
                "queue_group",
                queue_group_id,
                {"cancel_queued": cancel_queued, "cancelled_count": cancelled, "reason": reason},
            )

        return True, cancelled

    def get_session_queue_group(
            self,
            source_session_id: str,
            *,
            provider: str | None = None,
            label: str | None = None,
    ) -> QueueGroupItem:
        now = utc_now()
        with connect(self.db_path) as db:
            row = db.execute(
                """
                SELECT q.queue_group_id, q.name, q.status, q.is_default, q.created_at, q.updated_at
                FROM session_queue_groups s
                         JOIN queue_groups q ON s.queue_group_id = q.queue_group_id
                WHERE s.source_session_id = ?
                  AND q.status = 'active'
                """,
                (source_session_id,),
            ).fetchone()

            if row:
                return self._queue_group_item_from_row(row)

            db.execute(
                """
                INSERT OR REPLACE INTO session_queue_groups
                (source_session_id, provider, label, queue_group_id, assigned_at)
                VALUES (?, ?, ?, 'default', ?)
                """,
                (source_session_id, provider, label, now),
            )

            return self._get_queue_group_with_db(db,
                                                 DEFAULT_QUEUE_GROUP_ID)  # type: ignore[return-value]

    def set_session_queue_group(
            self,
            *,
            source_session_id: str,
            queue_group_id: str,
            provider: str | None = None,
            label: str | None = None,
    ) -> QueueGroupItem | None:
        now = utc_now()
        with connect(self.db_path) as db:
            group = self._get_queue_group_with_db(db, queue_group_id)
            if not group:
                return None

            db.execute(
                """
                INSERT OR REPLACE INTO session_queue_groups
                (source_session_id, provider, label, queue_group_id, assigned_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (source_session_id, provider, label, queue_group_id, now),
            )

            self._audit_with_db(
                db,
                "session.queue_group.assigned",
                "session",
                source_session_id,
                {"queue_group_id": queue_group_id, "provider": provider, "label": label},
            )

            return group

    def upsert_session(self, event: CaptureEvent) -> str:
        session_id = event.source_session_id or self.build_session_id(event)
        now = utc_now()

        with connect(self.db_path) as db:
            existing = db.execute(
                "SELECT session_id FROM sessions WHERE session_id = ?",
                (session_id,),
            ).fetchone()

            if existing:
                db.execute(
                    """
                    UPDATE sessions
                    SET last_seen_at=?,
                        url=?,
                        title=?,
                        conversation_id=?,
                        gizmo_id=?
                    WHERE session_id = ?
                    """,
                    (
                        now,
                        event.conversation_url,
                        event.conversation_title,
                        event.conversation_id,
                        event.gizmo_id,
                        session_id,
                    ),
                )
            else:
                db.execute(
                    """
                    INSERT INTO sessions
                    (session_id, provider, conversation_id, gizmo_id, url, title,
                     first_seen_at, last_seen_at, status, metadata_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
                    """,
                    (
                        session_id,
                        event.provider,
                        event.conversation_id,
                        event.gizmo_id,
                        event.conversation_url,
                        event.conversation_title,
                        now,
                        now,
                        _json_dumps(event.metadata),
                    ),
                )

        return session_id

    @staticmethod
    def build_session_id(event: CaptureEvent) -> str:
        if event.gizmo_id:
            return f"{event.provider}:{event.gizmo_id}:{event.conversation_id or 'unknown'}"
        return f"{event.provider}:standard:{event.conversation_id or 'unknown'}"

    @staticmethod
    def build_dedupe_key(event: CaptureEvent, session_id: str) -> str:
        turn = event.turn_testid or "no-turn"
        return f"{session_id}|{event.role}|{turn}|{event.text_hash}"

    def insert_message(self, event: CaptureEvent, session_id: str) -> tuple[str, bool]:
        message_id = str(uuid.uuid4())
        dedupe_key = self.build_dedupe_key(event, session_id)
        now = utc_now()
        format_capture = event.resolved_format_capture()
        format_capture_json = _json_dumps(model_to_dict(format_capture))
        diagnostics_json = _json_dumps(model_to_dict(format_capture.diagnostics))

        with connect(self.db_path) as db:
            existing = db.execute(
                "SELECT message_id FROM messages WHERE dedupe_key = ?",
                (dedupe_key,),
            ).fetchone()

            if existing:
                return str(existing["message_id"]), True

            db.execute(
                """
                INSERT INTO messages
                (message_id, source_session_id, provider, conversation_id, gizmo_id, role,
                 turn_testid, capture_source, body, body_markdown, body_plain, body_html,
                 body_hash, body_length, captured_at, created_at, dedupe_key,
                 metadata_json, format_capture_json, format_version, format_diagnostics_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    message_id,
                    session_id,
                    event.provider,
                    event.conversation_id,
                    event.gizmo_id,
                    event.role,
                    event.turn_testid,
                    event.capture_source,
                    format_capture.canonical_markdown,
                    format_capture.canonical_markdown,
                    format_capture.plain_text,
                    format_capture.html_fragment,
                    event.text_hash,
                    len(format_capture.canonical_markdown),
                    event.captured_at,
                    now,
                    dedupe_key,
                    _json_dumps(event.metadata),
                    format_capture_json,
                    format_capture.format_version,
                    diagnostics_json,
                ),
            )

            self._audit_with_db(
                db,
                "message.captured",
                "message",
                message_id,
                {
                    "dedupe_key": dedupe_key,
                    "provider": event.provider,
                    "format_version": format_capture.format_version,
                    "format_diagnostics": model_to_dict(format_capture.diagnostics),
                },
            )

        return message_id, False

    def create_delivery(
            self,
            message_id: str,
            route_id: str,
            target_type: str,
            target_id: str,
            wrapped_body: str,
            wrapped_format_capture: FormatCapture | None = None,
            queue_group_id: str = DEFAULT_QUEUE_GROUP_ID,
    ) -> str:
        delivery_id = str(uuid.uuid4())
        now = utc_now()

        if wrapped_format_capture is None:
            wrapped_format_capture = FormatCapture.from_legacy_text(wrapped_body)

        wrapped_format_capture = wrapped_format_capture.normalized()
        wrapped_json = _json_dumps(model_to_dict(wrapped_format_capture))
        diagnostics_json = _json_dumps(model_to_dict(wrapped_format_capture.diagnostics))

        with connect(self.db_path) as db:
            if not self._get_queue_group_with_db(db, queue_group_id):
                queue_group_id = DEFAULT_QUEUE_GROUP_ID

            db.execute(
                """
                INSERT INTO deliveries
                (delivery_id, message_id, route_id, target_type, target_id, queue_group_id, status,
                 wrapped_body, wrapped_body_markdown, wrapped_body_plain, wrapped_body_html,
                 wrapped_format_capture_json, format_version, format_diagnostics_json,
                 attempt_count, queued_at, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?, 0, ?, '{}')
                """,
                (
                    delivery_id,
                    message_id,
                    route_id,
                    target_type,
                    target_id,
                    queue_group_id,
                    wrapped_format_capture.canonical_markdown,
                    wrapped_format_capture.canonical_markdown,
                    wrapped_format_capture.plain_text,
                    wrapped_format_capture.html_fragment,
                    wrapped_json,
                    wrapped_format_capture.format_version,
                    diagnostics_json,
                    now,
                ),
            )

            self._audit_with_db(
                db,
                "delivery.queued",
                "delivery",
                delivery_id,
                {
                    "message_id": message_id,
                    "route_id": route_id,
                    "queue_group_id": queue_group_id,
                    "format_version": wrapped_format_capture.format_version,
                },
            )

        return delivery_id

    def _draft_select_sql(self) -> str:
        return """
               SELECT d.delivery_id, \
                      d.message_id, \
                      d.route_id, \
                      d.status, \
                      d.target_type, \
                      d.target_id, \
                      COALESCE(d.queue_group_id, 'default')             AS queue_group_id, \
                      q.name                                            AS queue_group_name, \
                      d.queued_at, \
                      d.delivered_at, \
                      d.acknowledged_at, \
                      d.cancelled_at, \
                      d.error, \

                      COALESCE(d.wrapped_body_markdown, d.wrapped_body) AS wrapped_body, \
                      d.wrapped_body_markdown, \
                      d.wrapped_body_plain, \
                      d.wrapped_body_html, \
                      d.wrapped_format_capture_json, \
                      d.format_version, \
                      d.format_diagnostics_json, \

                      m.provider, \
                      m.source_session_id, \
                      m.conversation_id, \
                      m.gizmo_id, \
                      s.url                                             AS conversation_url, \
                      s.title                                           AS conversation_title, \
                      m.role, \
                      m.turn_testid, \
                      m.capture_source, \
                      m.body_hash, \
                      m.body_length, \
                      m.captured_at, \
                      m.body_markdown, \
                      m.body_plain, \
                      m.body_html, \
                      m.format_capture_json
               FROM deliveries d
                        JOIN messages m ON d.message_id = m.message_id
                        JOIN sessions s ON m.source_session_id = s.session_id
                        LEFT JOIN queue_groups q \
                                  ON COALESCE(d.queue_group_id, 'default') = q.queue_group_id \
               """

    def _draft_row_to_item(self, row: sqlite3.Row) -> DraftItem:
        data = dict(row)

        format_capture_json = _json_loads_dict(data.pop("format_capture_json", None))
        wrapped_json = _json_loads_dict(data.pop("wrapped_format_capture_json", None))
        diagnostics = _json_loads_dict(data.pop("format_diagnostics_json", None))

        data["format_diagnostics"] = diagnostics

        if format_capture_json:
            try:
                data["format_capture"] = FormatCapture(**format_capture_json).normalized()
            except Exception:
                data["format_capture"] = None

        if wrapped_json:
            try:
                data["wrapped_format_capture"] = FormatCapture(**wrapped_json).normalized()
            except Exception:
                data["wrapped_format_capture"] = None

        data["wrapped_body"] = data.get("wrapped_body") or data.get("wrapped_body_markdown") or ""
        data["queue_group_id"] = data.get("queue_group_id") or DEFAULT_QUEUE_GROUP_ID
        data["queue_group_name"] = data.get("queue_group_name") or "Default queue"
        return DraftItem(**data)

    def list_drafts(
            self,
            include_handled: bool = False,
            limit: int = 200,
            queue_group_id: str | None = None,
    ) -> list[DraftItem]:
        if include_handled:
            statuses = (
                "queued",
                "dispatching",
                "dispatched",
                "response_received",
                "draft_inserted",
                "handled",
                "failed",
                "cancelled",
            )
        else:
            statuses = ("queued",)

        placeholders = ",".join("?" for _ in statuses)
        params: list[Any] = [*statuses]

        group_clause = ""
        if queue_group_id:
            group_clause = "AND COALESCE(d.queue_group_id, 'default') = ?"
            params.append(queue_group_id)

        params.append(limit)

        with connect(self.db_path) as db:
            rows = db.execute(
                f"""
                {self._draft_select_sql()}
                WHERE d.target_type = 'local_draft'
                  AND d.status IN ({placeholders})
                  {group_clause}
                ORDER BY d.queued_at DESC
                LIMIT ?
                """,
                tuple(params),
            ).fetchall()

        return [self._draft_row_to_item(row) for row in rows]

    def get_next_draft(
            self,
            *,
            exclude_source_session_id: str | None = None,
            provider: str | None = None,
            target_type: str = "local_draft",
            target_id: str = "default",
            queue_group_id: str | None = None,
    ) -> DraftItem | None:
        clauses = [
            "d.target_type = ?",
            "d.target_id = ?",
            "d.status = 'queued'",
        ]
        params: list[Any] = [target_type, target_id]

        if queue_group_id:
            clauses.append("COALESCE(d.queue_group_id, 'default') = ?")
            params.append(queue_group_id)

        if exclude_source_session_id:
            clauses.append("m.source_session_id != ?")
            params.append(exclude_source_session_id)

        if provider:
            clauses.append("m.provider = ?")
            params.append(provider)

        where = " AND ".join(clauses)

        with connect(self.db_path) as db:
            row = db.execute(
                f"""
                {self._draft_select_sql()}
                WHERE {where}
                ORDER BY d.queued_at ASC
                LIMIT 1
                """,
                tuple(params),
            ).fetchone()

        return self._draft_row_to_item(row) if row else None

    def cancel_delivery(self, delivery_id: str, *, reason: str = "cancelled by operator") -> bool:
        now = utc_now()
        with connect(self.db_path) as db:
            cur = db.execute(
                """
                UPDATE deliveries
                SET status='cancelled',
                    cancelled_at=?,
                    acknowledged_at=?,
                    error=?
                WHERE delivery_id = ?
                  AND status = 'queued'
                """,
                (now, now, reason, delivery_id),
            )
            changed = cur.rowcount > 0
            if changed:
                self._audit_with_db(
                    db,
                    "delivery.cancelled",
                    "delivery",
                    delivery_id,
                    {"reason": reason, "cancelled_at": now},
                )
            return changed

    def clear_queued(
            self,
            *,
            queue_group_id: str | None = None,
            provider: str | None = None,
            reason: str = "clear queued by operator",
    ) -> int:
        now = utc_now()
        clauses = ["d.status='queued'", "d.target_type='local_draft'"]
        params: list[Any] = []

        if queue_group_id:
            clauses.append("COALESCE(d.queue_group_id, 'default') = ?")
            params.append(queue_group_id)

        if provider:
            clauses.append(
                "d.message_id IN (SELECT message_id FROM messages WHERE provider = ?)"
            )
            params.append(provider)

        where = " AND ".join(clauses)

        with connect(self.db_path) as db:
            cur = db.execute(
                f"""
                UPDATE deliveries AS d
                SET status='cancelled',
                    cancelled_at=?,
                    acknowledged_at=?,
                    error=?
                WHERE {where}
                """,
                (now, now, reason, *params),
            )
            count = cur.rowcount
            self._audit_with_db(
                db,
                "delivery.clear_queued",
                "delivery",
                queue_group_id or "all",
                {"reason": reason, "queue_group_id": queue_group_id, "provider": provider,
                 "count": count},
            )
            return count

    def mark_delivery_draft_inserted(
            self,
            delivery_id: str,
            *,
            target_session_id: str | None = None,
            target_provider: str | None = None,
            target_conversation_id: str | None = None,
            target_gizmo_id: str | None = None,
            inserted_at: str | None = None,
            metadata: dict[str, Any] | None = None,
    ) -> bool:
        delivered_at = inserted_at or utc_now()
        payload = {
            "target_session_id": target_session_id,
            "target_provider": target_provider,
            "target_conversation_id": target_conversation_id,
            "target_gizmo_id": target_gizmo_id,
            "inserted_at": delivered_at,
            "metadata": metadata or {},
        }

        with connect(self.db_path) as db:
            cur = db.execute(
                """
                UPDATE deliveries
                SET status='draft_inserted',
                    delivered_at=?,
                    attempt_count=attempt_count + 1,
                    error=NULL,
                    metadata_json=?
                WHERE delivery_id = ?
                  AND status IN ('queued', 'dispatching', 'dispatched', 'failed')
                """,
                (delivered_at, _json_dumps(payload), delivery_id),
            )

            changed = cur.rowcount > 0
            if changed:
                self._audit_with_db(
                    db,
                    "delivery.draft_inserted",
                    "delivery",
                    delivery_id,
                    payload,
                )

            return changed

    def mark_delivery_failed(
            self,
            delivery_id: str,
            *,
            error: str,
            target_session_id: str | None = None,
            failed_at: str | None = None,
            metadata: dict[str, Any] | None = None,
    ) -> bool:
        when = failed_at or utc_now()
        payload = {
            "target_session_id": target_session_id,
            "failed_at": when,
            "error": error,
            "metadata": metadata or {},
        }

        with connect(self.db_path) as db:
            cur = db.execute(
                """
                UPDATE deliveries
                SET status='failed',
                    attempt_count=attempt_count + 1,
                    error=?,
                    metadata_json=?
                WHERE delivery_id = ?
                  AND status IN ('queued', 'failed')
                """,
                (error, _json_dumps(payload), delivery_id),
            )

            changed = cur.rowcount > 0
            if changed:
                self._audit_with_db(
                    db,
                    "delivery.failed",
                    "delivery",
                    delivery_id,
                    payload,
                )

            return changed

    def mark_delivery_handled(self, delivery_id: str) -> bool:
        now = utc_now()

        with connect(self.db_path) as db:
            cur = db.execute(
                """
                UPDATE deliveries
                SET status='handled',
                    acknowledged_at=?
                WHERE delivery_id = ?
                  AND status!='handled'
                """,
                (now, delivery_id),
            )

            changed = cur.rowcount > 0
            if changed:
                self._audit_with_db(
                    db,
                    "delivery.handled",
                    "delivery",
                    delivery_id,
                    {"acknowledged_at": now},
                )

            return changed

    def get_draft_by_delivery_id(self, delivery_id: str) -> DraftItem | None:
        with connect(self.db_path) as db:
            row = db.execute(
                f"""
                {self._draft_select_sql()}
                WHERE d.delivery_id = ?
                LIMIT 1
                """,
                (delivery_id,),
            ).fetchone()

        return self._draft_row_to_item(row) if row else None

    def mark_delivery_dispatching(
            self,
            delivery_id: str,
            *,
            provider_id: str,
            metadata: dict[str, Any] | None = None,
    ) -> bool:
        now = utc_now()
        payload = {
            "provider_id": provider_id,
            "dispatching_at": now,
            "metadata": metadata or {},
        }

        with connect(self.db_path) as db:
            cur = db.execute(
                """
                UPDATE deliveries
                SET status='dispatching',
                    attempt_count=attempt_count + 1,
                    metadata_json=?,
                    error=NULL
                WHERE delivery_id = ?
                  AND status IN ('queued', 'failed')
                """,
                (_json_dumps(payload), delivery_id),
            )

            changed = cur.rowcount > 0
            if changed:
                self._audit_with_db(
                    db,
                    "delivery.dispatching",
                    "delivery",
                    delivery_id,
                    payload,
                )
            return changed

    def mark_delivery_dispatched(
            self,
            delivery_id: str,
            *,
            provider_id: str,
            metadata: dict[str, Any] | None = None,
    ) -> bool:
        now = utc_now()
        payload = {
            "provider_id": provider_id,
            "dispatched_at": now,
            "metadata": metadata or {},
        }

        with connect(self.db_path) as db:
            cur = db.execute(
                """
                UPDATE deliveries
                SET status='dispatched',
                    delivered_at=COALESCE(delivered_at, ?),
                    metadata_json=?,
                    error=NULL
                WHERE delivery_id = ?
                  AND status IN ('dispatching', 'queued', 'failed')
                """,
                (now, _json_dumps(payload), delivery_id),
            )

            changed = cur.rowcount > 0
            if changed:
                self._audit_with_db(
                    db,
                    "delivery.dispatched",
                    "delivery",
                    delivery_id,
                    payload,
                )
            return changed

    def mark_delivery_response_received(
            self,
            delivery_id: str,
            *,
            provider_id: str | None = None,
            generated_message_id: str | None = None,
            metadata: dict[str, Any] | None = None,
    ) -> bool:
        now = utc_now()
        payload = {
            "provider_id": provider_id,
            "generated_message_id": generated_message_id,
            "response_received_at": now,
            "metadata": metadata or {},
        }

        with connect(self.db_path) as db:
            cur = db.execute(
                """
                UPDATE deliveries
                SET status='response_received',
                    delivered_at=COALESCE(delivered_at, ?),
                    acknowledged_at=COALESCE(acknowledged_at, ?),
                    metadata_json=?,
                    error=NULL
                WHERE delivery_id = ?
                  AND status IN ('queued', 'dispatching', 'dispatched', 'failed')
                """,
                (now, now, _json_dumps(payload), delivery_id),
            )

            changed = cur.rowcount > 0
            if changed:
                self._audit_with_db(
                    db,
                    "delivery.response_received",
                    "delivery",
                    delivery_id,
                    payload,
                )
            return changed

    def list_provider_sessions(self) -> list["ProviderSessionItem"]:
        from .models import ProviderSessionItem

        with connect(self.db_path) as db:
            rows = db.execute(
                """
                SELECT s.session_id                              AS source_session_id,
                       s.provider                                AS provider,
                       COALESCE(sq.label, s.title, s.session_id) AS label,
                       COALESCE(sq.queue_group_id, 'default')    AS queue_group_id,
                       COALESCE(q.name, 'Default queue')         AS queue_group_name,
                       sq.assigned_at                            AS assigned_at,
                       s.last_seen_at                            AS last_seen_at
                FROM sessions s
                         LEFT JOIN session_queue_groups sq ON sq.source_session_id = s.session_id
                         LEFT JOIN queue_groups q
                                   ON COALESCE(sq.queue_group_id, 'default') = q.queue_group_id
                ORDER BY s.last_seen_at DESC
                """
            ).fetchall()

        return [
            ProviderSessionItem(
                source_session_id=str(row["source_session_id"]),
                provider=row["provider"],
                label=row["label"],
                queue_group_id=row["queue_group_id"] or DEFAULT_QUEUE_GROUP_ID,
                queue_group_name=row["queue_group_name"] or "Default queue",
                assigned_at=row["assigned_at"],
                last_seen_at=row["last_seen_at"],
            )
            for row in rows
        ]

    def summary(self) -> dict[str, Any]:
        with connect(self.db_path) as db:
            return {
                "sessions": db.execute("SELECT COUNT(*) AS n FROM sessions").fetchone()["n"],
                "queue_groups": db.execute(
                    "SELECT COUNT(*) AS n FROM queue_groups WHERE status='active'"
                ).fetchone()["n"],
                "messages": db.execute("SELECT COUNT(*) AS n FROM messages").fetchone()["n"],
                "deliveries": db.execute("SELECT COUNT(*) AS n FROM deliveries").fetchone()["n"],
                "dispatching": db.execute(
                    "SELECT COUNT(*) AS n FROM deliveries WHERE status='dispatching'"
                ).fetchone()["n"],
                "dispatched": db.execute(
                    "SELECT COUNT(*) AS n FROM deliveries WHERE status='dispatched'"
                ).fetchone()["n"],
                "response_received": db.execute(
                    "SELECT COUNT(*) AS n FROM deliveries WHERE status='response_received'"
                ).fetchone()["n"],
                "queued_drafts": db.execute(
                    "SELECT COUNT(*) AS n FROM deliveries WHERE target_type='local_draft' AND status='queued'"
                ).fetchone()["n"],
                "draft_inserted": db.execute(
                    "SELECT COUNT(*) AS n FROM deliveries WHERE target_type='local_draft' AND status='draft_inserted'"
                ).fetchone()["n"],
                "handled": db.execute(
                    "SELECT COUNT(*) AS n FROM deliveries WHERE target_type='local_draft' AND status='handled'"
                ).fetchone()["n"],
                "cancelled": db.execute(
                    "SELECT COUNT(*) AS n FROM deliveries WHERE target_type='local_draft' AND status='cancelled'"
                ).fetchone()["n"],
                "failed": db.execute(
                    "SELECT COUNT(*) AS n FROM deliveries WHERE target_type='local_draft' AND status='failed'"
                ).fetchone()["n"],
            }

    @staticmethod
    def _audit_with_db(
            db: sqlite3.Connection,
            event_type: str,
            entity_type: str,
            entity_id: str,
            payload: dict[str, Any],
    ) -> None:
        db.execute(
            """
            INSERT INTO audit_events
            (event_id, event_type, entity_type, entity_id, created_at, payload_json)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                event_type,
                entity_type,
                entity_id,
                utc_now(),
                _json_dumps(payload),
            ),
        )