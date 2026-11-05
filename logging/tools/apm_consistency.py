#!/usr/bin/env python3
"""로그·APM 정합성 점검.

docs 저장소 APM_ARCHITECTURE.md 11절의 점검(C1~C9, C11)을 dev ES에서 돌린다. C10(서비스 코드가 추적 API를 쓰지 않는지)은
서비스 저장소의 빌드(ArchUnit, ruff)가 맡아서 여기에는 없다.

무엇을 보나
- C1  로그 줄의 trace.id·span.id가 APM에 같은 서비스의 span으로 있고, 줄의 시각이 그 span 안에 있다.
- C2  외부 호출 결과 줄(`<target> call completed|failed`)이 `<target> call` span 안에서 찍혔고, 걸린 시간이 맞고, 계측 자식이 있다.
- C3  최근 trace마다 root가 하나이고 부모를 잃은 span이 없다. 흐름별(파일 저장, 최신화, 채팅, 로그인 등)로 기대한 서비스·span 종류가 있다.
- C4  Kafka 발행·소비 span이 relay 회차 trace에 붙지 않는다(저장된 trace를 잇는다). 헤더 없이 소비한 레코드 수도 센다.
- C5  빈 폴링 회차·성공한 헬스체크 trace, 시작점이 아닌 부모 없는 span이 저장되지 않는다.
- C6  서비스마다 쓰는 의존 대상에 span이 있고, 종류별 표준 속성이 99% 이상 있고, 같은 작업의 같은 종류 span이 겹치지 않는다.
- C7  외부 traceparent를 붙인 gateway 요청이 새 trace로 시작한다(--gateway-url을 줄 때만).
- C8  span resource에 service.name·service.version·service.instance.id·k8s.pod.name·deployment.environment.name이 있다.
- C9  traces·APM 오류 문서에 지워야 할 속성이 없고, 표본 반대 검색(이메일, JWT, code=·state=, S3 객체 키, SQL)이 0건이다.
- C11 앱 로그의 warn·error 줄에 error.stack_trace가 있고 error.message는 없다.

EDOT로 옮기는 동안에는 옮긴 서비스만 --service로 골라 돌린다. 옮기기 전 서비스는 C1·C2·C6·C11에서 실패하는 것이 정상이다.

접속
- kubectl port-forward로 ES(svc/logs-es-http)에 붙는다. elastic 비밀번호와 CA는 Secret에서 읽어 이 프로세스 메모리에만 둔다
  (화면·명령줄·파일에 남기지 않는다. CA는 공개 인증서라 임시 파일로 쓴 뒤 지운다).
- 조회만 한다. C7만 gateway에 요청 하나를 보낸다.

사용
  KUBECONFIG=... python3 logging/tools/apm_consistency.py --context lore-sentry-dev-admin [--since 30m] \
      [--service authentication-api ...] [--gateway-url https://api-dev.example.com] [--json out.json]
결과는 마크다운 표로 나오고, FAIL이 하나라도 있으면 종료 코드 1이다.
"""

import argparse
import base64
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter, defaultdict
from datetime import datetime, timezone
from decimal import Decimal

# ---------------------------------------------------------------------------
# 대상과 기준
# ---------------------------------------------------------------------------

SERVICES = ["gateway-api", "authentication-api", "content-api", "ai-chat-api", "ai-chat-summarizer", "graph-rag-api"]
TRACES = "traces-*.otel-*"
OTEL_LOGS = "logs-*.otel-*"  # span의 예외 event(APM 오류)
APP_LOGS = "logs-loresentry.*-dev"

# 서비스마다 쓰는 의존 대상(LOG_SCHEMA.md 7절 계측 범위). 이름은 아래 span_category()가 돌려주는 값이다.
# 창 안에 그 호출이 없었으면 없음으로 나온다. 트래픽을 만든 뒤 돌리거나 --since를 넓힌다.
EXPECTED_DEPENDENCIES = {
    "gateway-api": ["request", "http", "db:redis"],
    "authentication-api": ["request", "http", "db:redis", "db:postgresql", "messaging:publish", "schedule"],
    "content-api": ["request", "db:postgresql", "aws:S3", "aws:KMS", "messaging:publish", "messaging:process", "schedule"],
    "ai-chat-api": ["request", "http", "db:postgresql", "aws:KMS", "genai"],
    "ai-chat-summarizer": ["messaging:process", "db:postgresql", "aws:KMS", "genai", "schedule"],
    "graph-rag-api": ["request", "http", "aws:S3", "aws:KMS", "genai", "messaging:process", "messaging:publish", "schedule"],
}

# span 종류별 표준 속성. 안정 이름과 옛 이름이 다르면 둘 중 하나가 있으면 된다(튜플). `이름=값`은 그 속성이 그 값일 때만 있다고 본다.
# collector의 elasticapm processor는 messaging 속성(system·destination·operation)을 APM 필드로 옮기고 원래 이름을 남기지 않는다
# (2026-11-05 dev 확인). 그래서 messaging은 그 APM 필드도 같은 뜻으로 받는다.
# - span(부모가 같은 서비스, 예: 발행): span.subtype, span.message.queue.name·service.target.name, span.action
# - transaction(부모가 원격, 예: 다른 서비스가 보낸 레코드의 소비): system은 transaction.type=messaging, destination은
#   transaction.message.queue.name이다. operation은 따로 남지 않는다. 원격 부모를 잇는 messaging transaction이 곧 소비(process)라
#   transaction.type=messaging을 operation으로도 받는다
REQUIRED_ATTRIBUTES = {
    "request": ["http.request.method", "url.path", "http.response.status_code"],
    "http": ["http.request.method", "server.address", "url.full"],
    "db": [("db.system.name", "db.system"), "server.address"],
    "messaging": [("messaging.system", "span.subtype", "transaction.type=messaging"),
                  ("messaging.destination.name", "span.message.queue.name", "service.target.name",
                   "transaction.message.queue.name"),
                  ("messaging.operation.type", "messaging.operation", "span.action", "transaction.type=messaging")],
    "aws": ["rpc.system", "rpc.service", "rpc.method"],
    "genai": [("gen_ai.provider.name", "gen_ai.system"), "gen_ai.request.model"],
}

