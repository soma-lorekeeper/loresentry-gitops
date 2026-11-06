import json
import math
import os
import random
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SHORT_ID = re.compile(r"\b[0-9a-f]{8}\b")
DOCUMENT = re.compile(r'<document id="([^"]+)"[^>]*>(.*?)</document>', re.S)
BODY = re.compile(r"<body>(.*?)</body>", re.S)
CHAPTER = re.compile(r"<chapter id=\"[^\"]+\"[^>]*>(.*?)</chapter>", re.S)
SPACES = re.compile(r"\s+")

KINDS = (
    "chat_tool",
    "chat_answer",
    "chat_judge",
    "check_find",
    "check_judge",
    "summary",
    "refresh",
    "count",
    "other",
)
JUDGES = {"sufficiency", "answer_check"}
CHECK_FINDS = {"setting_check_candidates", "setting_check_setting_candidates"}
FAULTS = ("rate_limit", "quota", "overloaded", "slow_down", "timeout")
LATENCY = {
    "chat_tool": (2.1, 5.4),
    "chat_answer": (4.6, 10.8),
    "chat_judge": (1.2, 2.5),
    "check_find": (30.0, 90.0),
    "check_judge": (3.0, 8.0),
    "summary": (3.0, 8.0),
    "refresh": (60.0, 180.0),
    "count": (0.06, 0.12),
    "other": (3.0, 8.0),
}
ANSWER = (
    "이 답은 dev 클러스터의 OpenAI mock 이 만든 부하 테스트용 문장입니다. "
    "This answer was produced by the dev cluster's OpenAI mock for load testing. "
)


def env_int(name, default):
    value = os.environ.get(name)
    return int(value) if value else default


def env_float(name, default):
    value = os.environ.get(name)
    return float(value) if value else default


def span(value):
    low, _, high = str(value).partition("-")
    return int(low), int(high or low)


def pair(value):
    median, _, p90 = str(value).partition(",")
    return float(median), float(p90 or median)


def rates(value):
    found = {}
    for part in str(value or "").split(","):
        if part.strip():
            name, _, rate = part.partition("=")
            found[name.strip()] = float(rate)
    return found


