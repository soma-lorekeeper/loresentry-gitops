# CloudFront 표준 로그 v2(JSON)를 ECS 필드로 옮긴다(aws-filter.conf에서 부른다).
# 입력: [@metadata][cf] = JSON 한 줄을 푼 해시. 키는 CloudFront 필드 이름(문서 standard-logs-reference)이다.
#   - 아는 키만 옮긴다. 모르는 키를 그대로 펼치면 필드가 계속 늘어난다
#   - cs(Cookie)는 세션 쿠키가 들어 있어 어디에도 두지 않는다(로그를 켤 때도 이 필드는 고르지 않는다, 6단계)
#   - 없는 값은 '-'다
#   - event.original에는 cs(Cookie)를 뺀 JSON을 둔다
#   - message는 "메서드 경로?쿼리 상태" 한 줄. 마스킹은 뒤의 mask.rb가 message·url.query에 한다
require "json"
require "time"
require "uri"

def register(params)
  # CloudFront 키 → [ECS 필드, 변환]
  @map = {
    "c-ip" => ["[source][ip]", :str],
    "c-port" => ["[source][port]", :int],
    "c-country" => ["[source][geo][country_iso_code]", :str], # 접속 IP로 CloudFront가 정한 국가(ISO 3166-1 alpha-2)
    "cs-method" => ["[http][request][method]", :str],
    "x-host-header" => ["[url][domain]", :str],
    "cs-uri-stem" => ["[url][path]", :str],
    "cs-uri-query" => ["[url][query]", :str],
    "sc-status" => ["[http][response][status_code]", :int],
    "cs(Referer)" => ["[http][request][referrer]", :str],
    "cs(User-Agent)" => ["[user_agent][original]", :urldecode],
    "cs-protocol" => ["[url][scheme]", :str],
    "cs-protocol-version" => ["[http][version]", :http_version],
    "sc-bytes" => ["[http][response][bytes]", :int],
    "cs-bytes" => ["[http][request][bytes]", :int],
    "ssl-protocol" => ["[tls][version]", :tls],
    "ssl-cipher" => ["[tls][cipher]", :str],
    "sc-content-type" => ["[http][response][mime_type]", :str],
    "x-edge-location" => ["[aws][cloudfront][edge_location]", :str],
    "x-edge-request-id" => ["[aws][cloudfront][request_id]", :str],
    "x-edge-result-type" => ["[aws][cloudfront][result_type]", :str],
    "x-edge-response-result-type" => ["[aws][cloudfront][response_result_type]", :str],
    "x-edge-detailed-result-type" => ["[aws][cloudfront][detailed_result_type]", :str],
    "x-forwarded-for" => ["[aws][cloudfront][x_forwarded_for]", :str],
    "cs(Host)" => ["[aws][cloudfront][distribution_domain]", :str],
    "DistributionId" => ["[aws][cloudfront][distribution_id]", :str],
    "time-to-first-byte" => ["[aws][cloudfront][time_to_first_byte]", :float],
    "cache-behavior-path-pattern" => ["[aws][cloudfront][cache_behavior_path_pattern]", :str], # 요청이 걸린 캐시 동작(예: /assets/*)
    # 오리진(S3) 응답의 첫 바이트·마지막 바이트까지 걸린 초. 캐시 적중이면 '-'라 빠진다
    "origin-fbl" => ["[aws][cloudfront][origin_first_byte_latency]", :float],
    "origin-lbl" => ["[aws][cloudfront][origin_last_byte_latency]", :float]
  }
end

def filter(event)
  cf = event.get("[@metadata][cf]")
  return [event] unless cf.is_a?(Hash)
  cf = cf.reject { |k, _| k == "cs(Cookie)" }

  @map.each do |key, (field, kind)|
    value = cf[key]
    next if value.nil? || value == "-" || value == ""
    value = case kind
            when :int then Integer(value.to_s, exception: false)
            when :float then Float(value.to_s, exception: false)
            when :urldecode then URI.decode_www_form_component(value.to_s) rescue value
            when :http_version then value.to_s.sub(%r{\AHTTP/}, "")
            when :tls then (value.to_s =~ /\ATLSv(\d(?:\.\d)?)\z/ ? $1 : value)
            else value.to_s
            end
    event.set(field, value) unless value.nil?
  end
  event.set("[tls][version_protocol]", "tls") if event.get("[tls][version]")

  # 요청 처리 시간(초) → event.duration(나노초)
  taken = Float(cf["time-taken"].to_s, exception: false)
  event.set("[event][duration]", (taken * 1_000_000_000).round) if taken

  # 시각: v2의 timestamp(ms) 또는 timestamp(초), 없으면 date+time(UTC)
  if (ms = Integer(cf["timestamp(ms)"].to_s, exception: false))
    event.set("@timestamp", LogStash::Timestamp.at(ms / 1000, (ms % 1000) * 1000))
  elsif (sec = Float(cf["timestamp"].to_s, exception: false))
    event.set("@timestamp", LogStash::Timestamp.at(sec))
  elsif cf["date"] && cf["time"]
    event.set("@timestamp", LogStash::Timestamp.new(Time.strptime("#{cf['date']} #{cf['time']} UTC", "%Y-%m-%d %H:%M:%S %Z")))
  end

  status = event.get("[http][response][status_code]")
  level = if status.nil? then "unknown"
          elsif status >= 500 then "error"
          elsif status >= 400 then "warn"
          else "info" # 000(응답 전에 사용자가 끊음) 포함
          end
  event.set("[log][level]", level)

  query = event.get("[url][query]")
  event.set("message", [event.get("[http][request][method]"), [event.get("[url][path]"), query].compact.join("?"), status].compact.join(" "))
  event.set("[event][original]", JSON.generate(cf))
  [event]
end
