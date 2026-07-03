from __future__ import annotations

from dataclasses import dataclass

from local_llm.contracts import (
    ExperimentRunMatrixPlan,
    PacketGroupResponse,
    ResolvedExperimentCondition,
    ResolvedExperimentRunMatrixRequest,
)
from local_llm.eval_capture.groups import build_condition_group, build_experiment_group
from local_llm.store.base import StoreProtocol
from local_llm.turns.request import TurnExecutionRequest


@dataclass(frozen=True)
class ExperimentReplicatePlan:
    condition_label: str
    replicate_index: int
    request: TurnExecutionRequest


@dataclass(frozen=True)
class CreatedExperimentGroups:
    experiment_group: PacketGroupResponse
    condition_groups: list[PacketGroupResponse]


class ExperimentRunMatrixPlanner:
    def _conditions(
            self,
            request: ResolvedExperimentRunMatrixRequest,
    ) -> list[ResolvedExperimentCondition]:
        return [request.baseline] + list(request.variables)

    def create_groups(
            self,
            store: StoreProtocol,
            request: ResolvedExperimentRunMatrixRequest,
    ) -> CreatedExperimentGroups:
        experiment_req = build_experiment_group(
            label=f"experiment:{request.workflow_id}",
            purpose="baseline-vs-variable run matrix",
            metadata={
                "operator_labels": request.operator_labels,
                "training_preferences": request.training_preferences,
            },
        )
        experiment_group = store.create_packet_group(experiment_req)
        condition_groups: list[PacketGroupResponse] = []
        for condition in self._conditions(request):
            condition_req = build_condition_group(
                label=condition.label,
                parent_group_id=experiment_group.packet_group_id,
                condition={
                    "role": condition.role,
                    "config_overlay": condition.config_overlay,
                    "replicate_count": condition.replicate_count,
                },
            )
            condition_groups.append(store.create_packet_group(condition_req))
        return CreatedExperimentGroups(
            experiment_group=experiment_group,
            condition_groups=condition_groups,
        )

    def build_requests(
            self,
            request: ResolvedExperimentRunMatrixRequest,
            groups: CreatedExperimentGroups,
    ) -> list[TurnExecutionRequest]:
        turn_requests: list[TurnExecutionRequest] = []
        conditions = self._conditions(request)
        if len(groups.condition_groups) != len(conditions):
            raise ValueError("condition group count does not match condition count")
        for condition, group in zip(conditions, groups.condition_groups, strict=True):
            for index in range(1, condition.replicate_count + 1):
                turn_requests.append(TurnExecutionRequest(
                    source_kind="experiment_replicate",
                    workflow_id=request.workflow_id,
                    input=request.input,
                    capture_mode=request.capture_mode,
                    privacy_level=request.privacy_level,
                    config_overlay=condition.config_overlay,
                    experiment_group_id=groups.experiment_group.packet_group_id,
                    condition_group_id=group.packet_group_id,
                    packet_group_ids=[groups.experiment_group.packet_group_id],
                    replicate_index=index,
                    operator_labels={
                        **request.operator_labels,
                        "condition_label": condition.label,
                        "condition_role": condition.role,
                        "replicate_count": condition.replicate_count,
                    },
                ))
        return turn_requests

    def plan(
            self,
            store: StoreProtocol,
            request: ResolvedExperimentRunMatrixRequest,
    ) -> ExperimentRunMatrixPlan:
        groups = self.create_groups(store, request)
        turn_requests = self.build_requests(request, groups)
        return ExperimentRunMatrixPlan(
            experiment_group=groups.experiment_group,
            condition_groups=groups.condition_groups,
            requests=[item.__dict__ for item in turn_requests],
        )