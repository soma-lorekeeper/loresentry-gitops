import http from "k6/http";
import { check } from "k6";
import { SharedArray } from "k6/data";
import { phase } from "./profiles.js";

export const BASE_URL = __ENV.BASE_URL || "https://api-dev.loresentry.com";
export const ORIGIN = __ENV.ORIGIN || "https://dev.loresentry.com";
export const PROJECT_NAME = __ENV.PROJECT_NAME || "loadtest";

if (/^https:\/\/api\.loresentry\.com/.test(BASE_URL)) {
  throw new Error("refusing to load-test the production API");
}

export const sessions = new SharedArray("sessions", () =>
  open(__ENV.SESSIONS || "../.sessions.csv")
    .trim()
    .split("\n")
    .slice(1)
    .map((line) => line.split(",")[1]),
);

const OK_OR_MISSING = http.expectedStatuses({ min: 200, max: 399 }, 404);

const SLO = {
  content_get: "read",
  files: "read",
  content_put: "save",
};

export class Client {
  constructor(session) {
    this.session = session;
  }

  params(name, headers = {}, expected) {
    const params = {
      headers: { Origin: ORIGIN, ...headers },
      cookies: { "__Host-ls_session": { value: this.session, replace: true } },
      tags: { name, slo: SLO[name] || "other", phase: phase() },
    };
    if (expected) params.responseCallback = expected;
    return params;
  }

  get(path, name, expected) {
    return http.get(BASE_URL + path, this.params(name, {}, expected));
  }

  send(method, path, body, name, headers = {}) {
    const params = this.params(name, { "X-LS-CSRF": "1", "Content-Type": "application/json", ...headers });
    return http.request(method, BASE_URL + path, body === null ? null : JSON.stringify(body), params);
  }

  batch(requests) {
    return http.batch(
      requests.map(([path, name, expected]) => ({
        method: "GET",
        url: BASE_URL + path,
        params: this.params(name, {}, expected),
      })),
    );
  }
}

export function ok(res, label, missingOk = false) {
  return check(
    res,
    { [label]: (r) => (r.status >= 200 && r.status < 400) || (missingOk && r.status === 404) },
    { phase: phase() },
  );
}

export function projectId(client) {
  const res = client.get("/projects", "projects");
  ok(res, "projects");
  if (res.status !== 200) return undefined;
  const project = (res.json("projects") || []).find((p) => p.name === PROJECT_NAME);
  return project ? project.id : null;
}

export class Workspace {
  constructor(client, project) {
    this.client = client;
    this.project = project;
    this.documents = [];
    this.listed = false;
    this.chat = false;
    this.listedAt = 0;
    this.doc = null;
  }

  enter() {
    const c = this.client;
    const p = this.project;
    const [project, state] = c.batch([
      [`/projects/${p}`, "project"],
      [`/projects/${p}/workspace-state`, "workspace_state_get"],
    ]);
    ok(project, "project");
    ok(state, "workspace_state_get");
    this.refreshLists(true);
    const availability = c.get(`/projects/${p}/chat/availability`, "chat_availability");
    ok(availability, "chat_availability");
    this.chat = availability.status === 200 && availability.json("status") === "available";
    if (this.chat) {
      const [chatSessions, usage] = c.batch([
        [`/projects/${p}/chat/sessions`, "chat_sessions"],
        ["/chat/usage", "chat_usage"],
      ]);
      ok(chatSessions, "chat_sessions");
      ok(usage, "chat_usage");
    }
  }

  refreshLists(withProjects = false) {
    const c = this.client;
    const p = this.project;
    const requests = [
      [`/projects/${p}/files`, "files"],
      [`/projects/${p}/favorites`, "favorites"],
      [`/projects/${p}/graph-refresh`, "graph_refresh", OK_OR_MISSING],
      [`/projects/${p}/setting-checks/summary`, "setting_check_summary"],
    ];
    if (withProjects) requests.push(["/projects", "projects"]);
    const [files, ...rest] = c.batch(requests);
    ok(files, "files");
    rest.forEach((res, i) => ok(res, requests[i + 1][1], requests[i + 1][2] === OK_OR_MISSING));
    if (files.status === 200) {
      this.documents = (files.json("documents") || []).filter((d) => d.folder_code === "MANUSCRIPT" && !d.trashed_at);
      this.listed = true;
    }
    this.listedAt = Date.now();
  }

