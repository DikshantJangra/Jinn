import os
import tempfile
import unittest
from jinn.tools import LocalToolKit

class TestTools(unittest.TestCase):
    def test_system_telemetry(self):
        telemetry = LocalToolKit.system_telemetry()
        self.assertIn("os", telemetry)
        self.assertIn("python_version", telemetry)
        self.assertEqual(telemetry["privacy_mode"], "100% Offline / Local Execution")

    def test_inspect_workspace(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            test_file = os.path.join(tmp_dir, "hello.py")
            with open(test_file, "w") as f:
                f.write("print('hello world')")

            res = LocalToolKit.inspect_workspace(tmp_dir)
            self.assertEqual(res["files_count"], 1)
            self.assertEqual(res["file_list"][0]["path"], "hello.py")

    def test_analyze_python_file(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            test_file = os.path.join(tmp_dir, "sample.py")
            with open(test_file, "w") as f:
                f.write("""import sys
from os import path

class MyTest:
    pass

def my_func():
    return 42
""")
            analysis = LocalToolKit.analyze_python_file(test_file)
            self.assertIn("MyTest", analysis["classes"])
            self.assertIn("my_func", analysis["functions"])
            self.assertEqual(len(analysis["imports"]), 2)

if __name__ == "__main__":
    unittest.main()
