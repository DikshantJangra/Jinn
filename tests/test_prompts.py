import unittest
from jinn.prompts import format_gemma_turn, format_planning_prompt

class TestPrompts(unittest.TestCase):
    def test_format_gemma_turn(self):
        turn = format_gemma_turn("Summarize this document")
        self.assertIn("<start_of_turn>user", turn)
        self.assertIn("<end_of_turn>", turn)
        self.assertIn("<start_of_turn>model", turn)
        self.assertIn("Summarize this document", turn)

    def test_format_planning_prompt(self):
        prompt = format_planning_prompt("Build an offline analyzer")
        self.assertIn("Respond strictly with valid JSON", prompt)
        self.assertIn("Build an offline analyzer", prompt)

if __name__ == "__main__":
    unittest.main()
