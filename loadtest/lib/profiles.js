import exec from "k6/execution";

export const MIX = parseMix(__ENV.MIX || "0.7,0.3");

const SLO = {
  read: "p(95)<300",
  save: "p(95)<500",
  failed: "rate<0.001",
};

const PROFILES = {
  smoke: {
    stages: [["30s", 10, "ramp"], ["2m", 10, "steady"], ["10s", 0, "ramp-down"]],
    thresholds: {
      "http_req_failed{phase:steady}": ["rate==0"],
      "checks{phase:steady}": ["rate==1"],
    },
  },
  average: {
    stages: [["3m", 200, "ramp"], ["20m", 200, "steady"], ["2m", 0, "ramp-down"]],
    thresholds: sloAt("steady"),
  },
  stress: {
    stages: [["6m", 400, "ramp"], ["20m", 400, "steady"], ["3m", 0, "ramp-down"]],
    thresholds: sloAt("steady"),
  },
  spike: {
    stages: [
      ["2m", 200, "ramp"],
      ["5m", 200, "baseline"],
      ["1m", 600, "surge"],
      ["2m", 600, "surge"],
      ["1m", 200, "surge"],
      ["2m", 200, "settle"],
      ["3m", 200, "recovery"],
      ["1m", 0, "ramp-down"],
    ],
    thresholds: {
      ...sloAt("baseline"),
      "http_req_failed{phase:surge}": ["rate<0.01"],
      "http_req_duration{slo:save,phase:surge}": ["p(95)<2000"],
      ...sloAt("recovery"),
    },
  },
  soak: {
    stages: [["5m", 200, "ramp"], ["2h", 200, "steady"], ["5m", 0, "ramp-down"]],
    thresholds: sloAt("steady"),
  },
  breakpoint: {
    stages: breakpointStages(Number(__ENV.START || 200), Number(__ENV.STEP || 50), Number(__ENV.MAX || 1000)),
    thresholds: {
      http_req_failed: [{ threshold: "rate<0.05", abortOnFail: true, delayAbortEval: "1m" }],
      "http_req_duration{slo:save}": [{ threshold: "p(95)<3000", abortOnFail: true, delayAbortEval: "1m" }],
    },
  },
};

export const PROFILE_NAME = __ENV.PROFILE || "smoke";
export const PROFILE = PROFILES[PROFILE_NAME];
if (!PROFILE) {
  throw new Error(`unknown PROFILE ${PROFILE_NAME}; one of ${Object.keys(PROFILES).join(", ")}`);
}

export const BOUNDS = PROFILE.stages.reduce((acc, [duration, , phase]) => {
  const start = acc.length ? acc[acc.length - 1].end : 0;
  acc.push({ phase, start, end: start + seconds(duration) });
  return acc;
}, []);

export function phase() {
  const elapsed = (Date.now() - exec.scenario.startTime) / 1000;
  const bound = BOUNDS.find((b) => elapsed < b.end);
  return bound ? bound.phase : "ramp-down";
}

export function phaseSeconds(name, until = Infinity) {
  return BOUNDS.filter((b) => b.phase === name).reduce((sum, b) => sum + Math.max(0, Math.min(b.end, until) - b.start), 0);
}

export function scenarios(execs) {
  const shares = { writer: MIX[0], reader: MIX[1] };
  const result = {};
  for (const [name, fn] of Object.entries(execs)) {
    const stages = PROFILE.stages.map(([duration, users]) => ({
      duration,
      target: Math.round(users * shares[name]),
    }));
    if (stages.every((s) => s.target === 0)) continue;
    result[name] = {
      executor: "ramping-vus",
      startVUs: 0,
      stages,
      gracefulRampDown: "30s",
      gracefulStop: "30s",
      exec: fn,
    };
  }
  return result;
}

export const RECORD_ONLY = ["count>=0", "max>=0", "rate>=0"];

export function thresholds() {
  const all = { ...PROFILE.thresholds };
  const add = (key, expr) => (all[key] = [...(all[key] || []), expr]);
  for (const name of new Set(BOUNDS.map((b) => b.phase))) {
    add(`http_reqs{phase:${name}}`, "count>=0");
    add(`http_req_duration{slo:read,phase:${name}}`, "max>=0");
    add(`http_req_duration{slo:save,phase:${name}}`, "max>=0");
    add(`http_req_failed{phase:${name}}`, "rate>=0");
  }
  return all;
}

function sloAt(name) {
  return {
    [`http_req_duration{slo:read,phase:${name}}`]: [SLO.read],
    [`http_req_duration{slo:save,phase:${name}}`]: [SLO.save],
    [`http_req_failed{phase:${name}}`]: [SLO.failed],
  };
}

function breakpointStages(start, step, max) {
  const stages = [["2m", start, `vus-${start}`]];
  for (let users = start + step; users <= max; users += step) {
    stages.push(["30s", users, `vus-${users}`], ["90s", users, `vus-${users}`]);
  }
  return stages;
}

function parseMix(text) {
  const parts = text.split(",").map(Number);
  const total = parts.reduce((a, b) => a + b, 0);
  if (parts.length !== 2 || parts.some((p) => !(p >= 0)) || Math.abs(total - 1) > 1e-6) {
    throw new Error(`MIX must be two shares (writer,reader) that sum to 1, got ${text}`);
  }
  return parts;
}

function seconds(duration) {
  const match = /^(\d+)(s|m|h)$/.exec(duration);
  if (!match) throw new Error(`unsupported duration ${duration}`);
  return Number(match[1]) * { s: 1, m: 60, h: 3600 }[match[2]];
}