class Config:
    FIELDS = (
        "tpm",
        "rpm",
        "charge",
        "chars_per_token",
        "count_limited",
        "latency",
        "latency_scale",
        "latency_max",
        "ms_per_1k_input",
        "faults",
        "timeout_seconds",
        "judge_reject",
        "check_candidates",
        "tool_calls",
        "max_ranking",
        "answer_chars",
        "summary_chars",
    )

    def __init__(self, **values):
        self.tpm = 0
        self.rpm = 0
        self.charge = "max"
        self.chars_per_token = 4.0
        self.count_limited = False
        self.latency = dict(LATENCY)
        self.latency_scale = 1.0
        self.latency_max = 230.0
        self.ms_per_1k_input = 0.0
        self.faults = {}
        self.timeout_seconds = 130.0
        self.judge_reject = 0.0
        self.check_candidates = 0
        self.tool_calls = 1
        self.max_ranking = 3
        self.answer_chars = (400, 3000)
        self.summary_chars = (130, 300)
        self.update(values)

    @classmethod
    def from_env(cls):
        latency = {
            kind: pair(os.environ[f"MOCK_LATENCY_{kind.upper()}"])
            for kind in KINDS
            if os.environ.get(f"MOCK_LATENCY_{kind.upper()}")
        }
        return cls(
            tpm=env_int("MOCK_TPM", 0),
            rpm=env_int("MOCK_RPM", 0),
            charge=os.environ.get("MOCK_TPM_CHARGE", "max"),
            chars_per_token=env_float("MOCK_CHARS_PER_TOKEN", 4.0),
            count_limited=os.environ.get("MOCK_COUNT_LIMITED") == "1",
            latency=latency,
            latency_scale=env_float("MOCK_LATENCY_SCALE", 1.0),
            latency_max=env_float("MOCK_LATENCY_MAX", 230.0),
            ms_per_1k_input=env_float("MOCK_MS_PER_1K_INPUT", 0.0),
            faults=rates(os.environ.get("MOCK_FAULTS")),
            timeout_seconds=env_float("MOCK_TIMEOUT_SECONDS", 130.0),
            judge_reject=env_float("MOCK_JUDGE_REJECT", 0.0),
            check_candidates=env_int("MOCK_CHECK_CANDIDATES", 0),
            tool_calls=env_int("MOCK_TOOL_CALLS", 1),
            max_ranking=env_int("MOCK_MAX_RANKING", 3),
            answer_chars=span(os.environ.get("MOCK_ANSWER_CHARS", "400-3000")),
            summary_chars=span(os.environ.get("MOCK_SUMMARY_CHARS", "130-300")),
        )

    def update(self, values):
        unknown = set(values) - set(self.FIELDS)
        if unknown:
            raise ValueError(f"unknown settings: {', '.join(sorted(unknown))}")
        for name, value in values.items():
            if name == "latency":
                for kind, entry in value.items():
                    if kind not in KINDS:
                        raise ValueError(f"unknown kind: {kind}")
                    median, p90 = pair(entry) if isinstance(entry, str) else entry
                    if median <= 0 or p90 < median:
                        raise ValueError(f"latency for {kind} needs 0 < median <= p90")
                    self.latency[kind] = (float(median), float(p90))
            elif name == "faults":
                for fault, rate in value.items():
                    if fault not in FAULTS:
                        raise ValueError(f"unknown fault: {fault}")
                    if not 0 <= float(rate) <= 1:
                        raise ValueError(f"fault rate for {fault} must be within 0..1")
                    self.faults[fault] = float(rate)
            elif name in ("answer_chars", "summary_chars"):
                low, high = span(value) if isinstance(value, str) else value
                if not 0 < low <= high:
                    raise ValueError(f"{name} needs 0 < low <= high")
                setattr(self, name, (int(low), int(high)))
            elif name == "charge":
                if value not in ("max", "sum"):
                    raise ValueError("charge must be max or sum")
                self.charge = value
            elif name == "count_limited":
                self.count_limited = bool(value)
            elif name in ("tpm", "rpm", "check_candidates", "tool_calls", "max_ranking"):
                if int(value) < 0:
                    raise ValueError(f"{name} must not be negative")
                setattr(self, name, int(value))
            else:
                if float(value) < 0:
                    raise ValueError(f"{name} must not be negative")
                setattr(self, name, float(value))
        if self.chars_per_token <= 0:
            raise ValueError("chars_per_token must be positive")
        if not 0 <= self.judge_reject <= 1:
            raise ValueError("judge_reject must be within 0..1")

    def copy(self):
        clone = Config.__new__(Config)
        clone.__dict__.update(self.__dict__)
        clone.latency = dict(self.latency)
        clone.faults = dict(self.faults)
        return clone

    def as_dict(self):
        data = {name: getattr(self, name) for name in self.FIELDS}
        data["latency"] = {kind: list(value) for kind, value in self.latency.items()}
        data["answer_chars"] = list(self.answer_chars)
        data["summary_chars"] = list(self.summary_chars)
        return data


class Bucket:
    def __init__(self, limit, now):
        self.limit = limit
        self.rate = limit / 60.0
        self.level = float(limit)
        self.updated = now

    def refill(self, now):
        elapsed = max(0.0, now - self.updated)
        self.level = min(self.limit, self.level + elapsed * self.rate)
        self.updated = max(self.updated, now)

    def wait(self, amount):
        missing = amount - self.level
        return 0.0 if missing <= 0 else missing / self.rate

    def take(self, amount):
        self.level = max(0.0, self.level - amount)

    def state(self):
        return {
            "limit": self.limit,
            "remaining": max(0, math.floor(self.level)),
            "reset": (self.limit - self.level) / self.rate,
        }


class Admission:
    def __init__(self, allowed, quotas, retry_after=None, exhausted=None, too_large=False):
        self.allowed = allowed
        self.quotas = quotas
        self.retry_after = retry_after
        self.exhausted = exhausted
        self.too_large = too_large


