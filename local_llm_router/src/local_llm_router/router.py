from __future__ import annotations

from .config import AppConfig
from .format_capture import model_to_dict
from .models import CaptureEvent, CaptureResponse
from .store import Store
from .wrappers import apply_format_wrapper


class Router:
    def __init__(self, config: AppConfig, store: Store):
        self.config = config
        self.store = store

    def _queue_matching_deliveries(
            self,
            *,
            event: CaptureEvent,
            message_id: str,
            queue_group_id: str,
    ) -> tuple[list[str], str | None]:
        delivery_ids: list[str] = []
        target_session_id: str | None = None

        for route in self.config.routes:
            if not route.enabled:
                continue
            if route.source.provider != event.provider:
                continue
            if route.source.role != event.role:
                continue

            wrapped_format_capture = apply_format_wrapper(self.config, route.wrapper, event)
            delivery_id = self.store.create_delivery(
                message_id=message_id,
                route_id=route.route_id,
                target_type=route.target.type,
                target_id=route.target.id,
                wrapped_body=wrapped_format_capture.canonical_markdown,
                wrapped_format_capture=wrapped_format_capture,
                queue_group_id=queue_group_id,
            )
            delivery_ids.append(delivery_id)
            target_session_id = f"{route.target.type}:{route.target.id}"

        return delivery_ids, target_session_id

    def capture(self, event: CaptureEvent) -> CaptureResponse:
        resolved = event.resolved_format_capture()
        event.text = resolved.canonical_markdown
        event.text_length = len(event.text)

        if not event.text_hash:
            event.text_hash = str(abs(hash(event.text)))

        metadata = dict(event.metadata or {})
        metadata.setdefault("format_capture", model_to_dict(resolved))
        metadata.setdefault("format_diagnostics", model_to_dict(resolved.diagnostics))
        metadata.setdefault("format_version", resolved.format_version)
        event.metadata = metadata

        session_id = self.store.upsert_session(event)
        event.source_session_id = session_id

        queue_group = self.store.get_session_queue_group(
            session_id,
            provider=event.provider,
            label=event.conversation_title or event.conversation_id or session_id,
        )

        message_id, deduped = self.store.insert_message(event, session_id)

        delivery_ids, target_session_id = self._queue_matching_deliveries(
            event=event,
            message_id=message_id,
            queue_group_id=queue_group.queue_group_id,
        )

        if deduped:
            decision = (
                "deduped_requeued_to_local_draft"
                if delivery_ids
                else "deduped_existing_message_no_matching_route"
            )
            return CaptureResponse(
                accepted=True,
                message_id=message_id,
                deduped=True,
                route_decision=decision,
                delivery_ids=delivery_ids,
                target_session_id=target_session_id,
            )

        decision = "queued_to_local_draft" if delivery_ids else "accepted_no_matching_route"
        return CaptureResponse(
            accepted=True,
            message_id=message_id,
            deduped=False,
            route_decision=decision,
            delivery_ids=delivery_ids,
            target_session_id=target_session_id,
        )