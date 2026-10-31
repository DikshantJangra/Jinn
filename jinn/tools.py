"""
Local tools executable directly on the user's laptop.
Zero external network calls, ensuring 100% data privacy.
"""

import os
import sys
import platform
import json
from typing import Dict, Any, List

class LocalToolKit:
    @staticmethod
    def inspect_workspace(path: str = ".") -> Dict[str, Any]:
        """Scans the local directory and returns file hierarchy and statistics."""
        summary = {
            "root": os.path.abspath(path),
            "files_count": 0,
            "directories_count": 0,
            "file_list": []
        }
        for root, dirs, files in os.walk(path):
            if ".git" in root or "__pycache__" in root or "node_modules" in root:
                continue
            summary["directories_count"] += len(dirs)
            for f in files:
                rel = os.path.relpath(os.path.join(root, f), path)
                size = os.path.getsize(os.path.join(root, f))
                summary["files_count"] += 1
                summary["file_list"].append({"path": rel, "bytes": size})
        return summary

    @staticmethod
    def analyze_python_file(file_path: str) -> Dict[str, Any]:
        """Analyzes a Python file for lines, functions, classes, and imports."""
        if not os.path.exists(file_path):
            return {"error": f"File '{file_path}' does not exist"}

        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()

        functions: List[str] = []
        classes: List[str] = []
        imports: List[str] = []

        for line in lines:
            stripped = line.strip()
            if stripped.startswith("def "):
                fn_name = stripped.split("(")[0].replace("def ", "")
                functions.append(fn_name)
            elif stripped.startswith("class "):
                cls_name = stripped.split("(")[0].split(":")[0].replace("class ", "")
                classes.append(cls_name)
            elif stripped.startswith("import ") or stripped.startswith("from "):
                imports.append(stripped)

        return {
            "file": file_path,
            "total_lines": len(lines),
            "functions": functions,
            "classes": classes,
            "imports": imports
        }

    @staticmethod
    def system_telemetry() -> Dict[str, Any]:
        """Gathers local machine specs to verify offline compatibility."""
        return {
            "os": platform.system(),
            "os_release": platform.release(),
            "machine": platform.machine(),
            "python_version": sys.version.split()[0],
            "privacy_mode": "100% Offline / Local Execution"
        }
