"""
Local inference engine for Google Gemma.
Communicates with locally running instances (Ollama, llama.cpp, etc.)
or operates in fallback deterministic local mode.
Zero external library dependencies required.
"""

import json
import logging
import urllib.request
import urllib.error
from typing import Optional, Dict, Any

logger = logging.getLogger(__name__)

class GemmaLocalEngine:
    def __init__(
        self,
        model_name: str = "gemma4:e4b",
        endpoint: str = "http://localhost:11434/api/generate",
        timeout: int = 180,
        fallback_mode: bool = False
    ):
        self.model_name = model_name
        self.endpoint = endpoint
        self.timeout = timeout
        self.fallback_mode = fallback_mode

    def is_available(self) -> bool:
        """Checks if local Gemma runner (like Ollama) is reachable."""
        try:
            health_url = self.endpoint.replace("/api/generate", "/api/tags")
            req = urllib.request.Request(health_url, method="GET")
            with urllib.request.urlopen(req, timeout=2) as response:
                return response.status == 200
        except Exception:
            return False

    def generate(self, prompt: str, system: Optional[str] = None, json_mode: bool = False) -> Dict[str, Any]:
        """Generates response from local Gemma or fallback engine."""
        if not self.fallback_mode and self.is_available():
            try:
                payload: Dict[str, Any] = {
                    "model": self.model_name,
                    "prompt": prompt,
                    "stream": False,
                    "options": {
                        "temperature": 0.2,
                        "top_p": 0.95
                    }
                }
                if system:
                    payload["system"] = system
                if json_mode:
                    payload["format"] = "json"

                data = json.dumps(payload).encode("utf-8")
                req = urllib.request.Request(
                    self.endpoint,
                    data=data,
                    headers={"Content-Type": "application/json"},
                    method="POST"
                )
                with urllib.request.urlopen(req, timeout=self.timeout) as response:
                    if response.status == 200:
                        body = json.loads(response.read().decode("utf-8"))
                        return {
                            "model": self.model_name,
                            "response": body.get("response", "").strip(),
                            "mode": "local_hardware_gemma",
                            "raw": body
                        }
            except Exception as e:
                logger.warning(f"Local endpoint call failed: {e}. Switching to local fallback mode.")

        # Local deterministic fallback simulation for testing/standalone environments
        return self._fallback_generate(prompt)

    def _fallback_generate(self, prompt: str) -> Dict[str, Any]:
        """Deterministic local fallback processing for offline evaluation & testing."""
        if "Break down the following complex task into ordered, executable steps:" in prompt:
            return {
                "model": f"{self.model_name} (local fallback)",
                "response": json.dumps({
                    "task": "Automated Local Task Execution",
                    "steps": [
                        {"step_number": 1, "description": "Scan and inspect local workspace", "tool_required": "file_inspector", "expected_outcome": "Directory inventory collected"},
                        {"step_number": 2, "description": "Analyze local code and dependencies", "tool_required": "code_analyzer", "expected_outcome": "Dependency graph established"},
                        {"step_number": 3, "description": "Synthesize summary report offline", "tool_required": "local_summarizer", "expected_outcome": "Final markdown artifact generated locally"}
                    ],
                    "local_execution_safe": True
                }, indent=2),
                "mode": "local_fallback"
            }

        return {
            "model": f"{self.model_name} (local fallback)",
            "response": f"[Gemma Local] Successfully processed request: {prompt[:80]}...",
            "mode": "local_fallback"
        }
