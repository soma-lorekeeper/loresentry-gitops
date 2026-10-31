# Neptune slowquery 로그를 정리하고 쿼리의 값을 지운다(aws-filter.conf에서 부른다, LOG_SCHEMA.md 8절).
#
# 입력: [@metadata][np] = slowquery JSON 한 건을 푼 해시(문서 slow-query-logs).
# 쿼리를 보내는 곳은 graph-rag 하나이고, 모든 값을 literal()로 '...'(작은따옴표) 리터럴로 넣는다
# (loresentry-graph-rag app/adapters/projection_gremlin.py literal(), 바인딩 없음).
# 리터럴 가운데 아래만 남기고 나머지는 '[redacted]'로 바꾼다. 문서 제목·설명 같은 작품 내용을 지우기 위해서다.
#   - 스키마 낱말 허용 목록(@allow): 라벨, 속성 키, 결과·오류 코드, consumer 이름, 폴더 코드
#   - 식별자: UUID, 또는 소문자 접두어와 UUID를 ':'로 이은 값(file:<uuid>, inbox:<consumer>:<uuid>:<uuid> ...)
#   - sha256(16진수 64자리), ISO-8601 시각
# 목록에 없는 낱말은 지워지기만 하므로(내용이 새지 않음) graph-rag에 새 키가 생기면 이 목록에 더한다.
# 따옴표 없는 숫자(sequence, limit)와 true·false는 그대로 둔다. 쿼리 원문은 어디에도 남기지 않는다.
require "json"
require "set"
require "time"

def register(params)
  @allow = %w[
    File InboxEvent ProjectionState REFERENCES
    project_id title folder_code description trashed deleted origin sequence event_id payload_sha256
    processed_at consumer_name request_id request_sha256 completion_json outbox_pending identifier receipt
    created_at relation_id seed seed_id seed_ids target_id edge relations count
    APPLIED DUPLICATE SENT USER true false
    PROJECTION_INBOX_CONFLICT PROJECTION_PROJECT_MISMATCH PROJECTION_MISSING_FILE PROJECTION_RELATION_CONFLICT
    PROJECTION_PAIR_CONFLICT PROJECTION_NOT_READY REFRESH_INBOX_CONFLICT REFRESH_INBOX_INVALID REFRESH_INBOX_UNAVAILABLE
    content-graph-projection graph-rag-refresh
    WORLDVIEW CHARACTER LOCATION ORGANIZATION ITEM EVENT
  ].to_set
  uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  segment = "(?:[a-z][a-z0-9-]*|#{uuid})"
  @identifier = /\A(?=.*#{uuid})#{segment}(?::#{segment})*\z/
  @sha256 = /\A[0-9a-f]{64}\z/
  @iso_time = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/
  # graph-rag literal()이 만드는 작은따옴표 리터럴: 안의 '와 \는 \로 이스케이프된다
  @literal = /'((?:[^'\\]|\\.)*)'/m
  # 다른 경로로 들어온 큰따옴표 문자열도 같은 기준으로 지운다(방어)
  @double_literal = /"((?:[^"\\]|\\.)*)"/m
end

def keep?(value)
  @allow.include?(value) || value.match?(@identifier) || value.match?(@sha256) || value.match?(@iso_time)
end

def redact(query)
  text = query.gsub(@literal) { keep?($1) ? $& : "'[redacted]'" }
  text.gsub(@double_literal) { keep?($1) ? $& : "\"[redacted]\"" }
end

def filter(event)
  np = event.get("[@metadata][np]")
  return [event] unless np.is_a?(Hash)

  meta = np["requestResponseMetadata"] || {}
  stats = np["queryStats"] || {}
  times = np["queryTimeStats"] || {}

  query = stats["query"]
  # GET은 "gremlin=<스크립트>"로 찍힌다(문서 예시). 접두어를 먼저 떼고,
  # POST 본문이 JSON 그대로 찍히면 그 안의 gremlin 스크립트만 꺼낸다. 그래야 쿼리 모양이 남는다.
  query = query.sub(/\Agremlin=/, "") if query.is_a?(String)
  if query.is_a?(String) && query.start_with?("{")
    begin
      body = JSON.parse(query)
      query = body["gremlin"] || body["query"] || query
    rescue JSON::ParserError
      # 그대로 지운다
    end
  end
  fingerprint = stats["queryFingerprint"]
  event.set("message", query.is_a?(String) ? redact(query) : "slow query #{fingerprint}")

  event.set("[aws][neptune][query_language]", stats["queryLanguage"]) if stats["queryLanguage"]
  event.set("[aws][neptune][query_fingerprint]", fingerprint) if fingerprint
  event.set("[aws][neptune][request_id]", meta["requestId"]) if meta["requestId"]
  event.set("[aws][neptune][request_type]", meta["requestType"]) if meta["requestType"]
  event.set("[http][response][status_code]", meta["responseStatusCode"].to_i) if meta["responseStatusCode"]
  event.set("[error][type]", meta["exceptionClass"]) if meta["exceptionClass"]

  # 숫자뿐인 통계 묶음은 그대로 옮긴다(소요 시간, 읽은 문장 수, 정점·간선 변경 수, 메모리, 동시 실행 수)
  %w[queryTimeStats statementCounters transactionCounters vertexCounters edgeCounters memoryStats
     concurrentExecutionStats resultCache storageCounters].each do |key|
    value = np[key]
    next unless value.is_a?(Hash)
    numbers = value.select { |_, v| v.is_a?(Numeric) }
    event.set("[aws][neptune][#{key}]", numbers) unless numbers.empty?
  end
  event.set("[event][duration]", (times["overallRunTimeMs"].to_f * 1_000_000).round) if times["overallRunTimeMs"]

  # 쿼리 시작 시각(UTC, 예: 23/02/2023 11:42:52.657)
  if times["startTime"].is_a?(String)
    begin
      event.set("@timestamp", LogStash::Timestamp.new(Time.strptime("#{times['startTime']} UTC", "%d/%m/%Y %H:%M:%S.%L %Z")))
    rescue ArgumentError
      # CloudWatch 이벤트 시각을 그대로 둔다
    end
  end

  # 느린 쿼리는 warn, 실패(예외 또는 5xx)는 error (3절)
  failed = meta["exceptionClass"] || meta["responseStatusCode"].to_i >= 500
  event.set("[log][level]", failed ? "error" : "warn")
  [event]
end
