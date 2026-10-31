import unittest
from jinn.engine import GemmaLocalEngine

class TestEngine(unittest.TestCase):
    def test_engine_fallback(self):
        engine = GemmaLocalEngine(fallback_mode=True)
        res = engine.generate("Break down the following complex task into ordered, executable steps: test task")
        self.assertIn("response", res)
        self.assertEqual(res["mode"], "local_fallback")
        self.assertIn("steps", res["response"])

    def test_engine_generic_prompt(self):
        engine = GemmaLocalEngine(fallback_mode=True)
        res = engine.generate("Hello Gemma")
        self.assertIn("[Gemma Local] Successfully processed request", res["response"])

if __name__ == "__main__":
    unittest.main()
