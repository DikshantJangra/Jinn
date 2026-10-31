import unittest
from unittest.mock import patch
from jinn.agent import JinnAgent
from jinn.hands import mac


class FakeEngine:
    def __init__(self, replies):
        self.replies = list(replies)
        self.seen = []

    def chat(self, messages, tools=None):
        self.seen.append(list(messages))
        return self.replies.pop(0)


def tc(name, **args):
    return {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": name, "arguments": args}}]}


class TestHands(unittest.TestCase):
    def test_format_nodes_hides_passwords_and_dupes(self):
        out = mac.format_nodes([
            {"id": 0, "role": "AXButton", "label": "Send", "value": ""},
            {"id": 1, "role": "AXTextField", "label": "Password", "value": "", "secure": True},
            {"id": 2, "role": "AXTextField", "label": "To", "value": "bob"},
        ])
        self.assertEqual(out.splitlines(), ['[0] Button "Send"', '[1] TextField (password field) "Password"', '[2] TextField "To" = "bob"'])

    def test_wait_idle_backs_off_then_proceeds(self):
        idles = iter([0.1, 0.2, 5.0])
        slept = []
        waited = mac.wait_idle(lambda: next(idles), sleep=slept.append)
        self.assertEqual(len(slept), 2)
        self.assertAlmostEqual(waited, 0.6)
        self.assertEqual(mac.wait_idle(lambda: 0.0, sleep=lambda s: None, limit=1.0) >= 1.0, True)  # user never idle: gives up at the limit

    def test_unknown_tool_and_confirm_policy(self):
        with self.assertRaises(RuntimeError):
            mac.call("nope", {})
        self.assertTrue(mac.needs_confirm("applescript", {}) and mac.needs_confirm("type_text", {}) and mac.needs_confirm("web_click", {"target": "Submit"}))
        mac._labels.update({0: "Send", 1: "Next"})
        self.assertTrue(mac.needs_confirm("click", {"element_id": "0"}) and mac.needs_confirm("click", {"element_id": "x"}))
        self.assertFalse(mac.needs_confirm("click", {"element_id": 1}) or mac.needs_confirm("snapshot", {}))
        with patch.object(mac, "_web_risky", return_value=False):
            self.assertFalse(mac.needs_confirm("web_click", {"target": "Next"}))
        self.assertTrue(mac.needs_confirm("web_click", {"target": "Next"}))  # no browser reachable -> cannot tell -> ask

    def test_act_loop_runs_tools_and_feeds_results_back(self):
        eng = FakeEngine([tc("snapshot", app="Mail"), {"role": "assistant", "content": "Done."}])
        with patch.object(mac, "call", return_value='[0] Button "Send"') as call:
            res = JinnAgent(engine=eng).act("look at mail")
        call.assert_called_once_with("snapshot", {"app": "Mail"})
        self.assertEqual(res, {"status": "done", "answer": "Done."})
        self.assertEqual(eng.seen[1][-1]["content"], '[0] Button "Send"')

    def test_act_denies_risky_without_confirm_and_stops_loops(self):
        eng = FakeEngine([tc("applescript", src="x"), {"role": "assistant", "content": "ok"}])
        with patch.object(mac, "call") as call:
            JinnAgent(engine=eng).act("do it")
        call.assert_not_called()
        self.assertEqual(eng.seen[1][-1]["content"], "error: user declined")
        eng = FakeEngine([tc("snapshot", app="A")] * 4)
        with patch.object(mac, "call", return_value="x"):
            self.assertEqual(JinnAgent(engine=eng).act("loop")["status"], "stalled")


if __name__ == "__main__":
    unittest.main()
