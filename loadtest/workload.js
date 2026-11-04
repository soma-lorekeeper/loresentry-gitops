import http from "k6/http";
import { sleep, fail } from "k6";
import exec from "k6/execution";
import { BASE_URL, Client, Workspace, ok, projectId, prose, sessions } from "./lib/api.js";
import { scenarios, thresholds } from "./lib/profiles.js";
import { summarize } from "./lib/summary.js";

const TYPE_SECONDS = range(__ENV.TYPE_SECONDS || "10");
const REST_SECONDS = range(__ENV.REST_SECONDS || "3");
const READ_SECONDS = range(__ENV.READ_SECONDS || "20-60");
const CHANGE_INTERVAL = Number(__ENV.CHANGE_INTERVAL || 0.25);
const CHARS_PER_SECOND = Number(__ENV.CHARS_PER_SECOND || 2);
const SWITCH_CHANCE = Number(__ENV.SWITCH_CHANCE || 0.02);
const SAVE_IDLE = 0.8;
const SAVE_MAX_WAIT = 5;
const SEARCH_TERMS = ["레나", "카엘", "성당", "항구", "기사단", "등대"];

export const options = {
  scenarios: scenarios({ writer: "writer", reader: "reader" }),
  thresholds: thresholds(),
  summaryTrendStats: ["avg", "med", "p(90)", "p(95)", "p(99)", "max"],
  hosts: __ENV.TARGET_IP ? { [BASE_URL.replace(/^https?:\/\//, "").split("/")[0]]: __ENV.TARGET_IP } : {},
};

const USERS = Object.values(options.scenarios).reduce((sum, s) => sum + Math.max(...s.stages.map((st) => st.target)), 0);
if (sessions.length < USERS) {
  throw new Error(`this profile needs ${USERS} users but .sessions.csv has ${sessions.length}; run seed-sessions.sh`);
}

export function setup() {
  const res = http.get(`${BASE_URL}/health`);
  if (res.status !== 200) fail(`health check failed: ${res.status}`);
  return { users: USERS };
}

let current = null;

function workspace() {
  if (current) return current;
  const client = new Client(sessions[exec.vu.idInTest - 1]);
  ok(client.get("/auth/users/me", "me"), "me");
  const project = projectId(client);
  if (!project) exec.test.abort(`user ${exec.vu.idInTest} has no project named loadtest; run seed-content.js`);
  const ws = new Workspace(client, project);
  ws.enter();
  if (!ws.documents.length) exec.test.abort(`user ${exec.vu.idInTest} has no manuscripts; run seed-content.js`);
  ws.open(pick(ws.documents).id, true);
  current = ws;
  return ws;
}

export function writer() {
  const ws = workspace();
  if (!ws.doc || Math.random() < SWITCH_CHANCE) ws.open(pick(ws.documents).id);
  if (!ws.doc) {
    sleep(between(REST_SECONDS));
    return;
  }
  const settled = typeFor(ws, between(TYPE_SECONDS));
  sleep(Math.max(0, between(REST_SECONDS) - settled));
}

export function reader() {
  const ws = workspace();
  const roll = Math.random();
  if (roll < 0.7) {
    ws.open(pick(ws.documents).id);
  } else if (roll < 0.85) {
    ws.view("graph");
    ok(ws.client.get(`/projects/${ws.project}/graph`, "graph"), "graph");
  } else {
    ws.view("search");
    const term = encodeURIComponent(pick(SEARCH_TERMS));
    ok(ws.client.get(`/projects/${ws.project}/search?q=${term}`, "search"), "search");
  }
  sleep(between(READ_SECONDS));
}

function typeFor(ws, seconds) {
  let left = seconds;
  for (;;) {
    const typing = Math.max(0, Math.min(SAVE_MAX_WAIT, left));
    sleep(typing);
    left -= typing;
    type(ws.doc, typing);
    if (left <= 0) {
      sleep(SAVE_IDLE);
      return SAVE_IDLE + ws.save().timings.duration / 1000;
    }
    let took = ws.save().timings.duration / 1000;
    while (left > took && Math.random() < took / CHANGE_INTERVAL) {
      left -= took;
      type(ws.doc, took);
      took = ws.save().timings.duration / 1000;
    }
    left -= took;
  }
}

function type(doc, seconds) {
  const chars = Math.max(1, Math.round(seconds * CHARS_PER_SECOND));
  const last = doc.paragraphs.length - 1;
  if (doc.paragraphs[last].length >= 300) {
    doc.paragraphs.push(prose(chars, doc.revision));
  } else {
    doc.paragraphs[last] += prose(chars, doc.revision);
  }
}

function range(text) {
  const [low, high] = text.split("-").map(Number);
  return [low, high === undefined ? low : high];
}

function between([low, high]) {
  return low + Math.random() * (high - low);
}

function pick(items) {
  return items[Math.floor(Math.random() * items.length)];
}

export function handleSummary(data) {
  return summarize(data, { users: USERS });
}
