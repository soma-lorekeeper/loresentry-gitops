# ALB 접근 로그 grok 결과를 다듬는다(aws-filter.conf에서 부른다).
#   - 없는 값('-')을 지운다
#   - 세 처리 시간(요청·대상·응답, 초)의 합을 event.duration(나노초)으로. 하나라도 -1(측정 못 함)이면 두지 않는다
#   - url.original(https://host:443/path?query)을 url.scheme·url.path·url.query로 나눈다
#   - TLSv1.2 → tls.version 1.2 + tls.version_protocol tls (ECS 표기)
#   - 응답 코드로 log.level: 5xx error, 4xx warn, 그 외 info (3절)

def register(params)
  # '-'가 "값 없음"인 칸
  @dash_fields = [
    "[user_agent][original]", "[tls][cipher]", "[tls][version]", "[http][request][id]", "[url][domain]",
    "[aws][alb][target_group_arn]", "[aws][alb][chosen_cert_arn]", "[aws][alb][matched_rule_priority]",
    "[aws][alb][actions_executed]", "[aws][alb][redirect_url]", "[aws][alb][error_reason]",
    "[aws][alb][target_port_list]", "[aws][alb][target_status_code_list]", "[aws][alb][classification]",
    "[aws][alb][classification_reason]", "[aws][alb][conn_trace_id]"
  ]
end

def filter(event)
  @dash_fields.each { |field| event.remove(field) if event.get(field) == "-" }

  seconds = ["request_seconds", "target_seconds", "response_seconds"].map { |k| event.get("[@metadata][alb][#{k}]") }
  if seconds.all? { |s| s && s.to_f >= 0 }
    event.set("[event][duration]", (seconds.sum { |s| s.to_f } * 1_000_000_000).round)
  end

  url = event.get("[url][original]")
  if url && (m = url.match(%r{\A([a-z0-9+.-]+)://[^/?#]*(/[^?#]*)?(?:\?([^#]*))?}i))
    event.set("[url][scheme]", m[1].downcase)
    event.set("[url][path]", m[2] || "/")
    event.set("[url][query]", m[3]) if m[3] && !m[3].empty?
  end

  tls = event.get("[tls][version]")
  if tls && (m = tls.match(/\ATLSv(\d(?:\.\d)?)\z/))
    event.set("[tls][version]", m[1])
    event.set("[tls][version_protocol]", "tls")
  end

  status = event.get("[http][response][status_code]") || event.get("[aws][alb][target_status_code]")
  level = if status.nil? then "unknown"
          elsif status >= 500 then "error"
          elsif status >= 400 then "warn"
          else "info"
          end
  event.set("[log][level]", level)
  [event]
end
