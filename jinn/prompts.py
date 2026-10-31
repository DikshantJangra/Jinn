"""
Gemma-specific prompt templates and formatting.
"""

GEMMA_SYSTEM_PROMPT = """You are Jinn, an autonomous local AI assistant powered by Gemma running directly on the user's laptop.
You respect privacy, run 100% locally with zero data egress, and solve complex tasks step-by-step.
When given tools or structured tasks, reason carefully and return clear, actionable, and structured outputs."""

def format_gemma_turn(user_content: str, system_prompt: str = GEMMA_SYSTEM_PROMPT) -> str:
    """Formats prompt into standard Gemma conversational turn structure."""
    return f"<start_of_turn>user\n{system_prompt}\n\nTask: {user_content}<end_of_turn>\n<start_of_turn>model\n"

def format_planning_prompt(task_description: str) -> str:
    """Constructs a planning prompt that requires JSON formatted step breakdown."""
    prompt = f"""Break down the following complex task into ordered, executable steps:
Task: "{task_description}"

Respond strictly with valid JSON with the following structure:
{{
  "task": "{task_description}",
  "steps": [
    {{"step_number": 1, "description": "...", "tool_required": "...", "expected_outcome": "..."}}
  ],
  "local_execution_safe": true
}}"""
    return prompt  # Ollama applies the model chat template itself; raw turn markers would be doubled
