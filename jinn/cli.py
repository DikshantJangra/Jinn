"""
Command Line Interface for Jinn.
"""

import sys
import json
import argparse
from jinn.agent import JinnAgent
from jinn.engine import GemmaLocalEngine
from jinn.tools import LocalToolKit

def main():
    parser = argparse.ArgumentParser(
        description="Jinn: Autonomous Local AI Application Powered by Google Gemma"
    )
    subparsers = parser.add_subparsers(dest="command", help="Subcommand to execute")

    plan_parser = subparsers.add_parser("plan", help="Plan a complex task using Gemma locally")
    plan_parser.add_argument("task", type=str, help="Description of the task to plan")

    audit_parser = subparsers.add_parser("audit", help="Run local audit of current directory")
    audit_parser.add_argument("--dir", default=".", help="Directory to audit")

    subparsers.add_parser("info", help="Display local environment telemetry and Gemma status")

    args = parser.parse_args()

    engine = GemmaLocalEngine()
    agent = JinnAgent(engine=engine)

    if args.command == "plan":
        print(f"🧞 [Jinn] Planning task using Gemma: '{args.task}'...\n")
        res = agent.plan_task(args.task)
        print(json.dumps(res, indent=2))

    elif args.command == "audit":
        print(f"🧞 [Jinn] Running local workspace audit on: {args.dir}...\n")
        res = agent.execute_local_audit(args.dir)
        print(json.dumps(res, indent=2))

    elif args.command == "info":
        print("🧞 [Jinn] System & Engine Telemetry:")
        telemetry = LocalToolKit.system_telemetry()
        status = {
            "telemetry": telemetry,
            "gemma_available": engine.is_available(),
            "target_model": engine.model_name,
            "endpoint": engine.endpoint
        }
        print(json.dumps(status, indent=2))

    else:
        parser.print_help()
        sys.exit(0)

if __name__ == "__main__":
    main()
