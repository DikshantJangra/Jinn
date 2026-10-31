"""
Example script demonstrating Jinn's local task planning and workspace audit.
"""

import os
import sys
import json

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from jinn.agent import JinnAgent
from jinn.engine import GemmaLocalEngine

def run_demo():
    print("==================================================")
    print("  Jinn: Local AI Application Powered by Gemma     ")
    print("  Problem 08 - Build Anything with Gemma          ")
    print("==================================================\n")

    engine = GemmaLocalEngine()
    agent = JinnAgent(engine=engine)

    input_file = os.path.join(os.path.dirname(__file__), "input_task_planning.json")
    with open(input_file, "r") as f:
        sample_input = json.load(f)

    print(f"[Input Task]: {sample_input['task']}\n")

    result = agent.plan_task(sample_input["task"])
    print("[Actual Output Generated]:")
    print(json.dumps(result, indent=2))
    print("\nDemo finished successfully with 100% local privacy.")

if __name__ == "__main__":
    run_demo()
