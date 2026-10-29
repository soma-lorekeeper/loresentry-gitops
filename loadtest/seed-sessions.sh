#!/usr/bin/env bash
set -euo pipefail

COUNT="${1:-100}"
CONTEXT="${KUBE_CONTEXT:-lore-sentry-dev}"
NAMESPACE=dev
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-${DIR}/.sessions.csv}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

kc() { kubectl --context "$CONTEXT" -n "$NAMESPACE" "$@"; }

if [ "$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CONTEXT}')].context.cluster}")" != \
     "arn:aws:eks:ap-northeast-2:197179613039:cluster/lore-sentry-dev-k8s" ]; then
  echo "refusing to run: context ${CONTEXT} is not the dev cluster" >&2
  exit 1
fi

python3 -I - "$COUNT" "$WORK" <<'PY'
import base64, hashlib, json, secrets, sys, time, uuid
count, work = int(sys.argv[1]), sys.argv[2]
now = int(time.time())
expires = (now + 14 * 24 * 3600) * 1000
run = time.strftime("%m%d%H%M", time.gmtime(now))
users, sessions, commands = [], [], []
for i in range(1, count + 1):
    user = str(uuid.uuid4())
    session = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
    digest = hashlib.sha256(session.encode("ascii")).hexdigest()
    name = f"loadtest-{run}-{i:05d}"
    users.append((user, name))
    sessions.append(f"{user},{session}")
    record = json.dumps({"schema_version": 2, "user_id": user, "created_at": now}, separators=(",", ":"))
    index = json.dumps({"schema_version": 2, "session_hash": digest}, separators=(",", ":"))
    quote = lambda s: '"' + s.replace('"', '\\"') + '"'
    commands.append(f"SET auth:session:{{login}}:by-id:{digest} {quote(record)} PXAT {expires}")
    commands.append(f"SET auth:session:{{login}}:by-user:{user} {quote(index)} PXAT {expires}")
values = ",\n".join(f"('{u}'::uuid, '{n}')" for u, n in users)
sql = f"""BEGIN;
CREATE TEMP TABLE seed(id uuid, name text) ON COMMIT DROP;
INSERT INTO seed VALUES
{values};
INSERT INTO users (id, display_name, created_at, updated_at, onboarding_completed_at, locale)
SELECT id, name, now(), now(), now(), 'ko' FROM seed;
INSERT INTO oauth_identities (provider, provider_id, user_id, email)
SELECT 'google', 'loadtest-' || id, id, name || '@loadtest.invalid' FROM seed;
INSERT INTO user_terms_acceptances (user_id, terms_version_id, accepted_at)
SELECT s.id, t.id, now() FROM seed s
CROSS JOIN LATERAL (SELECT id FROM terms_versions WHERE effective_at <= now() ORDER BY effective_at DESC LIMIT 1) t;
SELECT count(*) AS seeded_users FROM seed;
COMMIT;
"""
open(f"{work}/users.sql", "w").write(sql)
open(f"{work}/sessions.valkey", "w").write("\n".join(commands) + "\n")
open(f"{work}/sessions.csv", "w").write("user_id,session_id\n" + "\n".join(sessions) + "\n")
PY

PG_HOST="$(kc get configmap postgres -o jsonpath='{.data.host}')"
echo "== users -> ${PG_HOST}/authentication"
kc delete pod loadtest-seed-sql --ignore-not-found >/dev/null
kc run loadtest-seed-sql --rm -i --restart=Never --quiet --image=postgres:18-alpine --overrides="$(cat <<JSON
{
  "spec": {
    "containers": [{
      "name": "loadtest-seed-sql",
      "image": "postgres:18-alpine",
      "stdin": true,
      "stdinOnce": true,
      "command": ["sh", "-c", "PGUSER=\"\$DB_USERNAME\" PGPASSWORD=\"\$DB_PASSWORD\" psql \"host=${PG_HOST} dbname=authentication sslmode=require\" -v ON_ERROR_STOP=1 -q -f -"],
      "env": [
        {"name": "DB_USERNAME", "valueFrom": {"secretKeyRef": {"name": "authentication-db", "key": "username"}}},
        {"name": "DB_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "authentication-db", "key": "password"}}}
      ]
    }]
  }
}
JSON
)" < "${WORK}/users.sql"

echo "== sessions -> auth-valkey"
PASS="$(kc get secret authentication-runtime -o jsonpath='{.data.SPRING_DATA_REDIS_PASSWORD}' | base64 -d)"
kc exec -i deploy/auth-valkey -c valkey -- \
  valkey-cli --user authentication --pass "$PASS" --no-auth-warning < "${WORK}/sessions.valkey" \
  | sort | uniq -c

if [ -f "$OUT" ]; then
  tail -n +2 "${WORK}/sessions.csv" >> "$OUT"
else
  cp "${WORK}/sessions.csv" "$OUT"
fi
echo "sessions appended to ${OUT} ($(($(wc -l < "$OUT") - 1)) total). They expire in 14 days."
