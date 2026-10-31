# 금지 항목 마스킹 (LOG_SCHEMA.md 4절 "Logstash 마스킹 규칙").
#
# 앱이 실수로 남긴 값을 막는 두 번째 방어선이다. 파싱에 성공했는지와 상관없이 아래 필드 전부에 적용하고,
# ES·S3로 갈라지기 전(app·aws pipeline의 filter)에 부른다. 이름·본문처럼 패턴으로 잡을 수 없는 것은 앱이 찍지 않는 것으로만 막는다.
# 규칙을 바꾸면 LOG_SCHEMA.md 표도 같은 시점에 고친다.

def register(params)
  # 마스킹할 필드. 없는 필드는 건너뛴다.
  # url.original(ALB 요청 줄의 전체 URL)과 Referer에도 쿼리가 들어 있다.
  @fields = ["message", "[event][original]", "[url][query]", "[url][original]", "[http][request][referrer]",
             "[error][message]", "[error][stack_trace]"]

  # [찾는 패턴, 바꿀 값]. 위에서부터 차례로 적용한다. \1·\2는 패턴의 괄호 묶음을 그대로 남긴다.
  @rules = [
    # 이메일: 로컬@도메인.최상위. 클러스터 안 주소(.svc·.local·.internal)는 이메일이 아니라 남긴다
    # (예: Kafka controller.quorum.voters의 0@lore-sentry-broker-0.lore-sentry-kafka-brokers.dev.svc:9090).
    [/[A-Za-z0-9._%+-]+@(?![A-Za-z0-9.-]*\.(?:svc|local|internal)\b)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/, "[email]"],
    # 쿼리의 OAuth code·state, 광고 클릭 ID 값. 이름과 utm_*는 남긴다.
    # 앞이 ?·&인 URL 안의 값, 줄 맨 앞(url.query 필드), "로 시작하는 JSON 문자열(event.original의 "query":"code=...")을 잡는다.
    [/(^|[?&"])(code|state|gclid|gbraid|wbraid)=[^&\s"'#]+/, '\1\2=[redacted]'],
    # 세션·동의 쿠키 값 (__Host- 접두어 포함)
    [/((?:__Host-)?ls_(?:session|consent)=)[^;\s"',]+/, '\1[redacted]'],
    # 인증 헤더: 헤더 이름 뒤의 값을 줄 끝까지. JSON으로 찍힌 "authorization": "..."도 잡는다.
    [/\b((?:set-)?cookie|authorization)(["']?\s*:\s*)[^\r\n]+/i, '\1\2[redacted]'],
    # JWT: eyJ로 시작하고 점으로 나뉜 세 조각 (Google ID 토큰 안에 이메일·이름이 있다)
    [/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/, "[jwt]"],
    # 비밀번호: ALTER ROLE ... PASSWORD '...'. PostgreSQL은 값 안의 '를 ''로 적는다.
    [/(PASSWORD\s+)'(?:[^']|'')*'/i, "\\1'[redacted]'"],
    # 고유 키·외래 키 위반 DETAIL의 키 값: Key (칼럼)=(값) already exists.
    [/(Key \([^)]*\)=\().*?(\)(?= [a-z]|\.?$))/, '\1[redacted]\2']
  ]
end

def filter(event)
  @fields.each do |field|
    value = event.get(field)
    # 같은 필드에 값이 여러 번 들어가면 배열이 된다. 배열 안의 문자열도 빠짐없이 지운다.
    if value.is_a?(String)
      masked = mask(value)
    elsif value.is_a?(Array)
      masked = value.map { |item| item.is_a?(String) ? mask(item) : item }
    else
      next
    end
    event.set(field, masked) unless masked == value
  end
  [event]
end

def mask(text)
  @rules.reduce(text) { |current, (pattern, replacement)| current.gsub(pattern, replacement) }
end
