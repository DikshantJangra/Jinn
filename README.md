# 🧞 Jinn — Autonomous Local AI Powered by Google Gemma

[![CI Pipeline](https://github.com/DikshantJangra/Jinn/actions/workflows/ci.yml/badge.svg)](https://github.com/DikshantJangra/Jinn/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Model: Google Gemma](https://img.shields.io/badge/AI%20Model-Google%20Gemma-4285F4.svg)](https://ai.google.dev/gemma)
[![Python: 3.9+](https://img.shields.io/badge/Python-3.9%2B-blue.svg)](https://www.python.org/)
[![Privacy: 100% Offline](https://img.shields.io/badge/Privacy-100%25%20Offline-success.svg)](#privacy-guarantee)

> **Hackathon Submission:** Special Track: Gemma  
> **Problem Statement:** PROBLEM 08 — Build Anything with Gemma – Local AI Innovation Challenge  
> **Team:** Jinn (Dikshant Jangra, Somraj, Ritesh)  
> **Repository:** [https://github.com/DikshantJangra/Jinn](https://github.com/DikshantJangra/Jinn)

---

## 📖 Overview

**Jinn** is an autonomous local AI application engineered specifically to harness the power of **Google Gemma** running 100% locally on laptops.

Designed as an intelligent offline genie, Jinn transforms high-level developer and user prompts into structured, multi-step execution plans and automates local system auditing, code analysis, and workflows—all with **zero cloud data egress**, total privacy, and near-zero latency.

---

## 🌟 Key Features

- **100% Local Inference:** Powered by Google Gemma (Gemma 2 2B / 9B, CodeGemma) running on-device via Ollama, llama.cpp, or MLX.
- **Zero Cloud Egress & Absolute Privacy:** Code, proprietary files, and sensitive prompts never leave your laptop.
- **Autonomous Task Planning:** Deconstructs complex user instructions into deterministic, verifiable execution steps using Gemma's structured instruction-following capabilities.
- **Local Tool Dispatcher:** Scans directories, extracts code metadata (classes, functions, imports), and monitors system telemetry natively.
- **Zero-Dependency Core:** Built using lightweight standard libraries with pluggable local endpoints and deterministic fallback modes for testing and CI/CD environments.

---

## 🏗️ Architecture

```mermaid
flowchart TD
    User([💻 Developer / User]) -->|CLI / Script Command| CLI[jinn CLI / Interface]
    CLI --> Agent[Jinn Autonomous Agent]
    
    subgraph Local Laptop Boundary
        Agent --> Engine[Gemma Local Engine]
        Engine <-->|Localhost HTTP / IPC| Gemma[Google Gemma\n(Ollama / llama.cpp / GGUF)]
        
        Agent --> Tools[Local Tool Execution]
        Tools --> FInspect[File & Workspace Inspector]
        Tools --> CAnalyze[Python Code & AST Analyzer]
        Tools --> Telemetry[System Privacy & Telemetry Guard]
    end
    
    Tools --> Outputs[Structured JSON & Markdown Reports]
    Outputs --> User
```

---

## 🚀 Quickstart & Installation

### 1. Prerequisites
- Python 3.9 or higher
- Optional (for hardware inference): [Ollama](https://ollama.ai) or [llama.cpp](https://github.com/ggerganov/llama.cpp)

### 2. Pull Gemma Locally (Recommended)
```bash
# Pull and start Gemma 2 (2B lightweight or 9B)
ollama pull gemma2:2b
ollama run gemma2:2b
```

### 3. Clone and Setup Jinn
```bash
git clone https://github.com/DikshantJangra/Jinn.git
cd Jinn
pip install -r requirements.txt
pip install -e .
```

---

## 💻 Execution Instructions

### CLI Usage

#### 1. Inspect System Telemetry & Gemma Local Engine Status
```bash
python3 -m jinn.cli info
# or if installed via pip:
jinn info
```

#### 2. Plan a Complex Task with Gemma
```bash
python3 -m jinn.cli plan "Perform local zero-egress security and structure audit of workspace"
```

#### 3. Run an Autonomous Workspace Audit
```bash
python3 -m jinn.cli audit --dir .
```

### Running the Example Demo
```bash
python3 examples/demo_run.py
```

---

## 🧪 Automated Testing & CI

Jinn includes automated unit tests covering prompts, tool dispatch, fallback resilience, and the autonomous agent loop:

```bash
# Run with standard library unittest
python3 -m unittest discover tests

# Or with pytest
pytest -v
```

All pushes and pull requests to `main` are automatically verified through the [CI Pipeline](.github/workflows/ci.yml).

---

## 📁 Repository Structure

```
Jinn/
├── .github/
│   ├── workflows/
│   │   └── ci.yml                 # Automated testing and verification CI
│   └── pull_request_template.md   # Required PR submission template
├── examples/
│   ├── demo_run.py                # Executable demonstration script
│   ├── input_task_planning.json   # Sample input for task planning
│   ├── output_task_planning.json  # Generated plan output from Gemma
│   ├── input_code_audit.json      # Sample input for workspace audit
│   └── output_code_audit.json     # Generated audit output
├── jinn/
│   ├── __init__.py                # Package metadata
│   ├── agent.py                   # Autonomous agent coordinator
│   ├── cli.py                     # Command-line interface
│   ├── engine.py                  # Local Gemma model interface
│   ├── prompts.py                 # Gemma prompt templates & turn formatting
│   └── tools.py                   # Local privacy-preserving system tools
├── tests/
│   ├── __init__.py
│   ├── test_agent.py              # Agent unit tests
│   ├── test_engine.py             # Inference engine tests
│   ├── test_prompts.py            # Prompt formatting tests
│   └── test_tools.py              # Local toolkit tests
├── HACKATHON.md                   # Hackathon details and model selection rationale
├── LICENSE                        # MIT Open Source License
├── requirements.txt               # Project dependencies
├── setup.py                       # Python packaging configuration
└── README.md                      # Project documentation
```

---

## 👥 Team Details

- **Team Name:** Jinn
- **Members:**
  - Dikshant Jangra
  - Somraj
  - Ritesh
- **Track:** SPECIAL TRACK: GEMMA
- **Problem Statement:** PROBLEM 08: Build Anything with Gemma – Local AI Innovation Challenge
- **Submission Deadline:** 8:30 PM, 31 October 2026

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
