import json
import os
import random
import statistics
import sys
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import server  # noqa: E402

FAST = {kind: [0.001, 0.001] for kind in server.KINDS}


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class LimiterTest(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.limiter = server.Limiter(self.clock)

    def test_charges_tokens_and_refuses_with_the_real_wait(self):
        self.assertTrue(self.limiter.admit("m", 60, 600, 500).allowed)
        refused = self.limiter.admit("m", 60, 600, 200)
        self.assertFalse(refused.allowed)
        self.assertEqual(refused.exhausted, "tokens")
        self.assertAlmostEqual(refused.retry_after, 10.0)
        self.clock.now += 10
        self.assertTrue(self.limiter.admit("m", 60, 600, 200).allowed)

    def test_refused_requests_still_count_against_rpm(self):
        self.limiter.admit("m", 60, 600, 600)
        self.limiter.admit("m", 60, 600, 600)
        state = self.limiter.snapshot()["m"]["requests"]
        self.assertEqual(state["remaining"], 58)

    def test_rpm_exhaustion(self):
        self.assertTrue(self.limiter.admit("m", 2, 0, 0).allowed)
        self.assertTrue(self.limiter.admit("m", 2, 0, 0).allowed)
        refused = self.limiter.admit("m", 2, 0, 0)
        self.assertEqual(refused.exhausted, "requests")
        self.assertAlmostEqual(refused.retry_after, 30.0)

    def test_request_larger_than_the_bucket_never_fits(self):
        refused = self.limiter.admit("m", 0, 600, 700)
        self.assertTrue(refused.too_large)
        self.assertIsNone(refused.retry_after)

    def test_buckets_are_per_model_and_off_without_limits(self):
        self.limiter.admit("a", 0, 600, 600)
        self.assertTrue(self.limiter.admit("b", 0, 600, 600).allowed)
        self.assertEqual(self.limiter.admit("c", 0, 0, 10**9).quotas, {})


class FormatTest(unittest.TestCase):
    def test_duration_matches_openai(self):
        self.assertEqual(server.duration(0.156), "156ms")
        self.assertEqual(server.duration(3.712), "3.71s")
        self.assertEqual(server.duration(59.6), "59.6s")
        self.assertEqual(server.duration(360), "6m0s")

    def test_headers(self):
        headers = server.ratelimit_headers({"tokens": {"limit": 100, "remaining": 40, "reset": 36.0}})
        self.assertEqual(headers["x-ratelimit-limit-tokens"], "100")
        self.assertEqual(headers["x-ratelimit-remaining-tokens"], "40")
        self.assertEqual(headers["x-ratelimit-reset-tokens"], "36s")

    def test_charge_modes(self):
        self.assertEqual(server.charge(server.Config(charge="max"), 500, 32000), 32000)
        self.assertEqual(server.charge(server.Config(charge="max"), 50000, 32000), 50000)
        self.assertEqual(server.charge(server.Config(charge="sum"), 500, 32000), 32500)


def schema_body(name):
    return {"text": {"format": {"type": "json_schema", "name": name, "schema": {}}}}


def chat_body(items, tool_choice="auto"):
    return {"tools": [{"type": "function", "name": "request_documents"}], "tool_choice": tool_choice, "input": items}


class ClassifyTest(unittest.TestCase):
    def setUp(self):
        self.config = server.Config()

    def test_structured_calls(self):
        cases = {
            "sufficiency": "chat_judge",
            "answer_check": "chat_judge",
            "setting_check_candidates": "check_find",
            "setting_check_setting_candidates": "check_find",
            "setting_check_judgement": "check_judge",
            "refresh_candidate": "refresh",
            "something_else": "other",
        }
        for name, kind in cases.items():
            self.assertEqual(server.classify(schema_body(name), self.config), kind)

    def test_summary_has_no_tools_or_schema(self):
        self.assertEqual(server.classify({"input": "본문"}, self.config), "summary")

    def test_chat_reads_then_answers(self):
        first = [{"role": "user", "content": "지도 a1b2c3d4 e5f6a7b8"}]
        self.assertEqual(server.classify(chat_body(first), self.config), "chat_tool")
        call = server.function_call(["a1b2c3d4"])
        second = first + [call, {"type": "function_call_output", "call_id": call["call_id"], "output": "x"}]
        self.assertEqual(server.classify(chat_body(second), self.config), "chat_answer")
        self.assertEqual(server.classify(chat_body(first, "none"), self.config), "chat_answer")

    def test_more_reads_skip_documents_already_requested(self):
        config = server.Config(tool_calls=2)
        first = [{"role": "user", "content": "지도 a1b2c3d4 e5f6a7b8"}]
        call = server.function_call(["a1b2c3d4"])
        second = first + [call, {"type": "function_call_output", "call_id": call["call_id"], "output": "x"}]
        self.assertEqual(server.classify(chat_body(second), config), "chat_tool")
        self.assertEqual(server.unread_ids(chat_body(second))[0], ["e5f6a7b8"])


SETTING = "레나는 무너진 성당에서 처음 각성했다. 그녀의 눈은 회색이다. 카엘은 북쪽 항구 출신이다."
EARLIER = "1화. 레나는 성당의 종소리를 들으며 깨어났다. 손끝에서 빛이 번졌다."
CHAPTER = "레나는 북쪽 온실에서 처음 각성했다고 회상했다. 그녀의 푸른 눈이 빛났다. 카엘은 남쪽 사막에서 왔다고 말했다."


def check_input():
    settings = f'<settings>\n<document id="aaaa1111" kind="SETTING" title="레나">\n<body>\n{SETTING}\n</body>\n</document>\n</settings>'
    earlier = f'<earlier>\n<document id="bbbb2222" kind="manuscript" number="1" title="1화">\n<body>\n{EARLIER}\n</body>\n</document>\n</earlier>'
    chapter = f'<author locale="ko"/>\n<chapter id="cccc3333" number="2" title="2화">\n{CHAPTER}\n</chapter>'
    blocks = [{"type": "input_text", "text": text} for text in (settings, earlier, chapter)]
    return [{"role": "user", "content": blocks}]


class OutputTest(unittest.TestCase):
    def test_candidates_quote_real_text(self):
        random.seed(7)
        found = server.candidates({"input": check_input()}, 5, settings_only=False)
        self.assertEqual(len(found), 5)
        sources = {"aaaa1111": server.collapse(SETTING), "bbbb2222": server.collapse(EARLIER)}
        quotes = []
        for item in found:
            self.assertIn(item["source_id"], sources)
            self.assertIn(item["source_quote"], sources[item["source_id"]])
            self.assertIn(item["quote"], server.collapse(CHAPTER))
            self.assertEqual(set(item), {"kind", "source_id", "source_quote", "quote", "summary", "direction", "core", "related_ids"})
            quotes.append(item["quote"])
        for a in quotes:
            for b in quotes:
                if a is not b:
                    self.assertFalse(a in b or b in a)

    def test_settings_only_fields(self):
        found = server.candidates({"input": check_input()}, 2, settings_only=True)
        self.assertEqual(set(found[0]), {"source_id", "source_quote", "quote", "summary", "direction"})

    def test_no_candidates_by_default(self):
        body = {"input": check_input(), **schema_body("setting_check_candidates")}
        output = server.output_of("check_find", body, server.Config())
        self.assertEqual(json.loads(output[0]["content"][0]["text"]), {"candidates": []})

    def test_judges_pass_unless_rejecting(self):
        self.assertTrue(server.judged("sufficiency", {}, server.Config())["sufficient"])
        rejecting = server.Config(judge_reject=1)
        self.assertFalse(server.judged("sufficiency", {}, rejecting)["sufficient"])
        self.assertFalse(server.judged("answer_check", {}, rejecting)["answer_ok"])

    def test_setting_check_judge_keeps_the_candidate(self):
        schema = {
            "type": "object",
            "required": ["verdict", "confidence"],
            "properties": {
                "verdict": {"type": "string", "enum": ["CONFLICT", "INSUFFICIENT"]},
                "confidence": {"type": "string", "enum": ["HIGH", "LOW"]},
            },
        }
        self.assertEqual(server.judged("setting_check_judgement", schema, server.Config())["verdict"], "CONFLICT")


class DelayTest(unittest.TestCase):
    def test_lognormal_matches_median_and_p90(self):
        random.seed(1)
        config = server.Config()
        samples = sorted(server.delay(config, "chat_answer", 0) for _ in range(4000))
        self.assertAlmostEqual(statistics.median(samples), 4.6, delta=0.4)
        self.assertAlmostEqual(samples[int(len(samples) * 0.9)], 10.8, delta=1.2)

    def test_scale_input_and_cap(self):
        random.seed(2)
        config = server.Config(latency={"count": [1, 1]}, latency_scale=2, ms_per_1k_input=500, latency_max=3)
        self.assertAlmostEqual(server.delay(config, "count", 1000), 2.5)
        self.assertEqual(server.delay(config, "count", 100000), 3)


class ConfigTest(unittest.TestCase):
    def test_rejects_bad_values(self):
        for values in (
            {"nope": 1},
            {"faults": {"boom": 0.1}},
            {"faults": {"quota": 2}},
            {"latency": {"chat_tool": [5, 1]}},
            {"charge": "avg"},
            {"tpm": -1},
            {"judge_reject": 1.5},
        ):
            with self.assertRaises(ValueError, msg=values):
                server.Config().update(values)

    def test_env(self):
        os.environ.update({"MOCK_TPM": "2000000", "MOCK_FAULTS": "quota=0.1,overloaded=0.2", "MOCK_LATENCY_CHAT_JUDGE": "1,2"})
        try:
            config = server.Config.from_env()
        finally:
            for name in ("MOCK_TPM", "MOCK_FAULTS", "MOCK_LATENCY_CHAT_JUDGE"):
                os.environ.pop(name)
        self.assertEqual(config.tpm, 2000000)
        self.assertEqual(config.faults, {"quota": 0.1, "overloaded": 0.2})
        self.assertEqual(config.latency["chat_judge"], (1.0, 2.0))
        self.assertEqual(config.latency["chat_tool"], server.LATENCY["chat_tool"])


class HttpTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = server.Server(("127.0.0.1", 0), server.Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        server.CONFIG = server.Config(latency=FAST)
        server.LIMITER.reset()
        server.STATS.reset()

    def call(self, path, payload=None, headers=None):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(self.base + path, data=data, headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                raw = response.read().decode()
                return response.status, response.headers, raw
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.headers, error.read().decode()

    def test_rate_limit_round_trip(self):
        status, _, _ = self.call("/_mock/config", {"tpm": 40000, "rpm": 100})
        self.assertEqual(status, 200)
        body = {"model": "gpt-6-luna", "input": "요약할 본문", "max_output_tokens": 32000}
        status, headers, raw = self.call("/v1/responses", body)
        self.assertEqual(status, 200)
        self.assertEqual(headers["x-ratelimit-limit-tokens"], "40000")
        self.assertEqual(headers["x-ratelimit-remaining-tokens"], "8000")
        self.assertEqual(headers["x-ratelimit-remaining-requests"], "99")
        self.assertTrue(json.loads(raw)["output"][0]["content"][0]["text"])

        status, headers, raw = self.call("/v1/responses", body, {"x-stainless-retry-count": "1"})
        self.assertEqual(status, 429)
        error = json.loads(raw)["error"]
        self.assertEqual(error["code"], "rate_limit_exceeded")
        self.assertEqual(error["type"], "tokens")
        self.assertGreaterEqual(int(headers["retry-after"]), 35)
        self.assertGreaterEqual(int(headers["retry-after-ms"]), 35000)

        _, _, raw = self.call("/_mock/stats")
        summary = json.loads(raw)["kinds"]["summary"]
        self.assertEqual(summary["requests"], 2)
        self.assertEqual(summary["retries"], 1)
        self.assertEqual(summary["results"], {"ok": 1, "rate_limited": 1})
        self.assertEqual(summary["tokens_charged"], 32000)

        _, headers, raw = self.call("/metrics")
        self.assertIn('openai_mock_requests_total{kind="summary",result="rate_limited"} 1', raw)
        self.assertIn('openai_mock_bucket_limit{model="gpt-6-luna",bucket="tokens"} 40000', raw)

        self.call("/_mock/reset", {})
        status, _, _ = self.call("/v1/responses", body)
        self.assertEqual(status, 200)

    def test_token_count_is_free_by_default(self):
        self.call("/_mock/config", {"tpm": 10})
        status, _, raw = self.call("/v1/responses/input_tokens", {"model": "m", "input": "x" * 400})
        self.assertEqual(status, 200)
        self.assertGreater(json.loads(raw)["input_tokens"], 10)

    def test_injected_faults(self):
        self.call("/_mock/config", {"faults": {"quota": 1}})
        status, _, raw = self.call("/v1/responses", {"model": "m", "input": "x"})
        self.assertEqual(status, 429)
        self.assertEqual(json.loads(raw)["error"]["code"], "insufficient_quota")
        self.call("/_mock/config", {"faults": {"quota": 0, "overloaded": 1}})
        status, _, raw = self.call("/v1/responses", {"model": "m", "input": "x"})
        self.assertEqual(status, 503)
        self.assertEqual(json.loads(raw)["error"]["code"], "server_is_overloaded")

    def test_bad_config_is_rejected_and_kept(self):
        status, _, _ = self.call("/_mock/config", {"tpm": 5, "faults": {"boom": 1}})
        self.assertEqual(status, 400)
        _, _, raw = self.call("/_mock/config")
        self.assertEqual(json.loads(raw)["tpm"], 0)

    def test_chat_turn_shape(self):
        items = [{"role": "user", "content": [{"type": "input_text", "text": "지도 a1b2c3d4"}]}]
        _, _, raw = self.call("/v1/responses", chat_body(items))
        call = json.loads(raw)["output"][0]
        self.assertEqual(call["type"], "function_call")
        self.assertEqual(json.loads(call["arguments"]), {"ranking": ["a1b2c3d4"]})


if __name__ == "__main__":
    unittest.main()