  open(documentId, restored = false) {
    if (Date.now() - this.listedAt > 30000) this.refreshLists();
    const res = this.client.get(`/files/${documentId}/content`, "content_get");
    ok(res, "content_get");
    if (res.status !== 200) return null;
    const body = res.json();
    this.doc = {
      id: body.id,
      title: body.title,
      revision: body.revision_no,
      paragraphs: paragraphsOf(body.body),
    };
    if (!restored) this.saveLayout({ kind: "file", fileId: body.id });
    return this.doc;
  }

  view(kind) {
    this.saveLayout({ kind });
  }

  saveLayout(target) {
    const tabId = target.kind === "file" ? `file:${target.fileId}` : target.kind;
    const layout = {
      version: 1,
      panes: [{ id: "pane-1", tabs: [{ id: tabId, target }], activeTabId: tabId }],
      activePaneId: "pane-1",
      sidebarOpen: true,
      panels: { memoOpen: false, memoDock: "right", memoRightWidth: 320, memoBelowHeight: 240 },
    };
    ok(this.client.send("PUT", `/projects/${this.project}/workspace-state`, { layout }, "workspace_state_put"), "workspace_state_put");
  }

  save() {
    const doc = this.doc;
    const res = this.client.send(
      "PUT",
      `/files/${doc.id}/content`,
      contentBody(doc.title, doc.paragraphs),
      "content_put",
      { "If-Match": `"${doc.revision}"`, "X-Save-Id": crypto.randomUUID() },
    );
    ok(res, "content_put");
    if (res.status === 200) {
      doc.revision = res.json("revision_no");
    } else if (res.status === 409 && res.json("code") === "DOCUMENT_CONFLICT") {
      doc.revision = res.json("current.revision_no");
    }
    return res;
  }
}

export function contentBody(title, paragraphs) {
  return {
    title,
    body: {
      schema_version: 1,
      doc: {
        type: "doc",
        content: paragraphs.map((text) => ({ type: "paragraph", content: [{ type: "text", text }] })),
      },
    },
    properties: [],
    relations: [],
  };
}

function paragraphsOf(body) {
  const nodes = (body && body.doc && body.doc.content) || [];
  const paragraphs = nodes
    .map((node) => (node.content || []).map((child) => child.text || "").join(""))
    .filter((text) => text.length > 0);
  return paragraphs.length ? paragraphs : [""];
}

const CORPUS = [
  "레나는 무너진 성당의 종탑 아래에서 오래된 지도를 펼쳤다.",
  "북쪽 항구에서 온 카엘은 바람의 방향이 바뀐 것을 먼저 알아챘다.",
  "도시의 성벽은 밤마다 조금씩 낮아지는 것처럼 보였다.",
  "그녀는 회색 눈으로 불타는 수평선을 한참 동안 바라보았다.",
  "기사단의 깃발이 언덕 너머로 사라지자 마을은 다시 조용해졌다.",
  "오래된 계약서에는 누구의 이름도 적혀 있지 않았다.",
  "검은 숲의 끝에서 낯선 노래가 들려오기 시작했다.",
  "그날 이후 아무도 등대에 불을 켜지 않았다.",
];

export function prose(chars, seed = 0) {
  let text = "";
  let i = seed;
  while (text.length < chars) {
    text += CORPUS[i % CORPUS.length] + " ";
    i += 1;
  }
  return text.slice(0, chars);
}

export function paragraphs(chars, size = 300) {
  const result = [];
  for (let written = 0, seed = 0; written < chars; written += size, seed += 3) {
    result.push(prose(Math.min(size, chars - written), seed));
  }
  return result;
}
