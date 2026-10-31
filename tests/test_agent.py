import os
import tempfile
import unittest
from jinn.agent import JinnAgent
from jinn.engine import GemmaLocalEngine

class TestAgent(unittest.TestCase):
    def test_jinn_agent_plan(self):
        engine = GemmaLocalEngine(fallback_mode=True)
        agent = JinnAgent(engine=engine)
        plan_result = agent.plan_task("Set up local development pipeline")

        self.assertEqual(plan_result["task"], "Set up local development pipeline")
        self.assertIn("plan", plan_result)
        self.assertIn("steps", plan_result["plan"])
        self.assertTrue(len(plan_result["plan"]["steps"]) > 0)

    def test_jinn_agent_audit(self):
        engine = GemmaLocalEngine(fallback_mode=True)
        agent = JinnAgent(engine=engine)

        with tempfile.TemporaryDirectory() as tmp_dir:
            sample_file = os.path.join(tmp_dir, "app.py")
            with open(sample_file, "w") as f:
                f.write("print('test')")

            audit = agent.execute_local_audit(tmp_dir)
            self.assertEqual(audit["status"], "success")
            self.assertIn("telemetry", audit)
            self.assertIn("workspace", audit)
            self.assertEqual(audit["workspace"]["files_count"], 1)

if __name__ == "__main__":
    unittest.main()
