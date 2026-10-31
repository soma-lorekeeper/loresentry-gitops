# EKS(Kubernetes API) 감사 이벤트를 정리한다(aws-filter.conf에서 부른다).
# 입력: [@metadata][audit] = audit.k8s.io/v1 Event JSON 한 건을 푼 해시.
#
# 버리는 것(4절 소음 제거): 시스템 계정(system:·eks:로 시작)의 성공한 읽기(get·list·watch).
#   컨트롤러·kubelet·operator가 쉬지 않고 읽어 양의 대부분을 차지하고 감사 가치가 낮다.
#   쓰기, 사람(IAM 사용자·역할)의 모든 요청, 실패한 요청(400 이상)은 시스템 계정 것도 남긴다.
# 필드: kubernetes.audit.* (Elastic Kubernetes audit 통합과 같은 이름). user.*는 앱 사용자 전용이라 쓰지 않는다.
# log.level: 응답 5xx error, 401·403 warn, 그 외 info (3절).
require "time"

def register(params)
  @read_verbs = %w[get list watch]
end

def filter(event)
  audit = event.get("[@metadata][audit]")
  return [event] unless audit.is_a?(Hash)

  verb = audit["verb"].to_s
  user = audit["user"].is_a?(Hash) ? audit["user"] : {}
  username = user["username"].to_s
  status = audit.dig("responseStatus", "code").to_i
  system_account = username.start_with?("system:") || username.start_with?("eks:")
  return [] if system_account && @read_verbs.include?(verb) && status < 400

  ref = audit["objectRef"].is_a?(Hash) ? audit["objectRef"] : {}
  set = lambda { |field, value| event.set(field, value) unless value.nil? || value == "" }
  set.call("[kubernetes][audit][verb]", verb)
  set.call("[kubernetes][audit][stage]", audit["stage"])
  set.call("[kubernetes][audit][level]", audit["level"])
  set.call("[kubernetes][audit][auditID]", audit["auditID"])
  set.call("[kubernetes][audit][requestURI]", audit["requestURI"])
  set.call("[kubernetes][audit][user][username]", username)
  set.call("[kubernetes][audit][user][groups]", user["groups"])
  arn = user.dig("extra", "arn")
  set.call("[kubernetes][audit][user][arn]", arn.is_a?(Array) ? arn.first : arn)
  set.call("[kubernetes][audit][impersonatedUser][username]", audit.dig("impersonatedUser", "username"))
  %w[resource subresource namespace name apiGroup apiVersion].each do |key|
    set.call("[kubernetes][audit][objectRef][#{key}]", ref[key])
  end
  set.call("[kubernetes][audit][responseStatus][code]", status) if status > 0
  set.call("[kubernetes][audit][responseStatus][reason]", audit.dig("responseStatus", "reason"))
  set.call("[kubernetes][audit][annotations][authorization_decision]", audit.dig("annotations", "authorization.k8s.io/decision"))

  set.call("[event][action]", verb)
  set.call("[http][response][status_code]", status) if status > 0
  set.call("[user_agent][original]", audit["userAgent"])
  ips = audit["sourceIPs"]
  set.call("[source][ip]", ips.first) if ips.is_a?(Array)

  # 요청을 받은 시각
  if audit["requestReceivedTimestamp"].is_a?(String)
    begin
      event.set("@timestamp", LogStash::Timestamp.new(Time.iso8601(audit["requestReceivedTimestamp"])))
    rescue ArgumentError
      # CloudWatch 이벤트 시각을 그대로 둔다
    end
  end

  # Discover에서 한눈에 읽히는 한 줄: get secrets dev/auth-runtime by arn:aws:iam::...:user/x -> 403
  target = [ref["resource"], ref["subresource"]].compact.join("/")
  name = [ref["namespace"], ref["name"]].compact.join("/")
  event.set("message", "#{verb} #{target} #{name} by #{username}#{status > 0 ? " -> #{status}" : ''}".squeeze(" "))

  level = if status >= 500 then "error"
          elsif status == 401 || status == 403 then "warn"
          else "info"
          end
  event.set("[log][level]", level)
  [event]
end
