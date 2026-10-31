"""
Autonomous Local Agent Orchestrator.
Uses Gemma to plan and coordinate tasks using local tools.
"""

import json
from typing import Dict, Any, Optional
from jinn.engine import GemmaLocalEngine
from jinn.prompts import format_planning_prompt, GEMMA_SYSTEM_PROMPT
from jinn.tools import LocalToolKit

class JinnAgent:
    def __init__(self, engine: Optional[GemmaLocalEngine] = None):
        self.engine = engine or GemmaLocalEngine()
        self.tools = LocalToolKit()

    def plan_task(self, task_description: str) -> Dict[str, Any]:
        """Prompts Gemma to generate an execution plan for a user's task."""
        prompt = format_planning_prompt(task_description)
        result = self.engine.generate(prompt, system=GEMMA_SYSTEM_PROMPT)

        try:
            raw = result["response"].strip()
            if "{" in raw:  # tolerate fences/prose around the JSON (gemma4 on Ollama has no format=json)
                raw = raw[raw.index("{"):raw.rindex("}") + 1]
            plan = json.loads(raw)
        except Exception:
            plan = {
                "task": task_description,
                "raw_response": result["response"],
                "status": "unstructured_response"
            }

        return {
            "task": task_description,
            "engine_mode": result.get("mode"),
            "model": result.get("model"),
            "plan": plan
        }

    def execute_local_audit(self, target_dir: str = ".") -> Dict[str, Any]:
        """Runs a complete local workspace audit orchestrated by Jinn."""
        workspace_info = self.tools.inspect_workspace(target_dir)
        telemetry = self.tools.system_telemetry()

        plan = self.plan_task(f"Audit and analyze repository at {target_dir}")

        return {
            "status": "success",
            "telemetry": telemetry,
            "workspace": workspace_info,
            "agent_plan": plan
        }
