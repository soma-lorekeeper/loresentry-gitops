import http from "k6/http";
import { check, sleep, fail } from "k6";
import { SharedArray } from "k6/data";

const BASE_URL = __ENV.BASE_URL || "https://api-dev.loresentry.com";
const ORIGIN = "https://loresentry.com";

if (/^https:\/\/api\.loresentry\.com/.test(BASE_URL)) {
  throw new Error("refusing to load-test the production API");
}

const sessions = new SharedArray("sessions", () =>
  open(__ENV.SESSIONS || "./.sessions.csv")
    .trim()
    .split("\n")
    .slice(1)
    .map((line) => line.split(",")[1]),
);

export const options = {
  scenarios: {
    browse: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: __ENV.RAMP || "1m", target: Number(__ENV.VUS || 20) },
        { duration: __ENV.HOLD || "3m", target: Number(__ENV.VUS || 20) },
        { duration: "30s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{kind:read}": ["p(95)<800"],
  },
};

export function setup() {
  const res = http.get(`${BASE_URL}/health`);
  if (res.status !== 200) fail(`health check failed: ${res.status}`);
  if (sessions.length === 0) fail("no sessions; run seed-sessions.sh first");
}

function params(session, kind, mutate = false) {
  const headers = { Cookie: `__Host-ls_session=${session}` };
  if (mutate) {
    headers.Origin = ORIGIN;
    headers["X-LS-CSRF"] = "1";
    headers["Content-Type"] = "application/json";
  }
  return { headers, tags: { kind } };
}

let projectId = null;

export default function () {
  const session = sessions[(__VU - 1) % sessions.length];

  const me = http.get(`${BASE_URL}/auth/users/me`, params(session, "read"));
  check(me, { "me 200": (r) => r.status === 200 });

  if (!projectId) {
    const list = http.get(`${BASE_URL}/projects`, params(session, "read"));
    const projects = list.status === 200 ? list.json("projects") : [];
    if (projects && projects.length > 0) {
      projectId = projects[0].id;
    } else {
      const created = http.post(`${BASE_URL}/projects/sample?locale=ko`, null, params(session, "write", true));
      check(created, { "sample 201": (r) => r.status === 201 });
      if (created.status === 201) projectId = created.json("id");
    }
  }

  if (projectId) {
    const files = http.get(`${BASE_URL}/projects/${projectId}/files`, params(session, "read"));
    check(files, { "files 200": (r) => r.status === 200 });
    const graph = http.get(`${BASE_URL}/projects/${projectId}/graph`, params(session, "read"));
    check(graph, { "graph 200": (r) => r.status === 200 });
  }

  sleep(1);
}
