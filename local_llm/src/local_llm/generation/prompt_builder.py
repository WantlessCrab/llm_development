from __future__ import annotations

import hashlib
from dataclasses import dataclass, field

from local_llm.config import PromptProfile


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class PromptSummary:
    message_count: int
    system_chars: int
    user_chars: int
    prompt_chars: int
    context_in_prompt_chars: int
    token_estimate: int
    system_hash: str
    user_hash: str
    prompt_hash: str
    context_hash: str
    content_ref_inputs: list[dict[str, object]] = field(default_factory=list)

    def model_dump(self) -> dict[str, object]:
        return self.__dict__.copy()


@dataclass(frozen=True)
class BuiltPrompt:
    messages: list[dict[str, str]]
    final_prompt: str
    summary: PromptSummary


def build_prompt(prompt_profile: PromptProfile, *, user_input: str,
                 retrieved_context: str) -> BuiltPrompt:
    user_content = prompt_profile.user_template.format(user_input=user_input,
                                                       retrieved_context=retrieved_context)
    messages = [
        {"role": "system", "content": prompt_profile.system},
        {"role": "user", "content": user_content},
    ]
    final_prompt = f"--- system ---\n{prompt_profile.system}\n\n--- user ---\n{user_content}"
    summary = PromptSummary(
        message_count=len(messages),
        system_chars=len(prompt_profile.system),
        user_chars=len(user_content),
        prompt_chars=len(final_prompt),
        context_in_prompt_chars=len(retrieved_context),
        token_estimate=max(1, len(final_prompt) // 4),
        system_hash=_hash(prompt_profile.system),
        user_hash=_hash(user_content),
        prompt_hash=_hash(final_prompt),
        context_hash=_hash(retrieved_context),
        content_ref_inputs=[{"role": item["role"], "chars": len(item["content"])} for item in
                            messages],
    )
    return BuiltPrompt(messages=messages, final_prompt=final_prompt, summary=summary)