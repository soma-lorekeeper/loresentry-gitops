import json
import os
import random
import re
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SHORT_ID = re.compile(r"\b[0-9a-f]{8}\b")


def delay_range(name, default):
    low, _, high = os.environ.get(name, default).partition("-")
    return int(low), int(high or low)


DELAYS = {
    "tool": delay_range("MOCK_TOOL_DELAY_MS", "1500-4000"),
    "text": delay_range("MOCK_TEXT_DELAY_MS", "3000-8000"),
    "judge": delay_range("MOCK_JUDGE_DELAY_MS", "800-2000"),
    "count": delay_range("MOCK_COUNT_DELAY_MS", "30-120"),
}
ANSWER_CHARS = int(os.environ.get("MOCK_ANSWER_CHARS", "1200"))
MAX_RANKING = int(os.environ.get("MOCK_MAX_RANKING", "3"))
ANSWER = (
    "이 답은 dev 클러스터의 OpenAI mock 이 만든 부하 테스트용 문장입니다. "
    "This answer was produced by the dev cluster's OpenAI mock for load testing. "
)


def pause(kind):
    low, high = DELAYS[kind]
    time.sleep(random.uniform(low, high) / 1000)


def tokens(value):
    return max(1, len(json.dumps(value, ensure_ascii=False)) // 4)


def texts(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from texts(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from texts(item)


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


def judged(name, schema):
    if name == "sufficiency":
        return {"sufficient": True, "missing": []}
    if name == "answer_check":
        return {"answer_ok": True, "problems": []}
    return sample(schema, schema)


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


def respond(body):
    items = body.get("input")
    fmt = (body.get("text") or {}).get("format") or {}
    has_tools = bool(body.get("tools"))
    answered = isinstance(items, list) and any(
        isinstance(i, dict) and i.get("type") == "function_call_output" for i in items
    )
    if fmt.get("type") == "json_schema":
        pause("judge")
        output = [message(json.dumps(judged(fmt.get("name"), fmt.get("schema") or {}), ensure_ascii=False))]
    elif has_tools and body.get("tool_choice") == "auto" and not answered:
        ids = []
        for text in texts(items):
            for found in SHORT_ID.findall(text):
                if found not in ids:
                    ids.append(found)
        pause("tool")
        if ids:
            output = [function_call(random.sample(ids, min(MAX_RANKING, len(ids))))]
        else:
            output = [message((ANSWER * (ANSWER_CHARS // len(ANSWER) + 1))[:ANSWER_CHARS])]
    else:
        pause("text")
        output = [message((ANSWER * (ANSWER_CHARS // len(ANSWER) + 1))[:ANSWER_CHARS])]
    input_tokens = tokens(body.get("instructions", "")) + tokens(items)
    output_tokens = tokens(output)
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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/health", "/healthz"):
            self.send(200, {"status": "ok"})
        else:
            self.send(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self.send(400, {"error": {"message": "invalid json", "type": "invalid_request_error"}})
            return
        path = self.path.split("?")[0].rstrip("/")
        if path.endswith("/responses/input_tokens"):
            pause("count")
            count = tokens(body.get("instructions", "")) + tokens(body.get("input"))
            self.send(200, {"object": "response.input_tokens", "input_tokens": count})
        elif path.endswith("/responses"):
            self.send(200, respond(body))
        else:
            self.send(404, {"error": {"message": f"unsupported path {path}", "type": "invalid_request_error"}})

    def log_message(self, fmt, *args):
        if os.environ.get("MOCK_ACCESS_LOG") == "1":
            super().log_message(fmt, *args)


if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8000"))), Handler).serve_forever()