class Limiter:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lock = threading.Lock()
        self.buckets = {}

    def reset(self):
        with self.lock:
            self.buckets.clear()

    def bucket(self, model, kind, limit, now):
        if not limit:
            return None
        found = self.buckets.get((model, kind))
        if found is None or found.limit != limit:
            found = self.buckets[(model, kind)] = Bucket(limit, now)
        found.refill(now)
        return found

    def admit(self, model, rpm, tpm, tokens):
        with self.lock:
            now = self.clock()
            requests = self.bucket(model, "requests", rpm, now)
            budget = self.bucket(model, "tokens", tpm, now)
            too_large = budget is not None and tokens > budget.limit
            waits = []
            if requests is not None:
                waits.append(("requests", requests.wait(1)))
            if budget is not None and not too_large:
                waits.append(("tokens", budget.wait(tokens)))
            blocking = [entry for entry in waits if entry[1] > 0]
            if too_large or blocking:
                if requests is not None:
                    requests.take(1)
                exhausted = "tokens" if too_large else max(blocking, key=lambda e: e[1])[0]
                retry = None
                if not too_large:
                    retry = max(
                        requests.wait(1) if requests is not None else 0.0,
                        budget.wait(tokens) if budget is not None else 0.0,
                    )
                return Admission(False, self.quotas(requests, budget), retry, exhausted, too_large)
            if requests is not None:
                requests.take(1)
            if budget is not None:
                budget.take(tokens)
            return Admission(True, self.quotas(requests, budget))

    def count(self, model, rpm):
        with self.lock:
            requests = self.bucket(model, "requests", rpm, self.clock())
            if requests is not None:
                requests.take(1)

    def peek(self, model, rpm, tpm):
        with self.lock:
            now = self.clock()
            return self.quotas(
                self.bucket(model, "requests", rpm, now),
                self.bucket(model, "tokens", tpm, now),
            )

    def snapshot(self):
        with self.lock:
            now = self.clock()
            found = {}
            for (model, kind), bucket in self.buckets.items():
                bucket.refill(now)
                found.setdefault(model, {})[kind] = bucket.state()
            return found

    @staticmethod
    def quotas(requests, budget):
        return {
            kind: bucket.state()
            for kind, bucket in (("requests", requests), ("tokens", budget))
            if bucket is not None
        }


def duration(seconds):
    if seconds < 1:
        return f"{max(0, round(seconds * 1000))}ms"
    if seconds < 60:
        return f"{seconds:.3g}s"
    minutes, rest = divmod(round(seconds), 60)
    return f"{minutes}m{rest}s"


def ratelimit_headers(quotas):
    headers = {}
    for kind, quota in quotas.items():
        headers[f"x-ratelimit-limit-{kind}"] = str(quota["limit"])
        headers[f"x-ratelimit-remaining-{kind}"] = str(quota["remaining"])
        headers[f"x-ratelimit-reset-{kind}"] = duration(quota["reset"])
    return headers


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        with self.lock:
            self.started = time.time()
            self.in_flight = 0
            self.kinds = {}

    def entry(self, kind):
        found = self.kinds.get(kind)
        if found is None:
            found = self.kinds[kind] = {
                "requests": 0,
                "retries": 0,
                "results": {},
                "tokens_charged": 0,
                "input_tokens": 0,
                "output_tokens": 0,
                "delay_sum": 0.0,
                "delay_count": 0,
                "delay_max": 0.0,
            }
        return found

    def request(self, kind, retry):
        with self.lock:
            entry = self.entry(kind)
            entry["requests"] += 1
            entry["retries"] += 1 if retry else 0

    def result(self, kind, result):
        with self.lock:
            results = self.entry(kind)["results"]
            results[result] = results.get(result, 0) + 1

    def charged(self, kind, tokens):
        with self.lock:
            self.entry(kind)["tokens_charged"] += tokens

    def begin(self):
        with self.lock:
            self.in_flight += 1

    def end(self, kind, delay, input_tokens, output_tokens):
        with self.lock:
            self.in_flight -= 1
            entry = self.entry(kind)
            entry["delay_sum"] += delay
            entry["delay_count"] += 1
            entry["delay_max"] = max(entry["delay_max"], delay)
            entry["input_tokens"] += input_tokens
            entry["output_tokens"] += output_tokens

    def snapshot(self):
        with self.lock:
            kinds = {}
            for kind, entry in self.kinds.items():
                copy = dict(entry, results=dict(entry["results"]))
                count = copy["delay_count"]
                copy["delay_avg"] = round(copy["delay_sum"] / count, 3) if count else None
                kinds[kind] = copy
            return {
                "since": self.started,
                "seconds": round(time.time() - self.started, 1),
                "in_flight": self.in_flight,
                "kinds": kinds,
            }


