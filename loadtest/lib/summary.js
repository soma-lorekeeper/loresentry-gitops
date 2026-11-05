import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js";
import { BOUNDS, MIX, PROFILE_NAME, RECORD_ONLY, phaseSeconds } from "./profiles.js";

export function summarize(data, extra = {}) {
  const phases = {};
  for (const [key, metric] of Object.entries(data.metrics)) {
    const match = /^http_reqs\{phase:([^}]+)\}$/.exec(key);
    if (!match) continue;
    const name = match[1];
    const span = phaseSeconds(name, data.state.testRunDurationMs / 1000);
    phases[name] = {
      seconds: span,
      requests: metric.values.count,
      rps: span ? round(metric.values.count / span) : null,
      read_p95_ms: value(data, `http_req_duration{slo:read,phase:${name}}`, "p(95)"),
      read_p99_ms: value(data, `http_req_duration{slo:read,phase:${name}}`, "p(99)"),
      save_p95_ms: value(data, `http_req_duration{slo:save,phase:${name}}`, "p(95)"),
      save_p99_ms: value(data, `http_req_duration{slo:save,phase:${name}}`, "p(99)"),
      error_rate: value(data, `http_req_failed{phase:${name}}`, "rate"),
    };
  }
  const thresholds = {};
  for (const [key, metric] of Object.entries(data.metrics)) {
    for (const [expr, result] of Object.entries(metric.thresholds || {})) {
      if (RECORD_ONLY.includes(expr)) continue;
      const judged = /phase:([^,}]+)/.exec(key);
      const measured = !judged || (phases[judged[1]] && phases[judged[1]].requests > 0);
      thresholds[`${key} ${expr}`] = result.ok && measured;
    }
  }
  const finished = new Date();
  const record = {
    profile: PROFILE_NAME,
    mix: { writer: MIX[0], reader: MIX[1] },
    started_at: new Date(finished.getTime() - data.state.testRunDurationMs).toISOString(),
    finished_at: finished.toISOString(),
    bounds: BOUNDS,
    passed: Object.values(thresholds).every(Boolean),
    thresholds,
    phases,
    ...extra,
  };
  const file = `${__ENV.RESULTS_DIR || "results"}/${PROFILE_NAME}-${record.finished_at.replace(/[:.]/g, "-")}.json`;
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }) + "\n" + JSON.stringify(record, null, 2) + "\n",
    [file]: JSON.stringify(record, null, 2),
  };
}

function value(data, key, stat) {
  const metric = data.metrics[key];
  if (!metric || metric.values[stat] === undefined) return null;
  return round(metric.values[stat]);
}

function round(n) {
  return Math.round(n * 1000) / 1000;
}