REQUIRED_RESOURCE = ["service.name", "service.version", "service.instance.id", "k8s.pod.name", "deployment.environment.name"]

# 시작점으로 허용하는 부모 없는 Internal span. 스케줄 회차(agent Spring Scheduling 계측)와 로깅 팩토리가 흐름 밖에서 연 span
# (Python 스케줄·폴링 회차, 시작할 때 도는 작업)이다. 로깅 팩토리의 tracer 이름은 Java `com.loresentry.<서비스>.logging`, Python `app.logs`다.
ALLOWED_INTERNAL_ROOT_SCOPES = re.compile(r"^(io\.opentelemetry\.spring-scheduling|com\.loresentry\.[a-z_]+\.logging|app\.logs)")

# 로깅 팩토리 tracer의 scope 이름(ES regexp, 전체 일치). 이 span의 상태 메시지는 우리 이유 코드(error.type)라 남고, 다른 계측 span의
# 상태 메시지(예외 문자열)는 collector가 지운다(C9).
LOGGING_FACTORY_SCOPES_ES = r"com\.loresentry\.[a-z_]+\.logging|app\.logs"

# 흐름 밖에서 도는 DB 쿼리의 스레드(LOG_SCHEMA.md 7절 시작점). 기동(Flyway, Hibernate 검증, main 스레드), 연결 풀이 연결을 만들 때
# (HikariPool-*), Redis 연결의 handshake(HELLO, CLIENT SETINFO)를 하는 Lettuce event loop(lettuce-*)다. 흐름이 아니라 부모가 없는
# 것이 맞아 C5에서 실패로 세지 않고 따로 센다. 흐름 안의 Redis 명령은 같은 event loop에서 돌아도 부르는 쪽의 span을 부모로 갖는다.
# 다른 스레드의 부모 없는 DB span은 실패다.
OUTSIDE_FLOW_DB_THREADS = re.compile(r"^(main|HikariPool-\d+[: ].*|lettuce-.*)$")

# relay 회차 span 이름. 발행·소비 span이 이 trace에 붙으면 저장된 trace를 잇지 못한 것이다(C4).
RELAY_ROUND_NAME = re.compile(r"(?i)outbox.?relay|^outbox-relay$|^refresh-relay$")

# 흐름별 기대(C3). root span 이름(`<METHOD> <route>`, Micrometer는 `http <method> <route>`)으로 고른다.
FLOWS = [
    {"name": "파일 저장 → Kafka → graph-rag·summarizer", "root": r"put /files/\{fileId\}/content",
     "services": ["gateway-api", "content-api"], "categories": ["request", "db:postgresql"]},
    {"name": "최신화 요청", "root": r"post /projects/\{projectId\}/graph-refresh",
     "services": ["gateway-api", "content-api"], "categories": ["request", "db:postgresql", "messaging:publish"]},
    {"name": "채팅 SSE", "root": r"post /chat/sessions/\{sessionId\}/messages",
     "services": ["gateway-api", "ai-chat-api"], "categories": ["request", "genai"]},
    {"name": "로그인 callback", "root": r"get /auth/oauth/google/callback",
     "services": ["gateway-api", "authentication-api"], "categories": ["request", "http", "db:redis"]},
    {"name": "로그아웃", "root": r"post /auth/sessions/revoke",
     "services": ["gateway-api", "authentication-api"], "categories": ["request", "db:redis"]},
    {"name": "탈퇴 → auth outbox → content", "root": r"post /auth/users/me/deletion",
     "services": ["gateway-api", "authentication-api"], "categories": ["request", "db:postgresql"]},
]

# 반대 검색 정규식(C9). 가린 뒤의 표시([redacted] 등)는 걸리지 않게 한다.
LEAK_PATTERNS = {
    "email": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"),
    "jwt": re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"),
    "oauth": re.compile(r"(^|[?&\"])(code|state)=(?!\[redacted\])[^&\s\"#]+"),
    "s3-key": re.compile(r"(projects/[0-9a-f-]{36}/images/|refresh/[0-9a-f-]{36}/[0-9a-f-]{36}/)"),
    "sql": re.compile(r"(?i)\b(select\b.+\bfrom|insert\s+into|update\b.+\bset|delete\s+from)\b"),
}
# 지워야 하는 속성(collector transform/privacy). 하나라도 있으면 C9 실패다.
FORBIDDEN_SPAN_ATTRIBUTES = ["db.statement", "db.query.text", "url.query", "aws.s3.key", "aws.s3.copy_source",
                             "gen_ai.prompt", "gen_ai.completion", "gen_ai.input.messages", "gen_ai.output.messages",
                             "gen_ai.system_instructions"]
