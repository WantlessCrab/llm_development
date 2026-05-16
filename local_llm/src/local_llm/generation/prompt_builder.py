from __future__ import annotations

from dataclasses import dataclass

from local_llm.config import PromptProfile


@dataclass(frozen=True)
class BuiltPrompt:
    messages: list[dict[str, str]]
    final_prompt: str


def build_prompt(prompt_profile: PromptProfile, *, user_input: str, retrieved_context: str) -> BuiltPrompt:
    user_content = prompt_profile.user_template.format(user_input=user_input, retrieved_context=retrieved_context)
    messages = [
        {"role": "system", "content": prompt_profile.system},
        {"role": "user", "content": user_content},
    ]
    final_prompt = f"--- system ---\n{prompt_profile.system}\n\n--- user ---\n{user_content}"
    return BuiltPrompt(messages=messages, final_prompt=final_prompt)
