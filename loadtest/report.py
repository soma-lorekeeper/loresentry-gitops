#!/usr/bin/env python3
import argparse
import base64
import html
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

CONTEXT = "lore-sentry-dev"
NAMESPACE = "dev"
SERVICES = ("gateway", "content", "authentication")
API_HOST = "api-dev.loresentry.com"
RDS = "lore-sentry-dev-postgres"
ALB = "app/k8s-loresentrydev-816354655c/736d08342ca326bb"
TARGET_GROUP = "targetgroup/k8s-dev-gatewaya-5dc05d918a/e403427f58146ec9"
LOADGEN = "lore-sentry-dev-loadgen"
KIBANA = "https://kibana-dev.loresentry.com"
GRAFANA = "https://grafana-dev.loresentry.com"
GRAFANA_POD = "6581e46e4e5c7ba40a07646395ef7b23"
GRAFANA_NODE = "200ac8fdbfbb74b39aff88118e4d1c2c"
APP_LOGS_VIEW = "loresentry-app-logs-dev"
ES_PORT = 29200
PROM_PORT = 29090
STEP = 60
SAMPLE = 500
KST = timezone(timedelta(hours=9))
MIB = 1024 * 1024

STATUS = {
    "2xx": {"range": {"http.response.status_code": {"gte": 200, "lt": 300}}},
    "3xx·4xx": {"range": {"http.response.status_code": {"gte": 300, "lt": 500}}},
    "503": {"term": {"http.response.status_code": 503}},
    "500·기타 5xx": {"bool": {"filter": [{"range": {"http.response.status_code": {"gte": 500}}}],
                             "must_not": [{"term": {"http.response.status_code": 503}}]}},
}
OK = {"range": {"http.response.status_code": {"gte": 200, "lt": 400}}}
LEVELS = ["warn", "error", "WARN", "ERROR"]
REQUEST_LOG = [{"wildcard": {"log.logger": "*.RequestLogFilter"}}, {"exists": {"field": "http.response.status_code"}}]


def parse_time(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)


def iso(t):
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ms(t):
    return int(t.timestamp() * 1000)


def duration(text):
    units = {"s": 1, "m": 60, "h": 3600}
    return sum(int(n) * units[u] for n, u in re.findall(r"(\d+)([smh])", text))


def kubectl(*args):
    return subprocess.run(["kubectl", "--context", CONTEXT, *args], check=True, capture_output=True, text=True).stdout