FORBIDDEN_ERROR_ATTRIBUTES = ["exception.message", "exception.stacktrace"]

CALL_LINE = re.compile(r"^(?P<target>\S+) call (completed|failed)$")
HEALTH_PATH = re.compile(r"^/health(/.*)?$")


# ---------------------------------------------------------------------------
# ES 접속
# ---------------------------------------------------------------------------

class Elasticsearch:
    """kubectl port-forward로 ES에 붙어 조회만 하는 작은 클라이언트."""

    def __init__(self, context, namespace="monitoring"):
        self.kubectl = ["kubectl", "--context", context, "-n", namespace]
        password = self._secret("logs-es-elastic-user", "elastic")
        ca = self._secret("logs-es-http-certs-public", "ca\\.crt")
        # 인증 헤더는 메모리에만 둔다. 비밀번호는 곧바로 버린다.
        self._auth = "Basic " + base64.b64encode(f"elastic:{password}".encode()).decode()
        del password
        ca_file = tempfile.NamedTemporaryFile("w", suffix=".crt", delete=False)
        ca_file.write(ca)
        ca_file.close()
        # 인증서 이름은 logs-es-http.monitoring.svc라 localhost와 다르다. CA 검증은 하고 이름 확인만 끈다.
        self._ssl = ssl.create_default_context(cafile=ca_file.name)
        self._ssl.check_hostname = False
        os.unlink(ca_file.name)
        self.truncated = 0
        self.port = self._free_port()
        self._forward = subprocess.Popen(self.kubectl + ["port-forward", "svc/logs-es-http", f"{self.port}:9200"],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self._wait_ready()

    def _secret(self, name, key):
        out = subprocess.run(self.kubectl + ["get", "secret", name, "-o", f"jsonpath={{.data.{key}}}"],
                             capture_output=True, text=True, check=True).stdout
        return base64.b64decode(out).decode()

    @staticmethod
    def _free_port():
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def _wait_ready(self):
        for _ in range(50):
            try:
                self.request("GET", "/")
                return
            except (urllib.error.URLError, ConnectionError, OSError):
                time.sleep(0.2)
        raise RuntimeError("ES port-forward did not become ready")

    def close(self):
        self._forward.terminate()

    def request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"https://127.0.0.1:{self.port}{path}", data=data, method=method,
                                     headers={"Authorization": self._auth, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, context=self._ssl, timeout=120) as resp:
            return json.loads(resp.read())

    def search(self, index, query, size=0, source=None, sort=None, aggs=None):
        body = {"size": size, "query": query, "track_total_hits": True}
        if source is not None:
            body["_source"] = source
        if sort is not None:
            body["sort"] = sort
        if aggs is not None:
            body["aggs"] = aggs
        return self.request("POST", f"/{index}/_search?ignore_unavailable=true&allow_no_indices=true", body)

    def hits(self, index, query, size, source, sort=None):
        return [h["_source"] for h in self.search(index, query, size=size, source=source, sort=sort)["hits"]["hits"]]

    def count(self, index, query):
        return self.search(index, query)["hits"]["total"]["value"]

    def spans_by(self, field, values, source=None, extra=None, chunk=1000):
        """field(span_id·trace_id·parent_span_id)가 values 중 하나인 span을 모두 가져온다. chunk개씩 나눠 묻는다.

        한 번에 받을 수 있는 문서는 10,000개다. 그만큼 찼으면 잘렸을 수 있으므로 truncated에 센다(trace_id로 물을 때는 chunk를 작게 준다).
        """
        found = []
        values = sorted(set(v for v in values if v))
        for i in range(0, len(values), chunk):
            filters = [{"terms": {field: values[i:i + chunk]}}] + (extra or [])
            got = self.hits(TRACES, {"bool": {"filter": filters}}, 10000, source)
            if len(got) >= 10000:
                self.truncated += 1
            found += got
        return found


# ---------------------------------------------------------------------------
# 도움 함수
# ---------------------------------------------------------------------------

def time_range(since, settle):
    # 최근 settle(기본 1분) 안의 문서는 빼고 본다. collector가 trace를 5초 모으고, 앱이 span을 몇 초씩 묶어 보내고,
    # 로그는 Filebeat·Logstash를 거치므로 막 찍힌 줄의 span이 아직 없을 수 있다.
    return {"range": {"@timestamp": {"gte": f"now-{since}", "lte": f"now-{settle}"}}}


def ns_of(timestamp):
    """ES _source의 @timestamp를 epoch 나노초로 바꾼다. traces는 epoch 밀리초 문자열, 로그는 ISO 문자열이다."""
    if isinstance(timestamp, (int, float)) or re.fullmatch(r"\d+(\.\d+)?", str(timestamp)):
        return int(Decimal(str(timestamp)) * 1_000_000)
    text = str(timestamp).replace("Z", "+00:00")
    main, _, rest = text.partition(".")
    fraction, offset = (re.match(r"(\d*)(.*)", rest).groups() if rest else ("", "+00:00"))
    seconds = datetime.fromisoformat(main + (offset or "+00:00")).replace(tzinfo=timezone.utc).timestamp()
    return int(seconds) * 1_000_000_000 + int((fraction + "000000000")[:9])


def field(doc, path):
    """로그 문서에서 `a.b.c` 값을 꺼낸다. _source가 중첩 객체여도, 점이 든 키여도 찾는다."""
    if path in doc:
        return doc[path]
    head, _, rest = path.partition(".")
    if rest and isinstance(doc.get(head), dict):
        return field(doc[head], rest)
    return None


def attr(span, key):
    return (span.get("attributes") or {}).get(key)


def has_attr(span, key):
    """표준 속성이 있는지. key는 이름 하나 또는 같은 뜻의 이름 튜플이다. `이름=값`은 그 속성이 그 값일 때만 있다고 본다."""
    keys = key if isinstance(key, tuple) else (key,)
    for k in keys:
        name, _, expected = k.partition("=")
        value = attr(span, name)
        if value is not None and (not expected or str(value) == expected):
            return True
    return False


def service_of(doc):
    return ((doc.get("resource") or {}).get("attributes") or {}).get("service.name") or (doc.get("service") or {}).get("name")


def span_category(span):
    """span이 무슨 의존 대상을 부른 것인지 정한다. C3·C6의 이름(request, http, db:<system>, aws:<service>, messaging:<op>, genai, schedule)."""
    kind = span.get("kind")
    if attr(span, "gen_ai.system") or attr(span, "gen_ai.provider.name"):
        return "genai"
    if attr(span, "rpc.system") == "aws-api":
        # 서비스 이름의 대소문자는 SDK마다 다르다(Java AWS SDK는 Kms, Python botocore는 KMS). 대문자로 맞춘다
        return f"aws:{str(attr(span, 'rpc.service') or '?').upper()}"
    db = attr(span, "db.system.name") or attr(span, "db.system")
    if db:
        return f"db:{db}"
    if attr(span, "messaging.system") or kind in ("Producer", "Consumer"):
        return "messaging:publish" if kind == "Producer" else "messaging:process"
    if kind == "Server":
        return "request"
    if kind == "Client" and (has_attr(span, ("http.request.method", "http.method")) or has_attr(span, ("url.full", "http.url"))):
        return "http"
    if kind == "Internal" and not span.get("parent_span_id") and ALLOWED_INTERNAL_ROOT_SCOPES.match(((span.get("scope") or {}).get("name") or "")):
        return "schedule"
    return None


def root_name(span):
    # Micrometer는 `http put /files/{fileId}/content`, 안정 이름은 `PUT /files/{fileId}/content`다. 앞을 맞춰 비교한다.
    return re.sub(r"^http ", "", (span.get("name") or "").lower())


def successful_health_root(span):
    if span.get("parent_span_id"):
        return False
    path = attr(span, "url.path") or attr(span, "http.target") or attr(span, "uri") or ""
    status = attr(span, "http.response.status_code") or attr(span, "http.status_code") or attr(span, "status")
    try:
        return bool(HEALTH_PATH.match(str(path))) and int(status) < 400
    except (TypeError, ValueError):
        return False


def pct(part, whole):
    return 100.0 if whole == 0 else round(100.0 * part / whole, 2)


class Result:
    def __init__(self, check, title):
        self.check, self.title, self.status, self.lines, self.data = check, title, "PASS", [], {}

    def fail(self, line):
        self.status = "FAIL"
        self.lines.append(line)

    def note(self, line):
        self.lines.append(line)

    def skip(self, line):
        if self.status == "PASS":
            self.status = "SKIP"
        self.lines.append(line)


# ---------------------------------------------------------------------------
# 점검
# ---------------------------------------------------------------------------

def app_log_query(window, services, *extra):
    return {"bool": {"filter": [window, {"terms": {"service.name": services}}, *extra],
                     "must_not": [{"term": {"tags": "health"}}]}}


def check_c1(es, window, services, sample):
    r = Result("C1", "로그 줄의 trace.id·span.id가 같은 서비스의 span이고, 줄 시각이 그 span 안이다")
    for svc in services:
        lines = es.hits(APP_LOGS, app_log_query(window, [svc], {"exists": {"field": "span.id"}}), sample,
                        ["@timestamp", "trace.id", "span.id", "message", "service.name"], sort=[{"@timestamp": "desc"}])
        if not lines:
            r.skip(f"{svc}: 창 안에 trace가 있는 로그 줄이 없다")
            continue
        spans = {s["span_id"]: s for s in es.spans_by("span_id", [field(l, "span.id") for l in lines],
                                                        ["span_id", "trace_id", "@timestamp", "duration", "resource.attributes.service.name"])}
        missing, other_service, outside = [], 0, []
        for line in lines:
            span = spans.get(field(line, "span.id"))
            if span is None or span["trace_id"] != field(line, "trace.id"):
                missing.append(line)
                continue
            if service_of(span) != svc:
                other_service += 1
            start = ns_of(span["@timestamp"])
            at = ns_of(line["@timestamp"])
            if not (start - 2_000_000 <= at <= start + int(span.get("duration") or 0) + 2_000_000):
                outside.append(line)
        ok = len(lines) - len(missing) - other_service
        text = f"{svc}: {len(lines)}줄 중 span 있음 {pct(ok, len(lines))}%, 줄 시각이 span 안 {pct(len(lines) - len(missing) - len(outside), len(lines))}%"
        if missing or other_service or outside:
            examples = Counter(l["message"] for l in missing + outside).most_common(3)
            r.fail(text + f" (span 없음 {len(missing)}, 다른 서비스 {other_service}, 시각 밖 {len(outside)}; 예: {examples})")
        else:
            r.note(text)
    return r


def check_c2(es, window, services, sample):
    r = Result("C2", "외부 호출 결과 줄이 `<target> call` span 안이고, 시간이 맞고, 계측 자식이 있다")
    for svc in services:
        # message는 text 필드라 regexp가 낱말 하나씩만 본다. 구절로 고른 뒤 정확한 모양은 여기서 다시 맞춘다.
        phrases = {"bool": {"should": [{"match_phrase": {"message": "call completed"}}, {"match_phrase": {"message": "call failed"}}],
                            "minimum_should_match": 1}}
        lines = es.hits(APP_LOGS, app_log_query(window, [svc], phrases, {"exists": {"field": "span.id"}}),
                        sample, ["@timestamp", "span.id", "message", "event.duration"], sort=[{"@timestamp": "desc"}])
        lines = [l for l in lines if CALL_LINE.match(l.get("message") or "")]
        if not lines:
            r.skip(f"{svc}: 창 안에 외부 호출 결과 줄이 없다")
            continue
        ids = [field(l, "span.id") for l in lines]
        spans = {s["span_id"]: s for s in es.spans_by("span_id", ids, ["span_id", "name", "kind", "duration"])}
        children = defaultdict(list)
        for c in es.spans_by("parent_span_id", ids, ["parent_span_id", "kind", "name"]):
            children[c["parent_span_id"]].append(c)
        bad = Counter()
        for line in lines:
            target = CALL_LINE.match(line["message"]).group("target")
            span = spans.get(field(line, "span.id"))
            if span is None:
                bad["span 없음"] += 1
                continue
            if target == "kafka":
                # Python Kafka 발행은 우리 span이 곧 PRODUCER span이다(`<topic> publish`). 계측 자식은 없다.
                if span.get("kind") != "Producer":
                    bad[f"kafka 줄의 span이 Producer가 아님({span.get('name')})"] += 1
                continue
            if span.get("name") != f"{target} call":
                bad[f"span 이름이 `{target} call`이 아님({span.get('name')})"] += 1
            duration = field(line, "event.duration")
            if duration is not None and abs(int(span.get("duration") or 0) - int(duration)) > 5_000_000:
                bad["걸린 시간 차이 5ms 초과"] += 1
            if not any(c.get("kind") in ("Client", "Producer") for c in children[span["span_id"]]):
                if span.get("kind") != "Client":
                    bad[f"{target}: 계측 CLIENT 자식 없음"] += 1
        text = f"{svc}: 결과 줄 {len(lines)}개"
        if bad:
            r.fail(text + " — " + ", ".join(f"{k} {v}" for k, v in bad.most_common()))
        else:
            r.note(text + " 모두 맞음")
    return r


def fetch_traces(es, window, services, per_service):
    """서비스마다 최근 root span을 per_service개 골라 그 trace의 모든 span을 가져온다(헬스체크 제외)."""
    roots = []
    for svc in services:
        roots += es.hits(TRACES, {"bool": {"filter": [window, {"term": {"resource.attributes.service.name": svc}}],
                                           "must_not": [{"exists": {"field": "parent_span_id"}}]}},
                         per_service, ["trace_id", "name"], sort=[{"@timestamp": "desc"}])
    trace_ids = [r["trace_id"] for r in roots]
    source = ["trace_id", "span_id", "parent_span_id", "name", "kind", "scope.name", "attributes", "resource.attributes.service.name", "@timestamp"]
    traces = defaultdict(list)
    # trace 하나에 span이 수백 개일 수 있어 50개 trace씩 묻는다(한 번에 받는 상한 10,000개를 넘으면 부모 잃은 span으로 잘못 보인다).
    for s in es.spans_by("trace_id", trace_ids, source, chunk=50):
        traces[s["trace_id"]].append(s)
    return traces


def check_c3(es, window, services, per_service):
    r = Result("C3", "trace마다 root가 하나이고 부모를 잃은 span이 없다. 흐름별로 기대한 서비스·span 종류가 있다")
    traces = fetch_traces(es, window, services, per_service)
    if not traces:
        r.skip("창 안에 root span이 없다")
        return r, traces
    multi_root, orphan_traces, orphans = 0, 0, Counter()
    for spans in traces.values():
        ids = {s["span_id"] for s in spans}
        if sum(1 for s in spans if not s.get("parent_span_id")) > 1:
            multi_root += 1
        lost = [s for s in spans if s.get("parent_span_id") and s["parent_span_id"] not in ids]
        if lost:
            orphan_traces += 1
            orphans.update(f"{service_of(s)}:{s.get('name')}" for s in lost)
    text = f"trace {len(traces)}개: root 여럿 {multi_root}, 부모 잃은 span이 있는 trace {orphan_traces}"
    if multi_root or orphan_traces:
        r.fail(text + f" (예: {orphans.most_common(5)})")
    else:
        r.note(text)
    for flow in FLOWS:
        pattern = re.compile(flow["root"])
        matched = [spans for spans in traces.values()
                   if any(not s.get("parent_span_id") and pattern.fullmatch(root_name(s)) for s in spans)]
        if not matched:
            r.note(f"{flow['name']}: 창 안에 표본 없음")
            continue
        incomplete = Counter()
        for spans in matched:
            have_services = {service_of(s) for s in spans}
            have_categories = {span_category(s) for s in spans}
            for want in flow["services"]:
                if want not in have_services:
                    incomplete[f"서비스 {want} 없음"] += 1
            for want in flow["categories"]:
                if want not in have_categories:
                    incomplete[f"span 종류 {want} 없음"] += 1
        text = f"{flow['name']}: 표본 {len(matched)}개"
        if incomplete:
            r.fail(text + " — " + ", ".join(f"{k} {v}" for k, v in incomplete.most_common()))
        else:
            r.note(text + " 모두 기대대로")
    return r, traces


def check_c4(es, window, services, sample):
    r = Result("C4", "Kafka 발행·소비 span이 relay 회차 trace에 붙지 않고 저장된 trace를 잇는다")
    messaging = es.hits(TRACES, {"bool": {"filter": [window, {"terms": {"kind": ["Producer", "Consumer"]}},
                                                     {"terms": {"resource.attributes.service.name": services}}]}},
                        sample, ["trace_id", "span_id", "parent_span_id", "kind", "name", "resource.attributes.service.name"],
                        sort=[{"@timestamp": "desc"}])
    if not messaging:
        r.skip("창 안에 Kafka 발행·소비 span이 없다")
        return r
    roots = {}
    for s in es.spans_by("trace_id", [m["trace_id"] for m in messaging], ["trace_id", "name", "kind"],
                         extra=[{"bool": {"must_not": [{"exists": {"field": "parent_span_id"}}]}}]):
        roots[s["trace_id"]] = s
    in_relay = Counter()
    headerless = Counter()
    for m in messaging:
        root = roots.get(m["trace_id"])
        if root and RELAY_ROUND_NAME.search(root.get("name") or ""):
            in_relay[f"{service_of(m)}:{m['kind']}:{m['name']}"] += 1
        if m["kind"] == "Consumer" and not m.get("parent_span_id"):
            headerless[f"{service_of(m)}:{m['name']}"] += 1
    text = f"발행·소비 span {len(messaging)}개 중 relay 회차 trace에 붙은 것 {sum(in_relay.values())}"
    if in_relay:
        r.fail(text + f" (예: {in_relay.most_common(5)})")
    else:
        r.note(text)
    if headerless:
        # 헤더가 없거나 틀린 레코드는 새 trace로 처리하는 것이 규칙이라 실패는 아니다. 옛 행·옛 발행자 말고는 0이어야 한다.
        r.note(f"헤더 없이 시작한 소비 span {sum(headerless.values())} (예: {headerless.most_common(3)})")
    return r


def check_c5(es, window, services, sample):
    r = Result("C5", "빈 폴링·성공한 헬스체크 trace, 시작점이 아닌 부모 없는 span이 없다")
    svc_filter = {"terms": {"resource.attributes.service.name": services}}
    idle = es.count(TRACES, {"bool": {"filter": [window, svc_filter, {"term": {"attributes.loresentry.polling.idle": True}}]}})
    roots = es.hits(TRACES, {"bool": {"filter": [window, svc_filter], "must_not": [{"exists": {"field": "parent_span_id"}}]}},
                    sample, ["name", "kind", "scope.name", "attributes", "resource.attributes.service.name"], sort=[{"@timestamp": "desc"}])
    health = sum(1 for s in roots if successful_health_root(s))
    disallowed = Counter()
    outside_flow = Counter()
    for s in roots:
        kind = s.get("kind")
        if kind in ("Server", "Consumer"):
            continue
        if kind == "Client" and (span_category(s) or "").startswith("db:") and OUTSIDE_FLOW_DB_THREADS.match(str(attr(s, "thread.name") or "")):
            outside_flow[f"{service_of(s)}:{attr(s, 'thread.name')}"] += 1
            continue
        if kind == "Internal" and ALLOWED_INTERNAL_ROOT_SCOPES.match(((s.get("scope") or {}).get("name") or "")):
            continue
        disallowed[f"{service_of(s)}:{kind}:{s.get('name')}"] += 1
    # 부모를 잃은 span: 부모 ID가 있는데 그 부모가 저장되지 않은 span. C3은 root가 창 안에 있는 trace만 보므로 여기서 따로 센다.
    # 부모는 기간과 상관없이 찾는다(저장된 traceparent의 부모는 몇 시간 전 요청일 수 있다). 보존 기간(30일)이나 span 전송을
    # 켜기 전의 부모를 가리키는 옛 레코드도 여기에 걸린다.
    children = es.hits(TRACES, {"bool": {"filter": [window, svc_filter, {"exists": {"field": "parent_span_id"}}]}},
                       sample, ["parent_span_id", "name", "kind", "resource.attributes.service.name"], sort=[{"@timestamp": "desc"}])
    stored = {s["span_id"] for s in es.spans_by("span_id", [c["parent_span_id"] for c in children], ["span_id"])}
    lost = Counter(f"{service_of(c)}:{c.get('kind')}:{c.get('name')}" for c in children if c["parent_span_id"] not in stored)
    text = (f"빈 폴링 span {idle}, 성공한 헬스체크 root {health}, 허용 밖 root {sum(disallowed.values())} (root 표본 {len(roots)}), "
            f"부모 잃은 span {sum(lost.values())} (자식 표본 {len(children)})")
    if idle or health or disallowed or lost:
        r.fail(text + (f" (허용 밖 root 예: {disallowed.most_common(6)})" if disallowed else "")
               + (f" (부모 잃은 span 예: {lost.most_common(6)})" if lost else ""))
    else:
        r.note(text)
    if outside_flow:
        r.note(f"흐름 밖 DB 쿼리 root(기동·연결 풀) {sum(outside_flow.values())} (예: {outside_flow.most_common(4)})")
    return r


def check_c6(es, window, services, sample):
    r = Result("C6", "의존 대상마다 span이 있고, 표준 속성이 99% 이상이고, 겹친 span이 없다")
    for svc in services:
        spans = es.hits(TRACES, {"bool": {"filter": [window, {"term": {"resource.attributes.service.name": svc}}]}},
                        sample, ["span_id", "parent_span_id", "kind", "name", "scope.name", "attributes"], sort=[{"@timestamp": "desc"}])
        if not spans:
            r.skip(f"{svc}: 창 안에 span이 없다")
            continue
        categories = Counter(span_category(s) for s in spans)
        missing = [d for d in EXPECTED_DEPENDENCIES.get(svc, []) if categories.get(d, 0) == 0]
        coverage = []
        for group, keys in REQUIRED_ATTRIBUTES.items():
            members = [s for s in spans if (span_category(s) or "").split(":")[0] == group]
            for key in keys:
                have = sum(1 for s in members if has_attr(s, key))
                if members and pct(have, len(members)) < 99:
                    coverage.append(f"{group}.{key if isinstance(key, str) else '|'.join(key)} {pct(have, len(members))}%")
        by_id = {s["span_id"]: s for s in spans}
        duplicates = Counter()
        for s in spans:
            parent = by_id.get(s.get("parent_span_id"))
            if parent and parent.get("kind") == s.get("kind") and s.get("kind") in ("Client", "Server", "Producer", "Consumer"):
                duplicates[f"{s['kind']}:{parent.get('name')} > {s.get('name')}"] += 1
        text = f"{svc}: span {len(spans)}개, 종류 {dict(categories.most_common())}"
        if missing or coverage or duplicates:
            r.fail(text + (f" — 없음 {missing}" if missing else "") + (f" — 속성 부족 {coverage}" if coverage else "")
                   + (f" — 겹침 {duplicates.most_common(4)}" if duplicates else ""))
        else:
            r.note(text)
    return r


def check_c7(es, gateway_url, path):
    r = Result("C7", "외부 traceparent를 붙인 gateway 요청이 새 trace로 시작한다")
    if not gateway_url:
        r.skip("--gateway-url이 없어 건너뜀")
        return r
    forged = uuid.uuid4().hex
    req = urllib.request.Request(gateway_url.rstrip("/") + path, method="GET",
                                 headers={"traceparent": f"00-{forged}-{uuid.uuid4().hex[:16]}-01",
                                          "User-Agent": "loresentry-apm-consistency"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            answered = resp.headers.get("X-Trace-Id")
    except urllib.error.HTTPError as e:
        answered = e.headers.get("X-Trace-Id")
    # collector가 trace를 5초 모으고 앱이 몇 초씩 묶어 보낸다. 넉넉히 기다린 뒤 위조한 trace ID로 span이 있는지 본다.
    time.sleep(30)
    stored = es.count(TRACES, {"term": {"trace_id": forged}})
    if answered == forged or stored:
        r.fail(f"위조 trace가 이어짐(응답 X-Trace-Id 같음: {answered == forged}, 저장된 span {stored})")
    else:
        r.note(f"새 trace로 시작함(응답 X-Trace-Id {'있음' if answered else '없음'}, 위조 trace span 0)")
    return r


def check_c8(es, window, services):
    r = Result("C8", "span resource에 서비스·버전·인스턴스·파드·환경이 있다")
    for svc in services:
        base = [window, {"term": {"resource.attributes.service.name": svc}}]
        total = es.count(TRACES, {"bool": {"filter": base}})
        if not total:
            r.skip(f"{svc}: 창 안에 span이 없다")
            continue
        short = []
        for key in REQUIRED_RESOURCE:
            have = es.count(TRACES, {"bool": {"filter": base + [{"exists": {"field": f"resource.attributes.{key}"}}]}})
            if have < total:
                short.append(f"{key} {pct(have, total)}%")
        if short:
            r.fail(f"{svc}: span {total}개 — {', '.join(short)}")
        else:
            r.note(f"{svc}: span {total}개 모두 있음")
    return r


def check_c9(es, window, services, sample):
    r = Result("C9", "지워야 할 속성 0건, 표본 반대 검색 0건")
    svc_filter = {"terms": {"resource.attributes.service.name": services}}
    found = {}
    for key in FORBIDDEN_SPAN_ATTRIBUTES:
        n = es.count(TRACES, {"bool": {"filter": [window, svc_filter, {"exists": {"field": f"attributes.{key}"}}]}})
        if n:
            found[key] = n
    aws_url = es.count(TRACES, {"bool": {"filter": [window, svc_filter, {"term": {"attributes.rpc.system": "aws-api"}},
                                                    {"exists": {"field": "attributes.url.full"}}]}})
    if aws_url:
        found["AWS span url.full"] = aws_url
    # 계측 라이브러리 span의 상태 메시지는 예외 문자열이라 collector가 지운다. 로깅 팩토리 span의 메시지(이유 코드)만 남는다
    status_message = es.count(TRACES, {"bool": {"filter": [window, svc_filter, {"exists": {"field": "status.message"}}],
                                                "must_not": [{"term": {"status.message": ""}},
                                                             {"regexp": {"scope.name": LOGGING_FACTORY_SCOPES_ES}}]}})
    if status_message:
        found["계측 span status.message"] = status_message
    for key in FORBIDDEN_ERROR_ATTRIBUTES:
        n = es.count(OTEL_LOGS, {"bool": {"filter": [window, svc_filter, {"exists": {"field": f"attributes.{key}"}}]}})
        if n:
            found[f"APM 오류 {key}"] = n
    leaks = Counter()
    docs = es.hits(TRACES, {"bool": {"filter": [window, svc_filter]}}, sample, ["attributes", "resource.attributes"],
                   sort=[{"@timestamp": "desc"}])
    docs += es.hits(OTEL_LOGS, {"bool": {"filter": [window, svc_filter]}}, min(sample, 2000), ["attributes", "body"],
                    sort=[{"@timestamp": "desc"}])
    for d in docs:
        for value in (v for v in (d.get("attributes") or {}).values() if isinstance(v, str)):
            for name, pattern in LEAK_PATTERNS.items():
                if pattern.search(value):
                    leaks[name] += 1
    text = f"표본 {len(docs)}개"
    if found or leaks:
        r.fail(text + (f" — 지워야 할 속성 {found}" if found else "") + (f" — 반대 검색 {dict(leaks)}" if leaks else ""))
    else:
        r.note(text + ", 지워야 할 속성·반대 검색 모두 0건")
    return r


def check_c11(es, window, services):
    r = Result("C11", "앱 로그 warn·error 줄에 error.stack_trace가 있고 error.message는 없다")
    levels = {"terms": {"log.level": ["warn", "error", "WARN", "ERROR"]}}
    for svc in services:
        base = app_log_query(window, [svc], levels)
        total = es.count(APP_LOGS, base)
        if not total:
            r.note(f"{svc}: 창 안에 warn·error 줄 없음")
            continue
        no_stack = es.search(APP_LOGS, {"bool": {**base["bool"], "must_not": base["bool"]["must_not"] + [{"exists": {"field": "error.stack_trace"}}]}},
                             aggs={"logger": {"terms": {"field": "log.logger", "size": 5}}})
        missing = no_stack["hits"]["total"]["value"]
        with_message = es.count(APP_LOGS, {"bool": {**base["bool"], "filter": base["bool"]["filter"] + [{"exists": {"field": "error.message"}}]}})
        text = f"{svc}: warn·error {total}줄, 스택 없음 {missing}, error.message 있음 {with_message}"
        if missing or with_message:
            loggers = [(b["key"], b["doc_count"]) for b in no_stack["aggregations"]["logger"]["buckets"]]
            r.fail(text + (f" (스택 없는 logger: {loggers})" if missing else ""))
        else:
            r.note(text)
    return r


# ---------------------------------------------------------------------------
# 실행
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--context", required=True, help="kubectl context (dev admin)")
    p.add_argument("--since", default="30m", help="볼 기간(ES date math, 기본 30m)")
    p.add_argument("--settle", default="1m", help="막 들어온 문서를 빼는 기간(기본 1m)")
    p.add_argument("--service", action="append", choices=SERVICES, help="점검할 서비스(여러 번). 없으면 전부")
    p.add_argument("--sample", type=int, default=2000, help="서비스마다 가져올 표본 수(최대 10000)")
    p.add_argument("--traces-per-service", type=int, default=200, help="C3에서 서비스마다 고를 root 수")
    p.add_argument("--gateway-url", help="C7용 gateway 주소. 없으면 C7을 건너뛴다")
    p.add_argument("--gateway-path", default="/auth/users/me", help="C7에서 부를 경로(인증 없이 401이어도 된다)")
    p.add_argument("--only", help="쉼표로 고른 점검만 돌린다(예: C1,C5)")
    p.add_argument("--json", help="결과를 JSON 파일로도 쓴다")
    args = p.parse_args()

    services = args.service or SERVICES
    window = time_range(args.since, args.settle)
    sample = min(args.sample, 10000)
    only = set(args.only.split(",")) if args.only else None
    es = Elasticsearch(args.context)
    results = []
    try:
        checks = [
            ("C1", lambda: check_c1(es, window, services, min(sample, 1000))),
            ("C2", lambda: check_c2(es, window, services, sample)),
            ("C3", lambda: check_c3(es, window, services, args.traces_per_service)[0]),
            ("C4", lambda: check_c4(es, window, services, sample)),
            ("C5", lambda: check_c5(es, window, services, sample)),
            ("C6", lambda: check_c6(es, window, services, sample)),
            ("C7", lambda: check_c7(es, args.gateway_url, args.gateway_path)),
            ("C8", lambda: check_c8(es, window, services)),
            ("C9", lambda: check_c9(es, window, services, sample)),
            ("C11", lambda: check_c11(es, window, services)),
        ]
        for name, run in checks:
            if only and name not in only:
                continue
            results.append(run())
        truncated = es.truncated
    finally:
        es.close()

    print(f"# 로그·APM 정합성 점검 (최근 {args.since}, 대상 {', '.join(services)})\n")
    if truncated:
        print(f"> 주의: span 조회 {truncated}번이 10,000개 상한에 닿아 잘렸을 수 있다. --since나 표본 수를 줄여 다시 돌린다.\n")
    print("| 점검 | 결과 | 내용 |")
    print("| --- | --- | --- |")
    for res in results:
        detail = "<br>".join(line.replace("|", "\\|") for line in res.lines) or "-"
        print(f"| {res.check} {res.title} | {res.status} | {detail} |")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump([{"check": x.check, "status": x.status, "lines": x.lines} for x in results], f, ensure_ascii=False, indent=1)
    return 1 if any(x.status == "FAIL" for x in results) else 0


if __name__ == "__main__":
    sys.exit(main())
