import exec from "k6/execution";
import { Client, PROJECT_NAME, contentBody, ok, paragraphs, projectId, sessions } from "./lib/api.js";

const COUNT = Math.min(Number(__ENV.COUNT || sessions.length), sessions.length);
const MANUSCRIPTS = [2000, 2000, 2000, 2000, 2000, 10000, 10000, 10000, 10000, 50000];
const SETTINGS = [
  ["CHARACTER", "레나"],
  ["CHARACTER", "카엘"],
  ["LOCATION", "북쪽 항구"],
  ["ORGANIZATION", "기사단"],
  ["ITEM", "오래된 지도"],
];
const PLAN = [
  ...MANUSCRIPTS.map((chars, i) => ({ title: `${i + 1}화`, folder: "MANUSCRIPT", chars })),
  ...SETTINGS.map(([folder, title]) => ({ title, folder, chars: 800 })),
];

export const options = {
  scenarios: {
    seed: { executor: "shared-iterations", vus: Number(__ENV.VUS || 10), iterations: COUNT, maxDuration: "2h" },
  },
  thresholds: { checks: ["rate==1"] },
};

export default function () {
  const client = new Client(sessions[exec.scenario.iterationInTest]);
  let project = projectId(client);
  if (!project) {
    const res = client.send("POST", "/projects", { name: PROJECT_NAME, description: "load test data" }, "seed_project");
    if (!ok(res, "create project")) return;
    project = res.json("id") || (res.headers.Location || "").split("/").pop();
  }
  const files = client.get(`/projects/${project}/files`, "files");
  if (!ok(files, "files")) return;
  const existing = new Map((files.json("documents") || []).map((d) => [d.title, d]));
  for (const doc of PLAN) {
    let file = existing.get(doc.title);
    if (!file) {
      const created = client.send(
        "POST",
        `/projects/${project}/files`,
        { kind: "document", title: doc.title, folder_code: doc.folder, episode_id: null },
        "seed_file",
      );
      if (!ok(created, "create document")) continue;
      file = created.json();
    }
    if (file.char_count > 0) continue;
    const saved = client.send("PUT", `/files/${file.id}/content`, contentBody(doc.title, paragraphs(doc.chars)), "seed_content", {
      "If-Match": `"${file.revision_no}"`,
      "X-Save-Id": crypto.randomUUID(),
    });
    ok(saved, "write document");
  }
}
