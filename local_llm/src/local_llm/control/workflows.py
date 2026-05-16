from __future__ import annotations

from local_llm.control.profiles import ResolvedWorkflow


def assert_supported_workflow(workflow: ResolvedWorkflow) -> None:
    if workflow.workflow.kind != "rag_answer":
        raise ValueError(f"workflow kind {workflow.workflow.kind!r} is reserved but not implemented")
