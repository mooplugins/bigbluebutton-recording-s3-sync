#!/usr/bin/env ruby
# encoding: UTF-8
#
# BigBlueButton post_publish script — uploads published recording formats to S3.
#
# Repo: scripts/bbb-s3-sync/1_sendtos3.rb
#
# Install on BBB host:
#   /usr/local/bigbluebutton/core/scripts/post_publish/1_sendtos3.rb
#   chmod 755 1_sendtos3.rb
#   chown bigbluebutton:bigbluebutton 1_sendtos3.rb
#
# Same env file as bbb-s3-sync: /etc/default/bbb-s3-sync
#   BBB_S3_BUCKET, BBB_S3_REGION, BBB_S3_PREFIX, BBB_PUBLISHED_ROOT,
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#   BBB_S3_LOG (or BBB_S3_POST_PUBLISH_LOG), BBB_S3_PREFIX_EXTERNAL
#
# Uses Ruby stdlib SigV4 PutObject (needs access keys in ENV; IAM role alone is not enough).
# Needs: optimist (BBB), openssl/net/http/digest (stdlib).
#
# BBB invokes once per published format (-m meeting_id -f format).
# video, notes, podcast, screenshare, presentation, and statistics are uploaded.
# Other formats exit 0. Key layout matches bbb-s3-sync.rb.

def boot_log(msg)
  $stderr.puts "#{Time.now.utc} BOOT: #{msg}"
rescue StandardError
  nil
end

