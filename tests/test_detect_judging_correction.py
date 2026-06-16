#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts" / "detect-judging-correction.py"

spec = importlib.util.spec_from_file_location("detect_judging_correction", HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class DetectJudgingCorrectionTest(unittest.TestCase):
    def test_prompt_mentions_level_correction(self):
        self.assertTrue(hook.prompt_mentions_level_correction("不对，应该是 L2"))
        self.assertFalse(hook.prompt_mentions_level_correction("帮我加个按钮"))

    def test_transcript_has_recent_judgment(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as f:
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "级别 = L3｜理由 = bug"}],
                }
            }))
            f.write("\n")
            f.flush()

            self.assertTrue(hook.transcript_has_recent_judgment(f.name))

    def test_transcript_without_judgment_is_false(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as f:
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "普通回复"}],
                }
            }))
            f.write("\n")
            f.flush()

            self.assertFalse(hook.transcript_has_recent_judgment(f.name))


if __name__ == "__main__":
    unittest.main()