class Forward:
    def __init__(self, target, local, remote):
        self.proc = subprocess.Popen(
            ["kubectl", "--context", CONTEXT, "-n", "monitoring", "port-forward", target, f"{local}:{remote}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if self.proc.poll() is not None:
                raise SystemExit(f"port-forward {target} exited")
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", local)) == 0:
                    return
            time.sleep(0.2)
        raise SystemExit(f"port-forward {target} did not open")

    def close(self):
        self.proc.terminate()


class Elastic:
    def __init__(self):
        secret = kubectl("-n", "monitoring", "get", "secret", "logs-es-elastic-user", "-o", "jsonpath={.data.elastic}")
        token = base64.b64encode(b"elastic:" + base64.b64decode(secret)).decode()
        self.headers = {"Authorization": f"Basic {token}", "Content-Type": "application/json"}
        self.tls = ssl._create_unverified_context()

    def search(self, index, body):
        req = urllib.request.Request(f"https://127.0.0.1:{ES_PORT}/{index}/_search", json.dumps(body).encode(),
                                     self.headers)
        with urllib.request.urlopen(req, context=self.tls, timeout=180) as res:
            return json.load(res)


class Prometheus:
    def get(self, path, params):
        url = f"http://127.0.0.1:{PROM_PORT}/api/v1/{path}?{urllib.parse.urlencode(params)}"
        with urllib.request.urlopen(url, timeout=120) as res:
            return json.load(res)["data"]["result"]

    def range(self, query, start, end):
        return self.get("query_range", {"query": query, "start": start.timestamp(), "end": end.timestamp(),
                                        "step": STEP})

    def at(self, query, t):
        return self.get("query", {"query": query, "time": t.timestamp()})


def aws(*args):
    env = {**os.environ, "AWS_PROFILE": os.environ.get("AWS_PROFILE", "lorekeeper"),
           "AWS_REGION": os.environ.get("AWS_REGION", "ap-northeast-2"), "AWS_PAGER": ""}
    out = subprocess.run(["aws", *args, "--output", "json"], check=True, capture_output=True, text=True, env=env)
    return json.loads(out.stdout)


class Report:
    def __init__(self, label, phases, k6):
        self.label = label
        self.phases = phases
        self.k6 = k6
        start = phases[0]["start"]
        end = phases[-1]["end"]
        self.t0 = start.replace(second=0, microsecond=0) - timedelta(minutes=2)
        self.t1 = end.replace(second=0, microsecond=0) + timedelta(minutes=4)
        self.minutes = [self.t0 + timedelta(seconds=i * STEP)
                        for i in range(int((self.t1 - self.t0).total_seconds()) // STEP)]
        self.charts = {}
        self.tables = {}
        self.summary = {}
        self.facts = {}
        self.zoom = None

    def window(self):
        return {"range": {"@timestamp": {"gte": iso(self.t0), "lt": iso(self.t1)}}}

    def test_window(self):
        return {"range": {"@timestamp": {"gte": iso(self.phases[0]["start"]), "lt": iso(self.phases[-1]["end"])}}}

    def per_minute(self, extra=None):
        agg = {"date_histogram": {"field": "@timestamp", "fixed_interval": "1m", "min_doc_count": 0,
                                  "extended_bounds": {"min": ms(self.minutes[0]), "max": ms(self.minutes[-1])}}}
        if extra:
            agg["aggs"] = extra
        return agg

    def per_phase(self, extra):
        filters = {}
        for name in dict.fromkeys(p["name"] for p in self.phases):
            ranges = [{"range": {"@timestamp": {"gte": iso(p["start"]), "lt": iso(p["end"])}}}
                      for p in self.phases if p["name"] == name]
            filters[name] = {"bool": {"should": ranges, "minimum_should_match": 1}}
        return {"filters": {"filters": filters}, "aggs": extra}

    def align(self, points):
        return [points.get(ms(t)) for t in self.minutes]

    def add(self, chart, name, values):
        self.charts.setdefault(chart, []).append({"name": name, "values": values})

    def phase_values(self, values, name):
        picked = []
        for t, v in zip(self.minutes, values):
            if v is None:
                continue
            for p in self.phases:
                if p["name"] == name and p["start"] <= t + timedelta(seconds=STEP / 2) < p["end"]:
                    picked.append(v)
        return picked


def pct(values, key):
    v = (values or {}).get(key)
    return None if v is None else round(v / 1e6, 1)


def collect_requests(r, es, service):
    index = f"logs-loresentry.{service}_api-dev"
    base = REQUEST_LOG
    timeline = es.search(index, {"size": 0, "query": {"bool": {"filter": [r.window(), *base]}}, "aggs": {
        "m": r.per_minute({
            "s": {"filters": {"filters": STATUS}},
            "all": {"percentiles": {"field": "event.duration", "percents": [95]}},
            "ok": {"filter": OK, "aggs": {"d": {"percentiles": {"field": "event.duration", "percents": [95]}}}},
        })}})["aggregations"]["m"]["buckets"]
    for key in STATUS:
        r.add(f"{service}_rps", key, r.align({b["key"]: round(b["s"]["buckets"][key]["doc_count"] / STEP, 2)
                                              for b in timeline}))
    r.add("p95_ok", f"{service} 성공 요청 p95", r.align({b["key"]: pct(b["ok"]["d"]["values"], "95.0")
                                                     for b in timeline}))
    r.add(f"{service}_p95", "전체 p95", r.align({b["key"]: pct(b["all"]["values"], "95.0") for b in timeline}))

    totals = es.search(index, {"size": 0, "query": {"bool": {"filter": [r.test_window(), *base]}}, "aggs": {
        "phase": r.per_phase({
            "s": {"filters": {"filters": STATUS}},
            "ok": {"filter": OK, "aggs": {"d": {"percentiles": {"field": "event.duration", "percents": [50, 95, 99]}}}},
        }),
        "status": {"terms": {"field": "http.response.status_code", "size": 20}, "aggs": {
            "e": {"terms": {"field": "error.type", "size": 5, "missing": "-"}},
            "d": {"percentiles": {"field": "event.duration", "percents": [5, 50, 95]}}}},
        "route": {"terms": {"field": "http.route", "size": 15}, "aggs": {
            "m": {"terms": {"field": "http.request.method", "size": 4}, "aggs": {
                "fail": {"filter": {"range": {"http.response.status_code": {"gte": 500}}}},
                "d": {"percentiles": {"field": "event.duration", "percents": [50, 95]}}}}}},
    }})["aggregations"]
    for name, b in totals["phase"]["buckets"].items():
        s = r.summary.setdefault(name, {})
        s[f"{service}.requests"] = b["doc_count"]
        for key in STATUS:
            s[f"{service}.{key}"] = b["s"]["buckets"][key]["doc_count"]
        s[f"{service}.ok_p95"] = pct(b["ok"]["d"]["values"], "95.0")
    r.tables[f"{service}_status"] = [
        {"status": b["key"], "count": b["doc_count"],
         "errors": [[e["key"], e["doc_count"]] for e in b["e"]["buckets"]],
         "p5": pct(b["d"]["values"], "5.0"), "p50": pct(b["d"]["values"], "50.0"),
         "p95": pct(b["d"]["values"], "95.0")}
        for b in totals["status"]["buckets"]]
    r.tables[f"{service}_routes"] = sorted(
        ({"route": b["key"], "method": m["key"], "count": m["doc_count"], "fail": m["fail"]["doc_count"],
          "p50": pct(m["d"]["values"], "50.0"), "p95": pct(m["d"]["values"], "95.0")}
         for b in totals["route"]["buckets"] for m in b["m"]["buckets"]),
        key=lambda x: -x["count"])


def collect_alb(r, es):
    base = [{"term": {"url.domain": API_HOST}}]
    elb = {"bool": {"filter": [{"range": {"http.response.status_code": {"gte": 500}}}],
                    "must_not": [{"exists": {"field": "aws.alb.target_status_code"}}]}}
    timeline = es.search("logs-aws.alb-dev", {"size": 0, "query": {"bool": {"filter": [r.window(), *base]}},
                                             "aggs": {"m": r.per_minute({
                                                 "s": {"filters": {"filters": {**STATUS, "ALB 자체 5xx": elb}}},
                                                 "d": {"percentiles": {"field": "event.duration",
                                                                       "percents": [95]}}})}})
    buckets = timeline["aggregations"]["m"]["buckets"]
    for key in [*STATUS, "ALB 자체 5xx"]:
        r.add("alb_rps", key, r.align({b["key"]: round(b["s"]["buckets"][key]["doc_count"] / STEP, 2)
                                       for b in buckets}))
    r.add("alb_p95", "액세스 로그 p95", r.align({b["key"]: pct(b["d"]["values"], "95.0") for b in buckets}))
    totals = es.search("logs-aws.alb-dev", {"size": 0, "query": {"bool": {"filter": [r.test_window(), *base]}},
                                           "aggs": {"phase": r.per_phase({
                                               "fail": {"filter": {"range": {"http.response.status_code": {"gte": 500}}}},
                                               "d": {"percentiles": {"field": "event.duration", "percents": [95]}}})}})
    for name, b in totals["aggregations"]["phase"]["buckets"].items():
        s = r.summary.setdefault(name, {})
        s["alb.requests"] = b["doc_count"]
        s["alb.5xx"] = b["fail"]["doc_count"]
        s["alb.p95"] = pct(b["d"]["values"], "95.0")


def collect_error_logs(r, es):
    query = {"bool": {"filter": [r.test_window(), {"terms": {"log.level": LEVELS}}],
                      "must_not": [{"wildcard": {"log.logger": "*RequestLogFilter"}}]}}
    res = es.search("logs-loresentry.*-dev", {"size": 0, "query": query, "aggs": {
        "svc": {"terms": {"field": "service.name", "size": 10}, "aggs": {
            "l": {"terms": {"field": "log.logger", "size": 10}, "aggs": {
                "e": {"terms": {"field": "error.type", "size": 6, "missing": "-"}, "aggs": {
                    "first": {"min": {"field": "@timestamp"}},
                    "sample": {"top_hits": {"size": 1, "_source": ["message"]}}}}}}}}}})["aggregations"]
    rows = []
    for s in res["svc"]["buckets"]:
        for lg in s["l"]["buckets"]:
            for e in lg["e"]["buckets"]:
                hit = e["sample"]["hits"]["hits"]
                rows.append({"service": s["key"], "logger": lg["key"], "type": e["key"], "count": e["doc_count"],
                             "first": e["first"]["value_as_string"],
                             "message": hit[0]["_source"].get("message", "") if hit else ""})
    r.tables["error_logs"] = sorted(rows, key=lambda x: -x["count"])
    window = es.search("logs-loresentry.*-dev", {"size": 0, "query": {"bool": {
        "filter": [r.window(), {"terms": {"log.level": LEVELS}}],
        "must_not": [{"wildcard": {"log.logger": "*RequestLogFilter"}}]}},
        "aggs": {"types": {"terms": {"field": "error.type", "size": 6}, "aggs": {"m": r.per_minute()}}}})
    for t in window["aggregations"]["types"]["buckets"]:
        r.add("error_types", t["key"].rsplit(".", 1)[-1], r.align({b["key"]: b["doc_count"]
                                                                   for b in t["m"]["buckets"]}))


def collect_log_volume(r, es):
    res = es.search("logs-loresentry.*-dev", {"size": 0, "query": {"bool": {"filter": [r.window()]}}, "aggs": {
        "svc": {"terms": {"field": "service.name", "size": 10}, "aggs": {"m": r.per_minute()}}}})
    for s in res["aggregations"]["svc"]["buckets"]:
        r.add("log_rate", s["key"], r.align({b["key"]: round(b["doc_count"] / STEP, 1) for b in s["m"]["buckets"]}))


def collect_join(r, es):
    gateway = "logs-loresentry.gateway_api-dev"
    content = "logs-loresentry.content_api-dev"
    cases = [
        ("gateway 503 CONTENT_UNAVAILABLE", [{"term": {"error.type": "CONTENT_UNAVAILABLE"}}]),
        ("gateway 500 INTERNAL_ERROR", [{"term": {"error.type": "INTERNAL_ERROR"}}]),
        ("gateway 200 저장 (대조군)", [{"term": {"http.response.status_code": 200}},
                                   {"term": {"http.route": "/files/{fileId}/content"}},
                                   {"term": {"http.request.method": "PUT"}}]),
    ]
    rows = []
    for name, extra in cases:
        hits = es.search(gateway, {"size": SAMPLE, "_source": ["trace.id"], "query": {"function_score": {
            "query": {"bool": {"filter": [r.test_window(), *REQUEST_LOG, *extra]}},
            "random_score": {"seed": 7, "field": "_seq_no"}}}})["hits"]
        ids = [h["_source"]["trace"]["id"] for h in hits["hits"] if h["_source"].get("trace")]
        if not ids:
            continue
        found = es.search(content, {"size": 0, "query": {"bool": {"filter": [
            {"terms": {"trace.id": ids}}, *REQUEST_LOG]}}, "aggs": {
            "t": {"cardinality": {"field": "trace.id"}},
            "s": {"terms": {"field": "http.response.status_code", "size": 5}}}})["aggregations"]
        rows.append({"case": name, "total": hits["total"]["value"], "sampled": len(ids),
                     "reached": found["t"]["value"],
                     "content_status": [[b["key"], b["doc_count"]] for b in found["s"]["buckets"]]})
    r.tables["join"] = rows


def collect_slow_queries(r, es):
    hits = es.search("logs-aws.rds-dev", {"size": 5000, "sort": [{"@timestamp": "asc"}],
                                         "_source": ["@timestamp", "message", "postgresql.log.database", "log.level"],
                                         "query": {"bool": {"filter": [r.window()]}}})["hits"]["hits"]
    per_minute, per_minute_max, slow, other = {}, {}, {}, {}
    for h in hits:
        s = h["_source"]
        t = parse_time(s["@timestamp"]).replace(second=0, microsecond=0)
        message = s.get("message", "")
        db = (s.get("postgresql") or {}).get("log", {}).get("database", "-")
        match = re.match(r"duration: ([\d.]+) ms\s+(?:execute|statement|bind|parse)[^:]*:\s*(.*)", message, re.S)
        if match:
            took = float(match.group(1))
            per_minute[ms(t)] = per_minute.get(ms(t), 0) + 1
            per_minute_max[ms(t)] = max(per_minute_max.get(ms(t), 0), took)
            if r.phases[0]["start"] <= parse_time(s["@timestamp"]) < r.phases[-1]["end"]:
                key = (db, " ".join(match.group(2).split())[:110])
                row = slow.setdefault(key, {"database": db, "statement": key[1], "count": 0, "total": 0, "max": 0})
                row["count"] += 1
                row["total"] += took
                row["max"] = max(row["max"], took)
        else:
            key = re.sub(r"\d+", "N", " ".join(message.split()))[:110]
            row = other.setdefault(key, {"message": key, "level": (s.get("log") or {}).get("level", "-"), "count": 0})
            row["count"] += 1
    r.add("rds_slow", "1초 넘은 쿼리 수", [per_minute.get(ms(t), 0) for t in r.minutes])
    r.add("rds_slow_max", "가장 느린 쿼리", [round(per_minute_max[ms(t)]) if ms(t) in per_minute_max else None
                                       for t in r.minutes])
    r.tables["slow_queries"] = sorted(
        ({**v, "avg": round(v["total"] / v["count"]), "max": round(v["max"])} for v in slow.values()),
        key=lambda x: -x["count"])[:12]
    r.tables["rds_other"] = sorted(other.values(), key=lambda x: -x["count"])[:10]
    for p in dict.fromkeys(p["name"] for p in r.phases):
        r.summary.setdefault(p, {})["rds.slow"] = sum(r.phase_values(r.charts["rds_slow"][0]["values"], p))


def collect_first_failure(r, es):
    hits = es.search("logs-loresentry.gateway_api-dev", {"size": 1, "sort": [{"@timestamp": "asc"}], "_source": [
        "@timestamp"], "query": {"bool": {"filter": [r.test_window(), *REQUEST_LOG, {
            "range": {"http.response.status_code": {"gte": 500}}}]}}})["hits"]["hits"]
    if not hits:
        return
    first = parse_time(hits[0]["_source"]["@timestamp"])
    lo = first.replace(second=first.second - first.second % 10, microsecond=0) - timedelta(seconds=90)
    labels = [lo + timedelta(seconds=10 * i) for i in range(18)]
    window = {"range": {"@timestamp": {"gte": iso(lo), "lt": iso(labels[-1] + timedelta(seconds=10))}}}
    charts = {}
    for service in ("gateway", "content"):
        buckets = es.search(f"logs-loresentry.{service}_api-dev", {"size": 0, "query": {"bool": {
            "filter": [window, *REQUEST_LOG]}}, "aggs": {"m": {"date_histogram": {
                "field": "@timestamp", "fixed_interval": "10s", "min_doc_count": 0,
                "extended_bounds": {"min": ms(labels[0]), "max": ms(labels[-1])}}, "aggs": {
                "ok": {"filter": OK, "aggs": {"d": {"percentiles": {"field": "event.duration", "percents": [95]}}}},
                "max": {"max": {"field": "event.duration"}},
                "fail": {"filter": {"range": {"http.response.status_code": {"gte": 500}}}}}}}})
        by = {b["key"]: b for b in buckets["aggregations"]["m"]["buckets"]}
        pick = lambda fn: [fn(by[ms(t)]) if ms(t) in by else None for t in labels]
        charts.setdefault("zoom_rps", []).append({"name": f"{service} 요청", "values": pick(
            lambda b: round(b["doc_count"] / 10, 1))})
        charts["zoom_rps"].append({"name": f"{service} 5xx", "values": pick(
            lambda b: round(b["fail"]["doc_count"] / 10, 1))})
        charts.setdefault("zoom_latency", []).append({"name": f"{service} 성공 p95", "values": pick(
            lambda b: pct(b["ok"]["d"]["values"], "95.0"))})
        charts["zoom_latency"].append({"name": f"{service} 최대", "values": pick(
            lambda b: None if b["max"]["value"] is None else round(b["max"]["value"] / 1e6))})
    r.zoom = {"first": iso(first), "labels": [iso(t) for t in labels], "charts": charts}


def collect_traces(r, es):
    res = es.search("traces-*", {"size": 0, "query": {"bool": {"filter": [r.test_window()]}}, "aggs": {
        "svc": {"terms": {"field": "service.name", "size": 10}}}})
    r.facts["traces"] = {b["key"]: b["doc_count"] for b in res["aggregations"]["svc"]["buckets"]}


def short_pod(pod):
    match = re.match(r"(.+?)-api-[a-z0-9]+-([a-z0-9]+)$", pod)
    return f"{match.group(1)} ·{match.group(2)}" if match else pod


def collect_prometheus(r, prom):
    start, end = r.minutes[0] + timedelta(seconds=STEP), r.minutes[-1] + timedelta(seconds=STEP)
    pods = f'namespace="{NAMESPACE}",container="api",pod=~"({"|".join(SERVICES)})-api-.+"'

    def series(query, chart, name_of, scale=1.0, digits=3):
        for s in sorted(prom.range(query, start, end), key=lambda s: name_of(s["metric"])):
            points = {}
            for ts, v in s["values"]:
                value = float(v)
                if value != value or value < 0:
                    continue
                points[int(float(ts)) * 1000 - STEP * 1000] = round(value * scale, digits)
            r.add(chart, name_of(s["metric"]), r.align(points))

    pod_name = lambda m: short_pod(m["pod"])
    series(f"sum by (pod) (rate(container_cpu_usage_seconds_total{{{pods}}}[1m]))", "pod_cpu", pod_name)
    series(f"sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{{{pods}}}[1m])) / "
           f"sum by (pod) (rate(container_cpu_cfs_periods_total{{{pods}}}[1m]))", "pod_throttle", pod_name, 100, 1)
    series(f"sum by (pod) (container_memory_working_set_bytes{{{pods}}})", "pod_memory", pod_name, 1 / MIB, 0)
    series(f'sum by (consumergroup) (kafka_consumergroup_lag{{namespace="{NAMESPACE}"}})', "kafka_lag",
           lambda m: m["consumergroup"], 1, 0)

    mid = r.phases[0]["start"] + (r.phases[-1]["end"] - r.phases[0]["start"]) / 2
    placement = prom.at(f'kube_pod_info{{namespace=~"{NAMESPACE}|monitoring",'
                        f'pod=~".+-api-.+|logs-es-.+|logstash-.+"}}', mid)
    roles = {}
    for p in placement:
        kind = "ES" if p["metric"]["pod"].startswith("logs-es") else "Logstash" if p["metric"]["pod"].startswith(
            "logstash") else p["metric"]["pod"].split("-api-")[0]
        roles.setdefault(p["metric"]["node"], []).append(kind)
    names = {u["metric"]["instance"]: u["metric"]["nodename"] for u in prom.at("node_uname_info", mid)}

    def node_name(m):
        node = names.get(m["instance"], m["instance"])
        kinds = roles.get(node)
        label = node.split(".")[0]
        if kinds:
            counts = {k: kinds.count(k) for k in dict.fromkeys(kinds)}
            label += " · " + ", ".join(k if n == 1 else f"{k}×{n}" for k, n in counts.items())
        return label

    series('100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])))', "node_cpu",
           node_name, 1, 1)

    limits = {(m["metric"]["pod"], m["metric"]["resource"]): float(m["value"][1]) for m in prom.at(
        f'kube_pod_container_resource_limits{{namespace="{NAMESPACE}",container="api"}}', mid)}
    images = prom.range(f'kube_pod_container_info{{namespace="{NAMESPACE}",container="api"}}', start, end)
    nodes = {p["metric"]["pod"]: p["metric"]["node"] for p in placement}
    restarts = {s["metric"]["pod"]: float(s["values"][-1][1]) - float(s["values"][0][1]) for s in prom.range(
        f'kube_pod_container_status_restarts_total{{namespace="{NAMESPACE}",container="api"}}', start, end)}
    rows = []
    for s in images:
        pod = s["metric"]["pod"]
        first = datetime.fromtimestamp(float(s["values"][0][0]), timezone.utc)
        last = datetime.fromtimestamp(float(s["values"][-1][0]), timezone.utc)
        rows.append({"pod": pod, "image": s["metric"]["image"].rsplit("/", 1)[-1], "node": nodes.get(pod, "-"),
                     "cpu": limits.get((pod, "cpu")), "memory": limits.get((pod, "memory")),
                     "restarts": int(restarts.get(pod, 0)),
                     "replaced": first > r.phases[0]["start"] or last < r.phases[-1]["end"] - timedelta(
                         seconds=STEP),
                     "first": iso(first), "last": iso(last)})
    r.tables["pods"] = sorted(rows, key=lambda x: x["pod"])
    r.tables["placement"] = [{"pod": p["metric"]["pod"], "node": p["metric"]["node"]} for p in placement
                             if p["metric"]["pod"].startswith(("logs-es", "logstash"))]


def collect_cloudwatch(r, loadgen):
    def stat(qid, namespace, metric, dims, statistic, period=STEP):
        return {"Id": qid, "MetricStat": {"Metric": {"Namespace": namespace, "MetricName": metric, "Dimensions": [
            {"Name": k, "Value": v} for k, v in dims.items()]}, "Period": period, "Stat": statistic}}

    rds = {"DBInstanceIdentifier": RDS}
    tg = {"LoadBalancer": ALB, "TargetGroup": TARGET_GROUP}
    queries = [
        stat("rds_cpu", "AWS/RDS", "CPUUtilization", rds, "Maximum"),
        stat("rds_conn", "AWS/RDS", "DatabaseConnections", rds, "Maximum"),
        stat("rds_free", "AWS/RDS", "FreeableMemory", rds, "Minimum"),
        stat("rds_swap", "AWS/RDS", "SwapUsage", rds, "Maximum"),
        stat("rds_read", "AWS/RDS", "ReadLatency", rds, "Maximum"),
        stat("rds_write", "AWS/RDS", "WriteLatency", rds, "Maximum"),
        stat("rds_credit", "AWS/RDS", "CPUCreditBalance", rds, "Minimum"),
        stat("rds_queue", "AWS/RDS", "DiskQueueDepth", rds, "Maximum"),
        stat("alb_count", "AWS/ApplicationELB", "RequestCount", tg, "Sum"),
        stat("alb_p95", "AWS/ApplicationELB", "TargetResponseTime", tg, "p95"),
    ]
    if loadgen:
        queries.append(stat("loadgen_cpu", "AWS/EC2", "CPUUtilization", {"InstanceId": loadgen}, "Maximum", 300))
    res = aws("cloudwatch", "get-metric-data", "--start-time", iso(r.minutes[0]), "--end-time", iso(r.t1),
              "--metric-data-queries", json.dumps(queries))
    data = {m["Id"]: {ms(parse_time(t)): v for t, v in zip(m["Timestamps"], m["Values"])}
            for m in res["MetricDataResults"]}

    def add(chart, name, qid, scale=1.0, digits=1):
        r.add(chart, name, r.align({k: round(v * scale, digits) for k, v in data.get(qid, {}).items()}))

    add("rds_cpu", "CPU %", "rds_cpu")
    add("rds_connections", "연결 수", "rds_conn", 1, 0)
    add("rds_memory", "여유 메모리", "rds_free", 1 / MIB, 0)
    add("rds_memory", "스왑 사용", "rds_swap", 1 / MIB, 0)
    add("rds_latency", "읽기 지연", "rds_read", 1000, 2)
    add("rds_latency", "쓰기 지연", "rds_write", 1000, 2)
    add("rds_credit", "CPU 크레딧", "rds_credit", 1, 1)
    add("rds_queue", "디스크 대기열", "rds_queue", 1, 2)
    add("alb_p95", "CloudWatch TargetResponseTime p95", "alb_p95", 1000, 0)
    if loadgen:
        add("loadgen_cpu", "CPU % (5분 최대)", "loadgen_cpu")
    r.facts["loadgen"] = loadgen


SUMMARY_ROWS = [
    ("요청", "ALB 초당 요청", "alb.rps", "{:.1f}"),
    ("요청", "ALB 5xx", "alb.5xx", "{:,}"),
    ("요청", "ALB 응답 p95 (ms)", "alb.p95", "{:,.0f}"),
    ("gateway", "응답 503 (연결 대기 초과)", "gateway.503", "{:,}"),
    ("gateway", "응답 500·기타 5xx", "gateway.500·기타 5xx", "{:,}"),
    ("gateway", "성공 요청 p95 (ms)", "gateway.ok_p95", "{:,.0f}"),
    ("content", "받은 요청", "content.requests", "{:,}"),
    ("content", "응답 500 (DB 커넥션 대기 초과 등)", "content.500·기타 5xx", "{:,}"),
    ("content", "성공 요청 p95 (ms)", "content.ok_p95", "{:,.0f}"),
    ("자원", "gateway CPU 최대 (core, limit 0.5)", "gateway.cpu_max", "{:.2f}"),
    ("자원", "content CPU 평균 / 최대 (core)", "content.cpu", "{}"),
    ("자원", "content CPU throttling 최대 (%)", "content.throttle_max", "{:.0f}"),
    ("자원", "파드 메모리 최대 (MiB, limit 512)", "pod.memory_max", "{:.0f}"),
    ("자원", "API 노드 CPU 최대 (%)", "node.api_max", "{:.0f}"),
    ("자원", "로깅 노드 CPU 최대 (%)", "node.logging_max", "{:.0f}"),
    ("DB", "RDS CPU 최대 (%)", "rds.cpu_max", "{:.0f}"),
    ("DB", "RDS 연결 수 최대", "rds.conn_max", "{:.0f}"),
    ("DB", "RDS 여유 메모리 최소 / 스왑 최대 (MiB)", "rds.memory", "{}"),
    ("DB", "1초 넘은 쿼리", "rds.slow", "{:,}"),
    ("비동기·로깅", "Kafka lag 최대", "kafka.lag_max", "{:,.0f}"),
    ("비동기·로깅", "앱 로그 초당 줄 수 (평균)", "logs.rate", "{:,.0f}"),
    ("부하 발생기", "CPU 최대 (%, 70 넘으면 무효)", "loadgen.cpu_max", "{:.0f}"),
]


def summarize(r):
    def values(chart, match=lambda name: True):
        return [s for s in r.charts.get(chart, []) if match(s["name"])]

    def phase_stat(chart, phase, fn, match=lambda name: True, combine=False):
        group = values(chart, match)
        if combine:
            totals = [sum(v for v in col if v is not None) if any(v is not None for v in col) else None
                      for col in zip(*(s["values"] for s in group))] if group else []
            picked = r.phase_values(totals, phase)
        else:
            picked = [v for s in group for v in r.phase_values(s["values"], phase)]
        return fn(picked) if picked else None

    avg = lambda xs: sum(xs) / len(xs)
    for phase in dict.fromkeys(p["name"] for p in r.phases):
        s = r.summary.setdefault(phase, {})
        seconds = sum((p["end"] - p["start"]).total_seconds() for p in r.phases if p["name"] == phase)
        if "alb.requests" in s:
            s["alb.rps"] = s["alb.requests"] / seconds
        s["gateway.cpu_max"] = phase_stat("pod_cpu", phase, max, lambda n: n.startswith("gateway"))
        cpu_avg = phase_stat("pod_cpu", phase, avg, lambda n: n.startswith("content"))
        cpu_max = phase_stat("pod_cpu", phase, max, lambda n: n.startswith("content"))
        s["content.cpu"] = None if cpu_avg is None else f"{cpu_avg:.2f} / {cpu_max:.2f}"
        s["content.throttle_max"] = phase_stat("pod_throttle", phase, max, lambda n: n.startswith("content"))
        s["pod.memory_max"] = phase_stat("pod_memory", phase, max)
        s["node.api_max"] = phase_stat("node_cpu", phase, max, lambda n: any(k in n for k in SERVICES))
        s["node.logging_max"] = phase_stat("node_cpu", phase, max, lambda n: "ES" in n)
        s["rds.cpu_max"] = phase_stat("rds_cpu", phase, max)
        s["rds.conn_max"] = phase_stat("rds_connections", phase, max)
        free = phase_stat("rds_memory", phase, min, lambda n: n == "여유 메모리")
        swap = phase_stat("rds_memory", phase, max, lambda n: n == "스왑 사용")
        s["rds.memory"] = None if free is None else f"{free:.0f} / {swap:.0f}"
        s["kafka.lag_max"] = phase_stat("kafka_lag", phase, max, combine=True)
        s["logs.rate"] = phase_stat("log_rate", phase, avg, combine=True)
        s["loadgen.cpu_max"] = phase_stat("loadgen_cpu", phase, max)


def links(r):
    g = f"(time:(from:'{iso(r.phases[0]['start'])}',to:'{iso(r.phases[-1]['end'])}'))"

    def discover(kql):
        a = f"(dataSource:(dataViewId:'{APP_LOGS_VIEW}',type:dataView),query:(language:kuery,query:'{kql}'))"
        return f"{KIBANA}/app/discover#/?_g={urllib.parse.quote(g)}&_a={urllib.parse.quote(a)}"

    frm, to = ms(r.t0), ms(r.t1)
    out = [
        ("Kibana · gateway 연결 대기 초과 로그", discover(
            'error.type:"org.apache.hc.core5.http.ConnectionRequestTimeoutException"')),
        ("Kibana · content DB 커넥션 대기 초과 로그", discover(
            'error.type:"org.springframework.transaction.CannotCreateTransactionException"')),
        ("Kibana · gateway 503 요청 로그", discover('service.name:"gateway-api" and http.response.status_code:503')),
    ]
    if r.facts.get("traces"):
        out.append(("Kibana APM · gateway-api", f"{KIBANA}/app/apm/services/gateway-api/overview?"
                    f"rangeFrom={iso(r.t0)}&rangeTo={iso(r.t1)}&environment=ENVIRONMENT_ALL"))
    for row in r.tables.get("pods", []):
        if row["pod"].startswith(tuple(f"{s}-api" for s in SERVICES)):
            out.append((f"Grafana · {row['pod']}", f"{GRAFANA}/d/{GRAFANA_POD}/?var-datasource=prometheus&"
                        f"var-namespace={NAMESPACE}&var-pod={row['pod']}&from={frm}&to={to}"))
    for node in sorted({row["node"] for row in r.tables.get("pods", []) + r.tables.get("placement", [])} - {"-"}):
        out.append((f"Grafana · 노드 {node.split('.')[0]}",
                    f"{GRAFANA}/d/{GRAFANA_NODE}/?var-datasource=prometheus&var-node={node}&from={frm}&to={to}"))
    return out


CHARTS = [
    ("외부 (ALB)", "alb_rps", "ALB 응답 상태별 초당 요청", "req/s",
     "api-dev로 들어온 요청 전체 (ALB 액세스 로그). ALB 자체 5xx는 대상까지 가지 못한 요청이다"),
    ("외부 (ALB)", "alb_p95", "ALB 응답 시간 p95", "ms", "액세스 로그 분 단위 p95와 CloudWatch 대상 응답 시간 p95"),
    ("API 서버", "gateway_rps", "gateway 응답 상태별 초당 요청", "req/s", "gateway 요청 완료 로그"),
    ("API 서버", "p95_ok", "성공 요청 p95 — gateway vs content", "ms",
     "같은 요청을 gateway와 content가 각각 잰 시간. 둘의 차이는 gateway 안에서 content 연결을 기다린 시간이다"),
    ("API 서버", "content_rps", "content 응답 상태별 초당 요청", "req/s", "content 요청 완료 로그"),
    ("API 서버", "authentication_rps", "authentication 응답 상태별 초당 요청", "req/s", ""),
    ("API 서버", "error_types", "경고·오류 로그 유형별 건수", "건/분", "요청 완료 로그를 뺀 warn·error 로그의 error.type"),
    ("파드·노드", "pod_cpu", "파드 CPU", "core", "limit 0.5 core"),
    ("파드·노드", "pod_throttle", "파드 CPU throttling", "%", "CFS 주기 중 limit에 걸려 멈춘 비율"),
    ("파드·노드", "pod_memory", "파드 메모리 (working set)", "MiB", "limit 512 MiB"),
    ("파드·노드", "node_cpu", "노드 CPU", "%", "노드 이름 뒤는 그 노드에 있던 파드"),
    ("DB (RDS)", "rds_cpu", "RDS CPU", "%", "1분 최대"),
    ("DB (RDS)", "rds_connections", "RDS 연결 수", "개", "1분 최대"),
    ("DB (RDS)", "rds_memory", "RDS 여유 메모리·스왑", "MiB", "db.t4g.micro 메모리 1 GiB"),
    ("DB (RDS)", "rds_latency", "RDS 디스크 지연", "ms", "1분 최대"),
    ("DB (RDS)", "rds_slow", "1초 넘은 쿼리", "건/분", "RDS 로그 (log_min_duration_statement 1000ms)"),
    ("DB (RDS)", "rds_slow_max", "분마다 가장 느린 쿼리", "ms", ""),
    ("DB (RDS)", "rds_credit", "RDS CPU 크레딧", "credit", ""),
    ("비동기·로깅", "kafka_lag", "Kafka consumer lag", "메시지", "consumer group별 합계"),
    ("비동기·로깅", "log_rate", "앱 로그 초당 줄 수", "줄/s", "서비스별"),
    ("부하 발생기", "loadgen_cpu", "부하 발생기 CPU", "%", "EC2 기본 모니터링이라 5분 단위. 70%를 넘으면 결과 무효"),
]

PAGE = """<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root { --bg:#fbfbfa; --fg:#1d1d1f; --muted:#6b6b70; --line:#e3e3e0; --card:#ffffff; --bad:#c2352b; --good:#2f7d4a; --accent:#2f5fb3; }
@media (prefers-color-scheme: dark) { :root { --bg:#16171a; --fg:#ececec; --muted:#a0a0a8; --line:#2c2d31; --card:#1d1e22; --bad:#ff6b5e; --good:#5cc27f; --accent:#7aa5ff; } }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.55 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Pretendard", "Noto Sans KR", sans-serif; }
main { max-width:1180px; margin:0 auto; padding:28px 16px 64px; }
h1 { font-size:24px; margin:0 0 4px; }
h2 { font-size:18px; margin:36px 0 10px; padding-top:10px; border-top:1px solid var(--line); }
h3 { font-size:14px; margin:0 0 2px; }
p.note, .note { color:var(--muted); font-size:12.5px; margin:2px 0 8px; }
.meta { color:var(--muted); margin-bottom:16px; }
.verdict { display:inline-block; padding:2px 10px; border-radius:999px; font-weight:600; font-size:13px; }
.verdict.fail { background:color-mix(in srgb, var(--bad) 15%, transparent); color:var(--bad); }
.verdict.pass { background:color-mix(in srgb, var(--good) 15%, transparent); color:var(--good); }
.grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(520px, 1fr)); gap:14px; }
@media (max-width:600px) { .grid { grid-template-columns:1fr; } }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; }
.chart { position:relative; height:240px; }
.scroll { overflow-x:auto; }
table { border-collapse:collapse; width:100%; font-size:13px; font-variant-numeric:tabular-nums; }
th, td { text-align:left; padding:5px 8px; border-bottom:1px solid var(--line); vertical-align:top; }
th { color:var(--muted); font-weight:600; white-space:nowrap; }
td.num, th.num { text-align:right; white-space:nowrap; }
td.bad { color:var(--bad); font-weight:600; }
code { font:12px ui-monospace, SFMono-Regular, Menlo, monospace; word-break:break-all; }
ul.links { columns:2; padding-left:18px; }
@media (max-width:600px) { ul.links { columns:1; } }
a { color:var(--accent); }
</style>
</head>
<body>
<main>
__BODY__
</main>
<script>
const REPORT = __DATA__;
const COLORS = ["#2f5fb3", "#d0702a", "#2f9a6a", "#c2352b", "#7d55c7", "#8a7a2a", "#1d97b0", "#b0477f", "#5b6770"];
const clock = (t, seconds) => new Date(t).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit", ...(seconds ? { second: "2-digit" } : {}), hour12: false, timeZone: "Asia/Seoul" });
const marks = (lines, origin, step) => ({
  id: "marks",
  afterDatasetsDraw(chart) {
    const { ctx, chartArea, scales } = chart;
    ctx.save();
    ctx.strokeStyle = ctx.fillStyle = getComputedStyle(document.body).color;
    ctx.setLineDash([3, 3]);
    ctx.font = "11px sans-serif";
    for (const [at, text] of lines) {
      const x = scales.x.getPixelForValue((new Date(at).getTime() - origin) / step);
      ctx.globalAlpha = 0.35; ctx.beginPath(); ctx.moveTo(x, chartArea.top); ctx.lineTo(x, chartArea.bottom); ctx.stroke();
      ctx.globalAlpha = 0.75; if (text) ctx.fillText(text, x + 3, chartArea.top + 10);
    }
    ctx.restore();
  },
});
const phaseLines = [...REPORT.phases.map((p) => [p.start, p.name]), [REPORT.phases[REPORT.phases.length - 1].end, ""]];
for (const el of document.querySelectorAll("canvas[data-chart]")) {
  const zoom = "zoom" in el.dataset;
  const source = zoom ? REPORT.zoom : REPORT;
  const times = zoom ? REPORT.zoom.labels : REPORT.minutes;
  const series = source.charts[el.dataset.chart] || [];
  new Chart(el, {
    type: "line",
    data: { labels: times.map((t) => clock(t, zoom)), datasets: series.map((s, i) => ({ label: s.name, data: s.values, borderColor: COLORS[i % COLORS.length], backgroundColor: COLORS[i % COLORS.length], borderWidth: 1.6, pointRadius: zoom ? 2 : 0, tension: 0.15, spanGaps: true })) },
    options: {
      animation: false, responsive: true, maintainAspectRatio: false,
      interaction: { mode: "index", intersect: false },
      plugins: { legend: { position: "bottom", labels: { boxWidth: 10, font: { size: 11 } } } },
      scales: { y: { beginAtZero: true, title: { display: true, text: el.dataset.unit } }, x: { ticks: { maxTicksLimit: 12 } } },
    },
    plugins: [zoom ? marks([[REPORT.zoom.first, "첫 5xx"]], new Date(times[0]).getTime(), 10000) : marks(phaseLines, new Date(times[0]).getTime(), 60000)],
  });
}
</script>
</body>
</html>
"""


def e(value):
    return html.escape("" if value is None else str(value))


def fmt(value, pattern="{:,}"):
    if value is None:
        return "—"
    try:
        return pattern.format(value)
    except (ValueError, TypeError):
        return str(value)


def table(head, rows, numeric=()):
    out = ["<div class='scroll'><table><tr>"]
    out += [f"<th class='{'num' if i in numeric else ''}'>{e(h)}</th>" for i, h in enumerate(head)]
    out.append("</tr>")
    for row in rows:
        out.append("<tr>" + "".join(cell if isinstance(cell, str) and cell.startswith("<td") else
                                     f"<td class='{'num' if i in numeric else ''}'>{e(cell)}</td>"
                                     for i, cell in enumerate(row)) + "</tr>")
    out.append("</table></div>")
    return "".join(out)


def kst(text):
    return parse_time(text).astimezone(KST).strftime("%H:%M:%S")


def render(data):
    phases = list(dict.fromkeys(p["name"] for p in data["phases"]))
    number = iter(range(1, 100))
    h2 = lambda title: f"<h2>{next(number)}. {e(title)}</h2>"
    card = lambda cid, title, unit, note, zoom=False: (
        f"<div class='card'><h3>{e(title)}</h3><p class='note'>{e(note)}</p><div class='chart'>"
        f"<canvas data-chart='{cid}' data-unit='{e(unit)}'{' data-zoom' if zoom else ''}></canvas></div></div>")
    start, end = parse_time(data["phases"][0]["start"]), parse_time(data["phases"][-1]["end"])
    body = [f"<h1>{e(data['label'])} 부하 테스트 지표 보고서</h1>"]
    k6 = data.get("k6") or {}
    verdict = ""
    if "passed" in k6:
        verdict = (f"<span class='verdict {'pass' if k6['passed'] else 'fail'}'>"
                   f"{'합격' if k6['passed'] else '불합격'}</span> ")
    body.append(f"<div class='meta'>{verdict}{e(k6.get('profile', ''))} · "
                f"{iso(start)} ~ {iso(end)} (KST {start.astimezone(KST):%m-%d %H:%M} ~ "
                f"{end.astimezone(KST):%H:%M}) · 그래프 시각은 KST · 생성 {e(data['generated_at'])}</div>")

    if k6.get("phases"):
        body.append(h2("클라이언트 결과 (k6)"))
        rows = []
        for name in phases:
            p = k6["phases"].get(name)
            if not p:
                continue
            rows.append([name, fmt(p["seconds"]), fmt(p["requests"]), fmt(p["rps"], "{:.1f}"),
                         f"{fmt(p['read_p95_ms'], '{:,.0f}')} / {fmt(p['read_p99_ms'], '{:,.0f}')}",
                         f"{fmt(p['save_p95_ms'], '{:,.0f}')} / {fmt(p['save_p99_ms'], '{:,.0f}')}",
                         fmt(p["error_rate"], "{:.1%}")])
        body.append(table(["구간", "초", "요청", "RPS", "읽기 p95/p99 ms", "저장 p95/p99 ms", "실패율"], rows,
                          numeric=(1, 2, 3, 4, 5, 6)))
        if data.get("k6_report"):
            body.append(f"<p class='note'>k6 리포트: <a href='{e(data['k6_report'])}'>{e(data['k6_report'])}</a></p>")

    body.append(h2("구간별 핵심 지표"))
    body.append("<p class='note'>요청 수와 p95는 로그에서 구간마다 정확히 계산했다. 자원 지표는 1분 값 중 구간 안의 값으로 계산했다.</p>")
    rows = []
    for group, label, key, pattern in SUMMARY_ROWS:
        rows.append([group, label] + [fmt(data["summary"].get(p, {}).get(key), pattern) for p in phases])
    body.append(table(["분류", "지표", *phases], rows, numeric=tuple(range(2, 2 + len(phases)))))

    if data["tables"].get("join"):
        body.append(h2("실패한 요청이 content까지 갔는가 (trace.id 연결)"))
        body.append("<p class='note'>gateway 요청 로그에서 무작위로 고른 요청의 trace.id로 content 요청 로그를 찾는다. "
                    "content 로그가 없으면 요청이 gateway를 떠나지 못한 것이다.</p>")
        rows = [[j["case"], fmt(j["total"]), fmt(j["sampled"]), fmt(j["reached"]),
                 fmt(j["reached"] / j["sampled"], "{:.1%}"),
                 ", ".join(f"{s} {n}" for s, n in j["content_status"]) or "—"] for j in data["tables"]["join"]]
        body.append(table(["gateway 요청", "전체", "표본", "content 로그 있음", "비율", "content 응답"], rows,
                          numeric=(1, 2, 3, 4)))

    zoom = data.get("zoom")
    if zoom:
        body.append(h2("첫 5xx 전후 (10초 단위)"))
        body.append(f"<p class='note'>gateway의 첫 5xx: {kst(zoom['first'])} KST. 무엇이 먼저 느려졌는지 본다.</p>"
                    "<div class='grid'>")
        body.append(card("zoom_rps", "초당 요청과 5xx", "req/s", "gateway·content 요청 완료 로그", True))
        body.append(card("zoom_latency", "성공 요청 p95와 최대 응답 시간", "ms",
                         "content가 먼저 느려졌는지, gateway에서만 느려졌는지", True))
        body.append("</div>")

    body.append(h2("응답 상태와 오류"))
    for service in SERVICES:
        rows = [[s["status"], fmt(s["count"]), ", ".join(f"{k} {n:,}" for k, n in s["errors"] if k != "-") or "—",
                 fmt(s["p5"], "{:,.0f}"), fmt(s["p50"], "{:,.0f}"), fmt(s["p95"], "{:,.0f}")]
                for s in data["tables"].get(f"{service}_status", [])]
        if rows:
            body.append(f"<div class='card' style='margin-bottom:12px'><h3>{service}</h3>")
            body.append(table(["상태", "건수", "error.type", "p5 ms", "p50 ms", "p95 ms"], rows, numeric=(1, 3, 4, 5)))
            body.append("</div>")
    rows = [[r["service"], r["logger"].rsplit(".", 1)[-1], r["type"], fmt(r["count"]), kst(r["first"]), r["message"]]
            for r in data["tables"].get("error_logs", [])]
    body.append("<div class='card'><h3>경고·오류 로그 (요청 완료 로그 제외)</h3>")
    body.append(table(["서비스", "logger", "error.type", "건수", "처음 (KST)", "message"], rows, numeric=(3,)))
    body.append("</div>")

    rows = [[r["method"], r["route"], fmt(r["count"]), f"<td class='num{' bad' if r['fail'] else ''}'>{r['fail']:,}</td>",
             fmt(r["p50"], "{:,.0f}"), fmt(r["p95"], "{:,.0f}")] for r in data["tables"].get("gateway_routes", [])]
    body.append(h2("엔드포인트별 (gateway)"))
    body.append(table(["메서드", "경로", "요청", "5xx", "p50 ms", "p95 ms"], rows, numeric=(2, 3, 4, 5)))

    sections = list(dict.fromkeys(c[0] for c in CHARTS))
    for section in sections:
        charts = [c for c in CHARTS if c[0] == section and data["charts"].get(c[1])]
        if not charts:
            continue
        body.append(h2(section) + "<div class='grid'>")
        body += [card(cid, title, unit, note) for _, cid, title, unit, note in charts]
        body.append("</div>")
        if section == "DB (RDS)" and data["tables"].get("slow_queries"):
            rows = [[q["database"], f"<td><code>{e(q['statement'])}</code></td>", fmt(q["count"]),
                     fmt(q["avg"]), fmt(q["max"])] for q in data["tables"]["slow_queries"]]
            body.append("<div class='card' style='margin-top:14px'><h3>1초 넘은 쿼리 (테스트 구간)</h3>")
            body.append(table(["DB", "쿼리", "건수", "평균 ms", "최대 ms"], rows, numeric=(2, 3, 4)))
            body.append("</div>")
        if section == "파드·노드" and data["tables"].get("pods"):
            rows = [[p["pod"], p["image"], p["node"].split(".")[0], fmt(p["cpu"]),
                     fmt(None if p["memory"] is None else p["memory"] / MIB, "{:.0f}"), fmt(p["restarts"]),
                     f"<td class='bad'>교체됨 ({kst(p['first'])}~{kst(p['last'])})</td>" if p["replaced"] else "—"]
                    for p in data["tables"]["pods"]]
            body.append("<div class='card' style='margin-top:14px'><h3>파드 (테스트 중 교체되면 결과 무효)</h3>")
            body.append(table(["파드", "이미지", "노드", "CPU limit", "메모리 limit MiB", "재시작", "교체"], rows,
                              numeric=(3, 4, 5)))
            body.append("</div>")

    traces = data["facts"].get("traces") or {}
    body.append(h2("원본 바로 가기"))
    body.append("<p class='note'>trace: " + (", ".join(f"{k} {v:,}" for k, v in traces.items()) if traces else
                                            "이 구간에는 trace가 없다") + "</p><ul class='links'>")
    body += [f"<li><a href='{e(url)}'>{e(name)}</a></li>" for name, url in data["links"]]
    body.append("</ul>")

    payload = json.dumps({"minutes": data["minutes"], "phases": data["phases"], "charts": data["charts"],
                          "zoom": data.get("zoom")},
                         ensure_ascii=False).replace("</", "<\\/")
    return (PAGE.replace("__TITLE__", e(f"{data['label']} 지표 보고서"))
            .replace("__BODY__", "\n".join(body)).replace("__DATA__", payload))


def phases_of(args, k6):
    if k6.get("started_at") and k6.get("bounds"):
        start = parse_time(k6["started_at"])
        return [{"name": b["phase"], "start": start + timedelta(seconds=b["start"]),
                 "end": start + timedelta(seconds=b["end"])} for b in k6["bounds"]]
    if not args.start or not args.phases:
        raise SystemExit("k6 JSON has no started_at/bounds; pass --start and --phases name=3m,name=20m,…")
    phases, at = [], parse_time(args.start)
    for part in args.phases.split(","):
        name, length = part.split("=")
        phases.append({"name": name, "start": at, "end": at + timedelta(seconds=duration(length))})
        at = phases[-1]["end"]
    return phases


def loadgen_instance(args):
    if args.loadgen:
        return args.loadgen
    try:
        found = aws("ec2", "describe-instances", "--filters", f"Name=tag:Name,Values={LOADGEN}", "--query",
                    "Reservations[].Instances[].InstanceId")
    except subprocess.CalledProcessError:
        return None
    return found[0] if found else None


def main():
    parser = argparse.ArgumentParser(description="collect dev metrics for one load test run into an HTML report")
    parser.add_argument("out", type=Path, help="test folder, e.g. docs test/results/T1-1차")
    parser.add_argument("--label", help="report title (default: folder name)")
    parser.add_argument("--k6", type=Path, help="k6 summary JSON from results/ (copied to k6-summary.json)")
    parser.add_argument("--k6-html", type=Path, help="k6 HTML report (copied to k6-report.html)")
    parser.add_argument("--start", help="test start (UTC ISO) when the k6 JSON has no started_at")
    parser.add_argument("--phases", help="phase lengths when the k6 JSON has no bounds: ramp=3m,steady=20m,ramp-down=2m")
    parser.add_argument("--loadgen", help="load generator instance id (default: looked up by tag)")
    parser.add_argument("--render-only", action="store_true", help="rebuild report.html from metrics.json")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    metrics = args.out / "metrics.json"

    if args.render_only:
        (args.out / "report.html").write_text(render(json.loads(metrics.read_text())))
        return

    if args.k6:
        shutil.copyfile(args.k6, args.out / "k6-summary.json")
    if args.k6_html:
        shutil.copyfile(args.k6_html, args.out / "k6-report.html")
    k6_path = args.out / "k6-summary.json"
    k6 = json.loads(k6_path.read_text()) if k6_path.exists() else {}
    r = Report(args.label or args.out.name, phases_of(args, k6), k6)

    forwards = [Forward("svc/logs-es-http", ES_PORT, 9200), Forward("svc/kps-prometheus", PROM_PORT, 9090)]
    try:
        es, prom = Elastic(), Prometheus()
        steps = [("ALB", lambda: collect_alb(r, es)),
                 *[(s, lambda s=s: collect_requests(r, es, s)) for s in SERVICES],
                 ("error logs", lambda: collect_error_logs(r, es)),
                 ("log volume", lambda: collect_log_volume(r, es)),
                 ("trace.id join", lambda: collect_join(r, es)),
                 ("first failure", lambda: collect_first_failure(r, es)),
                 ("RDS logs", lambda: collect_slow_queries(r, es)),
                 ("traces", lambda: collect_traces(r, es)),
                 ("Prometheus", lambda: collect_prometheus(r, prom)),
                 ("CloudWatch", lambda: collect_cloudwatch(r, loadgen_instance(args)))]
        for name, step in steps:
            print(f"collecting {name}", flush=True)
            step()
    finally:
        for f in forwards:
            f.close()
    summarize(r)

    data = {
        "label": r.label,
        "generated_at": datetime.now(KST).strftime("%Y-%m-%d %H:%M KST"),
        "window": {"start": iso(r.t0), "end": iso(r.t1)},
        "phases": [{"name": p["name"], "start": iso(p["start"]), "end": iso(p["end"])} for p in r.phases],
        "k6": k6,
        "k6_report": "k6-report.html" if (args.out / "k6-report.html").exists() else None,
        "minutes": [iso(t) for t in r.minutes],
        "summary": r.summary,
        "tables": r.tables,
        "facts": r.facts,
        "charts": r.charts,
        "zoom": r.zoom,
    }
    data["links"] = links(r)
    metrics.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    (args.out / "report.html").write_text(render(data))
    print(f"wrote {metrics} and {args.out / 'report.html'}")


if __name__ == "__main__":
    main()