CONFIG_LOCK = threading.Lock()
CONFIG = Config.from_env()
LIMITER = Limiter()
STATS = Stats()


def current():
    with CONFIG_LOCK:
        return CONFIG.copy()


def texts(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from texts(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from texts(item)


def collapse(text):
    return SPACES.sub(" ", text).strip()


def estimate(chars, config):
    return max(1, math.ceil(chars / config.chars_per_token))


def charge(config, input_tokens, max_output):
    if config.charge == "sum":
        return input_tokens + max_output
    return max(input_tokens, max_output)


def delay(config, kind, input_tokens):
    median, p90 = config.latency[kind]
    sigma = math.log(p90 / median) / 1.2816 if p90 > median else 0.0
    seconds = random.lognormvariate(math.log(median), sigma) * config.latency_scale
    seconds += input_tokens / 1000 * config.ms_per_1k_input / 1000
    return min(seconds, config.latency_max)


def resolve(schema, root):
    while isinstance(schema, dict) and "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        schema = node
    return schema


def sample(schema, root):
    schema = resolve(schema, root)
    if not isinstance(schema, dict):
        return None
    for key in ("anyOf", "oneOf"):
        if key in schema:
            options = [resolve(s, root) for s in schema[key]]
            concrete = [s for s in options if s.get("type") != "null"] or options
            return sample(concrete[0], root)
    if "const" in schema:
        return schema["const"]
    if "enum" in schema:
        return schema["enum"][0]
    kind = schema.get("type")
    if isinstance(kind, list):
        kind = next((k for k in kind if k != "null"), "null")
    if kind == "object" or "properties" in schema:
        props = schema.get("properties", {})
        return {name: sample(props[name], root) for name in schema.get("required", props)}
    if kind == "array":
        count = schema.get("minItems", 0)
        return [sample(schema.get("items", {}), root) for _ in range(count)]
    if kind == "string":
        return "x" * schema.get("minLength", 0)
    if kind == "integer":
        return schema.get("minimum", 0)
    if kind == "number":
        return float(schema.get("minimum", 0))
    if kind == "boolean":
        return True
    return None


def filler(chars):
    low, high = chars
    length = random.randint(low, high)
    return (ANSWER * (length // len(ANSWER) + 1))[:length]


def message(text):
    return {
        "type": "message",
        "id": f"msg_{uuid.uuid4().hex}",
        "role": "assistant",
        "status": "completed",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }


def function_call(ranking):
    return {
        "type": "function_call",
        "id": f"fc_{uuid.uuid4().hex}",
        "call_id": f"call_{uuid.uuid4().hex}",
        "name": "request_documents",
        "arguments": json.dumps({"ranking": ranking}),
        "status": "completed",
    }


def requested(items):
    seen = set()
    for item in items:
        if isinstance(item, dict) and item.get("type") == "function_call":
            try:
                seen.update(json.loads(item.get("arguments") or "{}").get("ranking") or [])
            except (ValueError, AttributeError):
                pass
    return seen


def unread_ids(body):
    items = body.get("input")
    items = items if isinstance(items, list) else []
    seen = requested(items)
    found = []
    for text in texts(items):
        for match in SHORT_ID.findall(text):
            if match not in seen and match not in found:
                found.append(match)
    reads = sum(1 for i in items if isinstance(i, dict) and i.get("type") == "function_call_output")
    return found, reads


def classify(body, config):
    fmt = (body.get("text") or {}).get("format") or {}
    if fmt.get("type") == "json_schema":
        name = fmt.get("name") or ""
        if name in JUDGES:
            return "chat_judge"
        if name in CHECK_FINDS:
            return "check_find"
        if name == "setting_check_judgement":
            return "check_judge"
        if name == "refresh_candidate":
            return "refresh"
        return "other"
    if body.get("tools"):
        if body.get("tool_choice") == "auto":
            ids, reads = unread_ids(body)
            if ids and reads < config.tool_calls:
                return "chat_tool"
        return "chat_answer"
    return "summary"


def window(text, start, end):
    size = min(end - start, random.randint(12, 40))
    if size < 4:
        return None
    begin = random.randint(start, end - size)
    return text[begin : begin + size]


def candidates(body, count, settings_only):
    joined = "\n".join(texts(body.get("input")))
    sources = []
    for alias, inner in DOCUMENT.findall(joined):
        found = BODY.search(inner)
        text = collapse(found.group(1)) if found else ""
        if len(text) >= 12:
            sources.append((alias, text))
    chapter = CHAPTER.search(joined)
    target = collapse(chapter.group(1)) if chapter else ""
    if not sources or count <= 0 or len(target) < 12:
        return []
    count = min(count, 20, max(1, len(target) // 12))
    step = len(target) // count
    picked = []
    for index in range(count):
        quote = window(target, index * step, (index + 1) * step)
        alias, source = random.choice(sources)
        source_quote = window(source, 0, len(source))
        if not quote or not source_quote:
            continue
        item = {
            "source_id": alias,
            "source_quote": source_quote,
            "quote": quote,
            "summary": "mock 후보: 설정과 원고가 어긋난다",
            "direction": "mock 후보의 방향",
        }
        if not settings_only:
            item = {"kind": "SETTING", **item, "core": False, "related_ids": []}
        picked.append(item)
    return picked


def judged(name, schema, config):
    rejected = random.random() < config.judge_reject
    if name == "sufficiency":
        if rejected:
            return {"sufficient": False, "missing": ["mock: 근거가 더 필요하다"]}
        return {"sufficient": True, "missing": []}
    if name == "answer_check":
        if rejected:
            return {"answer_ok": False, "problems": ["mock: 답을 다시 써야 한다"]}
        return {"answer_ok": True, "problems": []}
    return sample(schema, schema)


def output_of(kind, body, config):
    fmt = (body.get("text") or {}).get("format") or {}
    if kind == "chat_tool":
        ids, _ = unread_ids(body)
        return [function_call(random.sample(ids, min(config.max_ranking, len(ids))))]
    if kind == "chat_answer":
        return [message(filler(config.answer_chars))]
    if kind == "summary":
        return [message(filler(config.summary_chars))]
    if kind == "check_find":
        settings_only = fmt.get("name") == "setting_check_setting_candidates"
        value = {"candidates": candidates(body, config.check_candidates, settings_only)}
        return [message(json.dumps(value, ensure_ascii=False))]
    value = judged(fmt.get("name"), fmt.get("schema") or {}, config)
    return [message(json.dumps(value, ensure_ascii=False))]


def response_of(body, output, input_tokens, config):
    output_tokens = estimate(len(json.dumps(output, ensure_ascii=False)), config)
    return {
        "id": f"resp_{uuid.uuid4().hex}",
        "object": "response",
        "created_at": int(time.time()),
        "status": "completed",
        "model": body.get("model", "mock"),
        "output": output,
        "parallel_tool_calls": bool(body.get("parallel_tool_calls", False)),
        "tool_choice": body.get("tool_choice", "auto"),
        "tools": body.get("tools", []),
        "usage": {
            "input_tokens": input_tokens,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": output_tokens,
            "output_tokens_details": {"reasoning_tokens": 0},
            "total_tokens": input_tokens + output_tokens,
        },
    }


def draw_fault(config):
    roll = random.random()
    for name in FAULTS:
        rate = config.faults.get(name, 0.0)
        if roll < rate:
            return name
        roll -= rate
    return None


def error_body(message_text, kind, code):
    return {"error": {"message": message_text, "type": kind, "param": None, "code": code}}


def fault_response(fault, model):
    if fault == "rate_limit":
        return 429, error_body(
            f"Rate limit reached for {model} (injected by mock). Please try again in 1s.",
            "requests",
            "rate_limit_exceeded",
        ), {"retry-after": "1", "retry-after-ms": "1000"}
    if fault == "quota":
        return 429, error_body(
            "You exceeded your current quota, please check your plan and billing details.",
            "insufficient_quota",
            "insufficient_quota",
        ), {}
    if fault == "slow_down":
        return 429, error_body(
            "Please reduce the rate at which you are sending requests.",
            "requests",
            "slow_down",
        ), {"retry-after": "1", "retry-after-ms": "1000"}
    return 503, error_body(
        "The server is overloaded or not ready yet.", "server_error", "server_is_overloaded"
    ), {}


def limit_response(admission, model, requested_tokens):
    quota = admission.quotas.get(admission.exhausted, {})
    limit = quota.get("limit", 0)
    used = limit - quota.get("remaining", 0)
    unit = "tokens per min (TPM)" if admission.exhausted == "tokens" else "requests per min (RPM)"
    headers = ratelimit_headers(admission.quotas)
    if admission.too_large:
        text = (
            f"Request too large for {model} on {unit}: Limit {limit}, Requested {requested_tokens}. "
            "The input or output tokens must be reduced in order to run successfully."
        )
    else:
        wait = admission.retry_after
        text = (
            f"Rate limit reached for {model} on {unit}: Limit {limit}, Used {used}, "
            f"Requested {requested_tokens if admission.exhausted == 'tokens' else 1}. "
            f"Please try again in {duration(wait)}."
        )
        headers["retry-after"] = str(max(1, math.ceil(wait)))
        headers["retry-after-ms"] = str(max(1, math.ceil(wait * 1000)))
    return 429, error_body(text, admission.exhausted, "rate_limit_exceeded"), headers


def metrics_text():
    stats = STATS.snapshot()
    buckets = LIMITER.snapshot()
    lines = [
        "# TYPE openai_mock_requests_total counter",
        "# TYPE openai_mock_retries_total counter",
        "# TYPE openai_mock_tokens_charged_total counter",
        "# TYPE openai_mock_usage_tokens_total counter",
        "# TYPE openai_mock_delay_seconds summary",
        "# TYPE openai_mock_in_flight gauge",
        "# TYPE openai_mock_bucket_limit gauge",
        "# TYPE openai_mock_bucket_remaining gauge",
        f"openai_mock_in_flight {stats['in_flight']}",
    ]
    for kind, entry in sorted(stats["kinds"].items()):
        for result, count in sorted(entry["results"].items()):
            lines.append(f'openai_mock_requests_total{{kind="{kind}",result="{result}"}} {count}')
        lines.append(f'openai_mock_retries_total{{kind="{kind}"}} {entry["retries"]}')
        lines.append(f'openai_mock_tokens_charged_total{{kind="{kind}"}} {entry["tokens_charged"]}')
        lines.append(f'openai_mock_usage_tokens_total{{kind="{kind}",direction="input"}} {entry["input_tokens"]}')
        lines.append(f'openai_mock_usage_tokens_total{{kind="{kind}",direction="output"}} {entry["output_tokens"]}')
        lines.append(f'openai_mock_delay_seconds_sum{{kind="{kind}"}} {entry["delay_sum"]:.3f}')
        lines.append(f'openai_mock_delay_seconds_count{{kind="{kind}"}} {entry["delay_count"]}')
    for model, kinds in sorted(buckets.items()):
        for bucket, state in sorted(kinds.items()):
            labels = f'model="{model}",bucket="{bucket}"'
            lines.append(f"openai_mock_bucket_limit{{{labels}}} {state['limit']}")
            lines.append(f"openai_mock_bucket_remaining{{{labels}}} {state['remaining']}")
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send(self, status, payload, headers=None, content_type="application/json"):
        data = (payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        text = raw.decode("utf-8", errors="replace")
        return (json.loads(text) if text else {}), len(text)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/health", "/healthz"):
            self.send(200, {"status": "ok"})
        elif path == "/metrics":
            self.send(200, metrics_text(), content_type="text/plain; version=0.0.4")
        elif path == "/_mock/config":
            self.send(200, current().as_dict())
        elif path == "/_mock/stats":
            self.send(200, {**STATS.snapshot(), "buckets": LIMITER.snapshot(), "config": current().as_dict()})
        else:
            self.send(404, error_body("not found", "invalid_request_error", None))

    def do_POST(self):
        try:
            body, chars = self.read_json()
        except ValueError:
            self.send(400, error_body("invalid json", "invalid_request_error", None))
            return
        path = self.path.split("?")[0].rstrip("/")
        if path == "/_mock/config":
            self.configure(body)
        elif path == "/_mock/reset":
            LIMITER.reset()
            STATS.reset()
            self.send(200, {"status": "reset"})
        elif path.endswith("/responses/input_tokens"):
            self.respond(body, chars, "count")
        elif path.endswith("/responses"):
            self.respond(body, chars, None)
        else:
            self.send(404, error_body(f"unsupported path {path}", "invalid_request_error", None))

    def configure(self, body):
        global CONFIG
        if not isinstance(body, dict):
            self.send(400, {"error": "expected a JSON object"})
            return
        with CONFIG_LOCK:
            updated = CONFIG.copy()
            try:
                updated.update(body)
            except (ValueError, TypeError) as error:
                self.send(400, {"error": str(error)})
                return
            CONFIG = updated
        if {"tpm", "rpm"} & set(body):
            LIMITER.reset()
        self.send(200, updated.as_dict())

    def respond(self, body, chars, kind):
        config = current()
        model = body.get("model") or "mock"
        kind = kind or classify(body, config)
        input_tokens = estimate(chars, config)
        retry = (self.headers.get("x-stainless-retry-count") or "0") not in ("", "0")
        STATS.request(kind, retry)

        fault = draw_fault(config)
        if fault and fault != "timeout":
            LIMITER.count(model, config.rpm)
            STATS.result(kind, f"fault_{fault}")
            status, payload, headers = fault_response(fault, model)
            headers.update(ratelimit_headers(LIMITER.peek(model, config.rpm, config.tpm)))
            self.send(status, payload, headers)
            return

        if kind == "count" and not config.count_limited:
            tokens = 0
            quotas = LIMITER.peek(model, config.rpm, config.tpm)
        else:
            if kind == "count":
                tokens = input_tokens
            else:
                tokens = charge(config, input_tokens, int(body.get("max_output_tokens") or 0))
            admission = LIMITER.admit(model, config.rpm, config.tpm, tokens)
            if not admission.allowed:
                STATS.result(kind, "rate_limited")
                self.send(*limit_response(admission, model, tokens))
                return
            quotas = admission.quotas
        STATS.charged(kind, tokens)

        if kind == "count":
            payload = {"object": "response.input_tokens", "input_tokens": input_tokens}
            output_tokens = 0
        else:
            payload = response_of(body, output_of(kind, body, config), input_tokens, config)
            output_tokens = payload["usage"]["output_tokens"]
        wait = config.timeout_seconds if fault == "timeout" else delay(config, kind, input_tokens)
        STATS.begin()
        try:
            time.sleep(wait)
        finally:
            STATS.end(kind, wait, input_tokens, output_tokens)
        STATS.result(kind, "fault_timeout" if fault == "timeout" else "ok")
        self.send(200, payload, ratelimit_headers(quotas))

    def log_message(self, fmt, *args):
        if os.environ.get("MOCK_ACCESS_LOG") == "1":
            super().log_message(fmt, *args)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 512


if __name__ == "__main__":
    Server(("0.0.0.0", int(os.environ.get("PORT", "8000"))), Handler).serve_forever()
