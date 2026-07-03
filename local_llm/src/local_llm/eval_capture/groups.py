from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

from local_llm.contracts import PacketGroupRequest, PacketGroupMemberRequest, ProjectionRequest
from local_llm.eval_capture.constants import GROUP_KINDS, MEMBER_ROLES, MEMBER_TYPES


@dataclass(frozen=True)
class PacketGroupPlan:
    request: PacketGroupRequest
    group_id: str = field(default_factory=lambda: str(uuid.uuid4()))


@dataclass(frozen=True)
class PacketGroupMemberPlan:
    request: PacketGroupMemberRequest
    member_id: str = field(default_factory=lambda: str(uuid.uuid4()))


def validate_group_kind(group_kind: str) -> None:
    if group_kind not in GROUP_KINDS:
        raise ValueError(f"invalid packet group kind: {group_kind}")


def validate_member_type_role(member_type: str, member_role: str) -> None:
    if member_type not in MEMBER_TYPES:
        raise ValueError(f"invalid packet group member_type: {member_type}")
    if member_role not in MEMBER_ROLES:
        raise ValueError(f"invalid packet group member_role: {member_role}")


def validate_replicate_membership(member_role: str, turn_packet_id: str | None,
                                  replicate_index: int | None) -> None:
    if member_role == "replicate" and (not turn_packet_id or not replicate_index):
        raise ValueError("replicate membership requires turn_packet_id and replicate_index")


def build_experiment_group(label: str, *, purpose: str | None = None,
                           metadata: dict[str, Any] | None = None) -> PacketGroupRequest:
    return PacketGroupRequest(group_kind="experiment", label=label, purpose=purpose,
                              metadata_json=metadata or {})


def build_condition_group(label: str, *, parent_group_id: str,
                          condition: dict[str, Any]) -> PacketGroupRequest:
    return PacketGroupRequest(group_kind="condition", label=label, parent_group_id=parent_group_id,
                              condition_json=condition)


def build_replicate_membership(packet_group_id: str, turn_packet_id: str, replicate_index: int, *,
                               role: str = "replicate") -> PacketGroupMemberRequest:
    validate_replicate_membership(role, turn_packet_id, replicate_index)
    return PacketGroupMemberRequest(
        packet_group_id=packet_group_id,
        member_type="turn_packet",
        member_id=turn_packet_id,
        turn_packet_id=turn_packet_id,
        member_role=role,
        replicate_index=replicate_index,
    )


def build_session_comparison_group(label: str, session_ids: list[str]) -> tuple[
    PacketGroupRequest, list[PacketGroupMemberRequest]]:
    group = PacketGroupRequest(group_kind="session_comparison", label=label,
                               metadata_json={"session_ids": session_ids})
    members = [
        PacketGroupMemberRequest(packet_group_id="", member_type="session", member_id=session_id,
                                 session_id=session_id, member_role="comparison_member",
                                 ordinal=i + 1)
        for i, session_id in enumerate(session_ids)
    ]
    return group, members


def build_manual_packet_set_group(label: str, packet_ids: list[str]) -> tuple[
    PacketGroupRequest, list[PacketGroupMemberRequest]]:
    group = PacketGroupRequest(group_kind="manual_packet_set", label=label,
                               metadata_json={"packet_ids": packet_ids})
    members = [
        PacketGroupMemberRequest(packet_group_id="", member_type="turn_packet", member_id=packet_id,
                                 turn_packet_id=packet_id, member_role="analysis_member",
                                 ordinal=i + 1)
        for i, packet_id in enumerate(packet_ids)
    ]
    return group, members


def build_session_comparison_request(session_ids: list[str],
                                     metric_keys: list[str] | None = None) -> ProjectionRequest:
    return ProjectionRequest(session_ids=session_ids, metric_keys=metric_keys or [])


def build_manual_packet_set_request(packet_ids: list[str],
                                    metric_keys: list[str] | None = None) -> ProjectionRequest:
    return ProjectionRequest(packet_ids=packet_ids, metric_keys=metric_keys or [])