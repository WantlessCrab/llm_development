from __future__ import annotations

from dataclasses import dataclass

from local_llm.config import AppConfig, ModelProfile, PromptProfile, RagProfile, WorkflowConfig


@dataclass(frozen=True)
class ResolvedWorkflow:
    workflow_id: str
    workflow: WorkflowConfig
    model_profile_id: str
    model_profile: ModelProfile
    rag_profile_id: str
    rag_profile: RagProfile
    prompt_profile_id: str
    prompt_profile: PromptProfile


def resolve_workflow(config: AppConfig, workflow_id: str) -> ResolvedWorkflow:
    workflow = config.workflows.get(workflow_id)
    if not workflow:
        raise KeyError(f"workflow not found: {workflow_id}")

    model_profile = config.model_profiles.get(workflow.model_profile)
    if not model_profile:
        raise KeyError(f"model_profile not found: {workflow.model_profile}")

    rag_profile = config.rag_profiles.get(workflow.rag_profile)
    if not rag_profile:
        raise KeyError(f"rag_profile not found: {workflow.rag_profile}")

    prompt_profile = config.prompt_profiles.get(workflow.prompt_profile)
    if not prompt_profile:
        raise KeyError(f"prompt_profile not found: {workflow.prompt_profile}")

    return ResolvedWorkflow(
        workflow_id=workflow_id,
        workflow=workflow,
        model_profile_id=workflow.model_profile,
        model_profile=model_profile,
        rag_profile_id=workflow.rag_profile,
        rag_profile=rag_profile,
        prompt_profile_id=workflow.prompt_profile,
        prompt_profile=prompt_profile,
    )