def load_bbb_s3_env!(path = ENV["BBB_S3_ENV_FILE"] || "/etc/default/bbb-s3-sync")
  return false unless File.readable?(path)

  File.foreach(path) do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    next unless line.include?("=")

    key, val = line.split("=", 2)
    key = key.to_s.strip
    next if key.empty?

    val = val.to_s.strip
    if (m = val.match(/\A(['"])(.*)\1\z/))
      val = m[2]
    end
    ENV[key] = val if ENV[key].to_s.empty?
  end
  true
end

boot_log("START pid=#{Process.pid} argv=#{ARGV.inspect}")
load_bbb_s3_env!
boot_log("env file=/etc/default/bbb-s3-sync loaded=#{File.readable?(ENV['BBB_S3_ENV_FILE'] || '/etc/default/bbb-s3-sync')}")

DISABLED = ENV.fetch("BBB_S3_POST_PUBLISH_DISABLED", "false").to_s.strip.downcase == "true"
if DISABLED
  boot_log("DISABLED via BBB_S3_POST_PUBLISH_DISABLED — exiting without upload")
  exit 0
end

begin
  require "optimist"
  require "logger"
  require "openssl"
  require "digest"
  require "net/http"
  require "uri"
  require "time"
  require "fileutils"
  require "pathname"
  boot_log("loaded libraries")
rescue LoadError => e
  boot_log("REQUIRE FAILED: #{e.class}: #{e.message}")
  exit 1
end

BUCKET_NAME = ENV["BBB_S3_BUCKET"].to_s.strip
AWS_REGION = ENV["BBB_S3_REGION"].to_s.strip
AWS_ACCESS_KEY_ID = (ENV["AWS_ACCESS_KEY_ID"] || ENV["BBB_S3_ACCESS_KEY_ID"]).to_s.strip
AWS_SECRET_ACCESS_KEY = (ENV["AWS_SECRET_ACCESS_KEY"] || ENV["BBB_S3_SECRET_ACCESS_KEY"]).to_s.strip
AWS_SESSION_TOKEN = ENV["AWS_SESSION_TOKEN"].to_s.strip
S3_PREFIX = ENV.fetch("BBB_S3_PREFIX", "bbb-recordings").to_s.strip.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
PREFIX_EXTERNAL_MEETING_ID = ENV.fetch("BBB_S3_PREFIX_EXTERNAL", "false").to_s.strip.downcase == "true"
PUBLISHED_ROOT = ENV.fetch("BBB_PUBLISHED_ROOT", "/var/bigbluebutton/published").to_s.strip
LOG_FILE = ENV["BBB_S3_POST_PUBLISH_LOG"].to_s.strip
LOG_FILE = ENV.fetch("BBB_S3_LOG", "/var/log/bigbluebutton/sendtos3.log") if LOG_FILE.empty?

TREE_FORMATS = %w[presentation statistics].freeze
FLAT_MEDIA = {
  "video" => /\Avideo(-\d+)?\.(m4v|mp4)\z/i,
  "notes" => /\Anotes\.pdf\z/i,
  "podcast" => /\Aaudio\.(ogg|webm|mp3)\z/i,
  "screenshare" => /\A(?:deskshare|screenshare)\.(webm|mp4)\z/i,
}.freeze
UPLOAD_FORMATS = (FLAT_MEDIA.keys + TREE_FORMATS).freeze

CONTENT_TYPES = {
  ".m4v"  => "video/x-m4v",
  ".mp4"  => "video/mp4",
  ".webm" => "video/webm",
  ".ogg"  => "audio/ogg",
  ".mp3"  => "audio/mpeg",
  ".pdf"  => "application/pdf",
  ".xml"  => "application/xml",
  ".svg"  => "image/svg+xml",
  ".png"  => "image/png",
  ".jpg"  => "image/jpeg",
  ".jpeg" => "image/jpeg",
  ".json" => "application/json",
  ".vtt"  => "text/vtt",
  ".html" => "text/html",
  ".txt"  => "text/plain",
}.freeze

if BUCKET_NAME.empty? || AWS_REGION.empty?
  boot_log("FATAL: BBB_S3_BUCKET and BBB_S3_REGION are required (see /etc/default/bbb-s3-sync)")
  exit 1
end

def content_type_for(file)
  CONTENT_TYPES[File.extname(file).downcase]
end

def s3_object_key(recording_id, basename)
  [S3_PREFIX, recording_id, basename].reject(&:empty?).join("/")
end

# --- minimal AWS SigV4 S3 PutObject (stdlib only) ---

def hmac(key, data)
  OpenSSL::HMAC.digest("sha256", key, data)
end

def hexsha256(data)
  Digest::SHA256.hexdigest(data)
end

def aws_signing_key(secret, date_stamp, region, service)
  k_date = hmac("AWS4#{secret}", date_stamp)
  k_region = hmac(k_date, region)
  k_service = hmac(k_region, service)
  hmac(k_service, "aws4_request")
end

def uri_encode_s3_key(key)
  key.split("/").map { |seg| URI.encode_www_form_component(seg).gsub("+", "%20") }.join("/")
end

def s3_put_object(file, object_key)
  access_key = AWS_ACCESS_KEY_ID.to_s
  secret_key = AWS_SECRET_ACCESS_KEY.to_s
  if access_key.empty? || secret_key.empty?
    raise "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY not set"
  end

  body = File.binread(file)
  payload_hash = hexsha256(body)
  content_type = content_type_for(file) || "application/octet-stream"

  now = Time.now.utc
  amz_date = now.strftime("%Y%m%dT%H%M%SZ")
  date_stamp = now.strftime("%Y%m%d")
  service = "s3"
  host = "#{BUCKET_NAME}.s3.#{AWS_REGION}.amazonaws.com"
  canonical_uri = "/#{uri_encode_s3_key(object_key)}"

  headers = {
    "content-type" => content_type,
    "host" => host,
    "x-amz-content-sha256" => payload_hash,
    "x-amz-date" => amz_date,
  }
  headers["x-amz-security-token"] = AWS_SESSION_TOKEN unless AWS_SESSION_TOKEN.empty?

  signed_header_names = headers.keys.sort
  canonical_headers = signed_header_names.map { |k| "#{k}:#{headers[k]}" }.join("\n") + "\n"
  signed_headers = signed_header_names.join(";")

  canonical_request = [
    "PUT",
    canonical_uri,
    "",
    canonical_headers,
    signed_headers,
    payload_hash,
  ].join("\n")

  credential_scope = "#{date_stamp}/#{AWS_REGION}/#{service}/aws4_request"
  string_to_sign = [
    "AWS4-HMAC-SHA256",
    amz_date,
    credential_scope,
    hexsha256(canonical_request),
  ].join("\n")

  signature = OpenSSL::HMAC.hexdigest(
    "sha256",
    aws_signing_key(secret_key, date_stamp, AWS_REGION, service),
    string_to_sign
  )

  authorization = [
    "AWS4-HMAC-SHA256 Credential=#{access_key}/#{credential_scope}",
    "SignedHeaders=#{signed_headers}",
    "Signature=#{signature}",
  ].join(", ")

  uri = URI("https://#{host}#{canonical_uri}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 30
  http.read_timeout = 600

  request = Net::HTTP::Put.new(uri)
  request["Content-Type"] = content_type
  request["Host"] = host
  request["X-Amz-Content-Sha256"] = payload_hash
  request["X-Amz-Date"] = amz_date
  request["X-Amz-Security-Token"] = AWS_SESSION_TOKEN unless AWS_SESSION_TOKEN.empty?
  request["Authorization"] = authorization
  request["Content-Length"] = body.bytesize.to_s
  request.body = body

  response = http.request(request)
  code = response.code.to_i
  unless code >= 200 && code < 300
    raise "S3 HTTP #{response.code}: #{response.body.to_s[0, 500]}"
  end
  true
end

def upload_file(file, object_key)
  s3_put_object(file, object_key)
  true
rescue StandardError => e
  LOGGER.error("Failed to upload #{object_key}: #{e.class}: #{e.message}")
  false
end

def skip_published_file?(relative)
  parts = relative.to_s.split("/")
  return true if parts.empty?
  parts.any? { |seg| seg.empty? || seg == "." || seg == ".." || seg.start_with?(".") || seg.end_with?(".tmp") }
end

# S3 path under the recording id. Nil means this file is not uploaded for the format.
# Flat media keeps its basename (video-0.m4v, notes.pdf, …). metadata.xml is namespaced.
# presentation and statistics keep format/<relative path>.
def s3_rel_for(format, published_dir, file)
  rel = Pathname.new(file).relative_path_from(Pathname.new(published_dir)).to_s
  return nil if skip_published_file?(rel)

  return "#{format}/#{rel}" if TREE_FORMATS.include?(format)
  return "#{format}/metadata.xml" if rel == "metadata.xml"

  base = File.basename(rel)
  media_re = FLAT_MEDIA[format]
  return base if media_re && base.match?(media_re)

  nil
end

def files_for_format(published_dir, format)
  Dir.glob("#{published_dir}/**/*").select { |path| File.file?(path) }.sort.map { |path|
    rel = s3_rel_for(format, published_dir, path)
    rel.nil? ? nil : [path, rel]
  }.compact
end

def external_meeting_id_from_events(events_xml)
  return "" unless File.exist?(events_xml)

  chunk = File.read(events_xml, 100_000)
  if (m = chunk.match(/meetingId["\s:=]+["']?([^"'<>\s]+)/i))
    return m[1].to_s
  end
  if (m = chunk.match(/<meetingId>([^<]+)<\/meetingId>/i))
    return m[1].to_s
  end
  ""
rescue StandardError
  ""
end

opts = Optimist.options do
  opt :meeting_id, "Meeting id to archive", type: :string
  opt :format, "Playback format name", type: :string
end

meeting_id = opts[:meeting_id].to_s.strip
format = (opts[:format] || "").to_s.strip
format = "presentation" if format.empty?

begin
  FileUtils.mkdir_p(File.dirname(LOG_FILE))
rescue StandardError
  nil
end

LOGGER = Logger.new(LOG_FILE, "weekly")
LOGGER.level = Logger::INFO
LOGGER.formatter = proc { |severity, datetime, _progname, msg|
  "#{datetime.utc} #{severity}: #{msg}\n"
}

boot_log("running meeting_id=#{meeting_id.inspect} format=#{format.inspect}")

if meeting_id.empty?
  LOGGER.error("Missing --meeting-id / -m")
  exit 1
end

raw_meeting_id = meeting_id.sub(/-(presentation|video|notes|podcast|screenshare|statistics)$/, "")

unless UPLOAD_FORMATS.include?(format)
  LOGGER.info("Skipping format=#{format} for #{raw_meeting_id} (not a synced format)")
  exit 0
end

published_dir = File.join(PUBLISHED_ROOT, format, raw_meeting_id)
published_dir = File.join(PUBLISHED_ROOT, format, meeting_id) unless File.directory?(published_dir)

unless File.directory?(published_dir)
  LOGGER.error("Published directory not found: #{published_dir}")
  exit 1
end

files = files_for_format(published_dir, format)

if files.empty?
  LOGGER.error("No managed files found in #{published_dir}")
  exit 1
end

recording_id = raw_meeting_id
if PREFIX_EXTERNAL_MEETING_ID
  events_xml = "/var/bigbluebutton/recording/raw/#{raw_meeting_id}/events.xml"
  external_id = external_meeting_id_from_events(events_xml)
  if external_id.empty?
    LOGGER.warn("BBB_S3_PREFIX_EXTERNAL=true but could not read meetingId from #{events_xml}")
  else
    recording_id = "#{external_id}/#{raw_meeting_id}"
  end
end

failures = 0
uploaded = 0
uploaded_keys = []

LOGGER.info(
  "S3 upload starting for #{raw_meeting_id} (#{format}) -> " \
  "s3://#{BUCKET_NAME}/#{s3_object_key(recording_id, '')}/ (#{files.size} file(s))"
)

files.each do |file, rel|
  object_key = s3_object_key(recording_id, rel)

  if upload_file(file, object_key)
    uploaded += 1
    uploaded_keys << object_key
    LOGGER.info("Uploaded: s3://#{BUCKET_NAME}/#{object_key} (#{rel})")
  else
    failures += 1
  end
end

if uploaded.zero?
  LOGGER.error("No files uploaded from #{published_dir}")
  exit 1
end

if failures.positive?
  LOGGER.error("S3 upload finished with #{failures} failure(s), #{uploaded} succeeded")
  exit 1
end

LOGGER.info(
  "S3 upload completed for #{raw_meeting_id} (#{format}): #{uploaded} file(s): #{uploaded_keys.join(', ')}"
)
exit 0
