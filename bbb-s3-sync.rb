#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8
#
# bbb-s3-sync — Idempotent BigBlueButton → Amazon S3 recording asset sync.
#
# Source of truth: local BBB published filesystem.
# Syncs video, notes, podcast, screenshare, presentation, and statistics.
# Video Lesson keys stay flat (video-0.m4v, notes.pdf). Format metadata and
# presentation/statistics trees keep a relative path under the recording id.

# Phase 1: upload missing objects. Phase 2: delete S3 orphans.
#
# Intended install path on BBB host: /usr/local/bin/bbb-s3-sync
# Does not depend on Moodle.
#
# Configuration via environment variables (no hardcoded credentials):
#   BBB_S3_BUCKET       (required)
#   BBB_S3_REGION       (required)
#   BBB_S3_PREFIX       (default: bbb-recordings)
#   BBB_PUBLISHED_ROOT  (default: /var/bigbluebutton/published)
#   BBB_S3_LOG          (default: /var/log/bigbluebutton/bbb-s3-sync.log)
#   AWS credentials via IAM role, AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, or shared config.
#
# Usage:
#   bbb-s3-sync [--dry-run] [--skip-delete] [--upload-limit=N] [--recording-limit=N] [--help]
#
# First-run backfill example:
#   bbb-s3-sync --skip-delete --upload-limit=50

require "optparse"
require "logger"
require "set"
require "fileutils"
require "pathname"

module BbbS3Sync
  VERSION = "1.0.0"

  CONTENT_TYPES = {
    ".m4v" => "video/x-m4v",
    ".mp4" => "video/mp4",
    ".webm" => "video/webm",
    ".ogg" => "audio/ogg",
    ".mp3" => "audio/mpeg",
    ".pdf" => "application/pdf",
    ".xml" => "application/xml",
    ".svg" => "image/svg+xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".json" => "application/json",
    ".vtt" => "text/vtt",
    ".html" => "text/html",
    ".txt" => "text/plain",
  }.freeze

  PUBLISHED_FORMATS = %w[video notes podcast screenshare presentation statistics].freeze
  TREE_FORMATS = %w[presentation statistics].freeze
  # metadata.xml for these formats is stored as <format>/metadata.xml, not flattened.
  NAMESPACED_METADATA_FORMATS = %w[video notes podcast screenshare].freeze

  # Flat media at prefix/<id>/<basename>. Video Lesson depends on video-0.m4v and notes.pdf.
  VIDEO_BASENAME_RE = /\Avideo(-\d+)?\.(m4v|mp4)\z/i.freeze
  PODCAST_BASENAME_RE = /\Aaudio\.(ogg|webm|mp3)\z/i.freeze
  SCREENSHARE_BASENAME_RE = /\A(?:deskshare|screenshare)\.(webm|mp4)\z/i.freeze
  NAMESPACED_METADATA_RE = %r{\A(?:video|notes|podcast|screenshare)/metadata\.xml\z}i.freeze
  TREE_PREFIX_RE = %r{\A(?:presentation|statistics)/}i.freeze

  FLAT_MEDIA = {
    "video" => VIDEO_BASENAME_RE,
    "notes" => /\Anotes\.pdf\z/i,
    "podcast" => PODCAST_BASENAME_RE,
    "screenshare" => SCREENSHARE_BASENAME_RE,
  }.freeze

  # Relative path under the recording id (may contain slashes).
  # recording.zip is left unmanaged so download archives are not deleted.
  def self.managed_asset_relpath?(rel)
    rel = rel.to_s
    return false if rel.empty? || rel.include?("..") || rel.start_with?("/")
    return false if File.basename(rel) == "recording.zip"
    return true if rel == "notes.pdf" || rel.match?(VIDEO_BASENAME_RE)
    return true if rel.match?(PODCAST_BASENAME_RE) || rel.match?(SCREENSHARE_BASENAME_RE)
    return true if rel.match?(NAMESPACED_METADATA_RE)
    return true if rel.match?(TREE_PREFIX_RE)
    false
  end

  def self.skip_published_file?(relative)
    parts = relative.to_s.split("/")
    return true if parts.empty?
    parts.any? { |seg| seg.empty? || seg == "." || seg == ".." || seg.start_with?(".") || seg.end_with?(".tmp") }
  end

  MAX_RETRIES = 3
  RETRY_BASE_SLEEP = 1.0

  # Load KEY=value from /etc/default/bbb-s3-sync (does not overwrite existing ENV).
  def self.load_env_file!(path = ENV["BBB_S3_ENV_FILE"] || "/etc/default/bbb-s3-sync")
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

  def self.require_aws_sdk!
    require "aws-sdk-s3"
  rescue LoadError
    warn "FATAL: aws-sdk-s3 gem is required. Install with: gem install aws-sdk-s3"
    exit 1
  end

  def self.retryable_error?(error)
    return true if defined?(Aws::S3::Errors::SlowDown) && error.is_a?(Aws::S3::Errors::SlowDown)
    return true if defined?(Aws::S3::Errors::RequestTimeout) && error.is_a?(Aws::S3::Errors::RequestTimeout)
    return true if defined?(Aws::S3::Errors::InternalError) && error.is_a?(Aws::S3::Errors::InternalError)
    return true if defined?(Aws::S3::Errors::ServiceUnavailable) && error.is_a?(Aws::S3::Errors::ServiceUnavailable)
    return true if defined?(Seahorse::Client::NetworkingError) && error.is_a?(Seahorse::Client::NetworkingError)
    false
  end

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------
  class Config
    attr_reader :bucket, :region, :prefix, :published_root, :log_path,
                :dry_run, :upload_limit, :recording_limit, :skip_delete

    def initialize(dry_run: false, upload_limit: nil, recording_limit: nil, skip_delete: false)
      BbbS3Sync.load_env_file!
      @bucket = ENV["BBB_S3_BUCKET"].to_s.strip
      @region = ENV["BBB_S3_REGION"].to_s.strip
      @prefix = ENV.fetch("BBB_S3_PREFIX", "bbb-recordings").to_s.strip.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      @published_root = ENV.fetch("BBB_PUBLISHED_ROOT", "/var/bigbluebutton/published").to_s.strip
      @log_path = ENV.fetch("BBB_S3_LOG", "/var/log/bigbluebutton/bbb-s3-sync.log").to_s.strip
      @dry_run = dry_run
      @upload_limit = upload_limit
      @recording_limit = recording_limit
      @skip_delete = skip_delete
    end

    def validate!
      errors = []
      errors << "BBB_S3_BUCKET is required" if @bucket.empty?
      errors << "BBB_S3_REGION is required" if @region.empty?
      errors << "Published root does not exist: #{@published_root}" unless File.directory?(@published_root)
      errors << "--upload-limit must be a positive integer" if !@upload_limit.nil? && @upload_limit < 1
      errors << "--recording-limit must be a positive integer" if !@recording_limit.nil? && @recording_limit < 1
      raise ArgumentError, errors.join("; ") unless errors.empty?
    end

    def format_root(format)
      File.join(@published_root, format)
    end

    def s3_key(recording_id, basename)
      [@prefix, recording_id, basename].reject(&:empty?).join("/")
    end
  end

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------
  def self.build_logger(log_path)
    FileUtils.mkdir_p(File.dirname(log_path)) rescue nil

    outputs = []
    begin
      outputs << File.open(log_path, "a")
    rescue StandardError => e
      warn "WARN: cannot open log file #{log_path}: #{e.message} (logging to STDOUT only)"
    end
    outputs << $stdout

    logger = Logger.new(MultiIO.new(*outputs))
    logger.level = Logger::INFO
    logger.formatter = proc do |severity, datetime, _progname, msg|
      "#{datetime.utc.strftime('%Y-%m-%d %H:%M:%S UTC')} #{severity}: #{msg}\n"
    end
    logger
  end

  class MultiIO
    def initialize(*targets)
      @targets = targets
    end

    def write(*args)
      @targets.each { |t| t.write(*args) }
    end

    def close
      @targets.each { |t| t.close unless t == $stdout || t == $stderr }
    end
  end

  # ---------------------------------------------------------------------------
  # BBB published recordings (filesystem)
  # ---------------------------------------------------------------------------
  class BbbRecordings
    Asset = Struct.new(:local_path, :s3_rel, keyword_init: true)
    Recording = Struct.new(:id, :assets, keyword_init: true)

    def initialize(config, logger)
      @config = config
      @logger = logger
    end

    # Returns Hash recording_id => Recording
    def all
      ids = Set.new
      PUBLISHED_FORMATS.each do |format|
        ids.merge(dir_names(@config.format_root(format)))
      end

      recordings = {}
      ids.each do |id|
        assets = collect_assets(id)
        if assets.empty?
          @logger.warn("Recording #{id}: no managed published files found locally")
        end
        recordings[id] = Recording.new(id: id, assets: assets)
      end
      recordings
    end

    private

    def dir_names(root)
      return [] unless File.directory?(root)

      Dir.children(root).select do |name|
        next false if name.start_with?(".")
        File.directory?(File.join(root, name))
      end
    rescue StandardError => e
      @logger.error("BBB lookup failed under #{root}: #{e.class}: #{e.message}")
      []
    end

    def collect_assets(recording_id)
      assets = []
      NAMESPACED_METADATA_FORMATS.each do |format|
        assets.concat(flat_format_assets(recording_id, format))
      end
      TREE_FORMATS.each do |format|
        assets.concat(tree_assets(recording_id, format))
      end
      assets.uniq { |asset| asset.s3_rel }
    end

    # Media basenames stay at the recording root. metadata.xml is namespaced.
    def flat_format_assets(recording_id, format)
      dir = File.join(@config.format_root(format), recording_id)
      return [] unless File.directory?(dir)

      media_re = FLAT_MEDIA.fetch(format)
      assets = []
      each_published_file(dir) do |path, rel|
        base = File.basename(rel)
        if base.match?(media_re)
          assets << Asset.new(local_path: path, s3_rel: base)
        elsif rel == "metadata.xml"
          assets << Asset.new(local_path: path, s3_rel: "#{format}/metadata.xml")
        end
      end
      assets
    end

    def tree_assets(recording_id, format)
      dir = File.join(@config.format_root(format), recording_id)
      return [] unless File.directory?(dir)

      assets = []
      each_published_file(dir) do |path, rel|
        assets << Asset.new(local_path: path, s3_rel: "#{format}/#{rel}")
      end
      assets
    end

    def each_published_file(dir)
      Dir.glob(File.join(dir, "**", "*")).sort.each do |path|
        next unless File.file?(path)
        rel = Pathname.new(path).relative_path_from(Pathname.new(dir)).to_s
        next if BbbS3Sync.skip_published_file?(rel)
        yield path, rel
      end
    rescue StandardError => e
      @logger.error("BBB file walk failed under #{dir}: #{e.class}: #{e.message}")
    end
  end

  # ---------------------------------------------------------------------------
  # S3 store
  # ---------------------------------------------------------------------------
  class S3Store
    def initialize(config, logger)
      @config = config
      @logger = logger
      @client = Aws::S3::Client.new(region: @config.region)
      @keys = Set.new
    end

    def load_existing_keys!
      prefix = @config.prefix.empty? ? "" : "#{@config.prefix}/"
      @logger.info("Listing S3 objects under s3://#{@config.bucket}/#{prefix}")
      token = nil
      count = 0
      loop do
        resp = with_retries("list_objects_v2") do
          params = {
            bucket: @config.bucket,
            prefix: prefix,
            max_keys: 1000,
          }
          params[:continuation_token] = token if token
          @client.list_objects_v2(params)
        end

        (resp.contents || []).each do |obj|
          @keys << obj.key
          count += 1
        end

        break unless resp.is_truncated
        token = resp.next_continuation_token
      end
      @logger.info("Found #{count} existing S3 object(s) under prefix")
      @keys
    end

    def existing_keys
      @keys
    end

    def exists?(key)
      @keys.include?(key)
    end

    def upload_file(local_path, key)
      content_type = CONTENT_TYPES[File.extname(local_path).downcase] || "application/octet-stream"
      if @config.dry_run
        @logger.info("[dry-run] Would upload #{local_path} -> s3://#{@config.bucket}/#{key}")
        return true
      end

      with_retries("put_object #{key}") do
        File.open(local_path, "rb") do |file|
          @client.put_object(
            bucket: @config.bucket,
            key: key,
            body: file,
            content_type: content_type,
          )
        end
      end
      @keys << key
      @logger.info("Uploaded: s3://#{@config.bucket}/#{key} (#{File.basename(local_path)})")
      true
    rescue StandardError => e
      @logger.error("AWS upload failed for #{key}: #{e.class}: #{e.message}")
      false
    end

    def delete_key(key, reason: "orphan")
      if @config.dry_run
        @logger.info("[dry-run] Would delete #{reason} s3://#{@config.bucket}/#{key}")
        return true
      end

      with_retries("delete_object #{key}") do
        @client.delete_object(bucket: @config.bucket, key: key)
      end
      @keys.delete(key)
      @logger.info("Deleted #{reason}: s3://#{@config.bucket}/#{key}")
      true
    rescue StandardError => e
      @logger.error("AWS delete failed for #{key}: #{e.class}: #{e.message}")
      false
    end

    # Recording IDs currently represented in S3 under the configured prefix.
    def recording_ids_in_s3
      ids = Set.new
      prefix = @config.prefix.empty? ? "" : "#{@config.prefix}/"
      @keys.each do |key|
        relative = prefix.empty? ? key : key.sub(/\A#{Regexp.escape(prefix)}/, "")
        parts = relative.split("/")
        next if parts.size < 2
        rel = parts[1..].join("/")
        next unless BbbS3Sync.managed_asset_relpath?(rel)
        ids << parts[0]
      end
      ids
    end

    # Managed asset keys for a recording. recording.zip is not managed.
    def asset_keys_for(recording_id)
      prefix = @config.prefix.empty? ? "" : "#{@config.prefix}/"
      base = "#{prefix}#{recording_id}/"
      @keys.select do |key|
        next false unless key.start_with?(base)
        rel = key[base.length..]
        next false if rel.nil? || rel.empty?
        BbbS3Sync.managed_asset_relpath?(rel)
      end
    end

    private

    def with_retries(label)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue StandardError => e
        raise unless BbbS3Sync.retryable_error?(e)
        if attempt <= MAX_RETRIES
          sleep_time = RETRY_BASE_SLEEP * (2**(attempt - 1))
          @logger.warn("Transient AWS error on #{label} (attempt #{attempt}/#{MAX_RETRIES}): #{e.class}: #{e.message}; retrying in #{sleep_time}s")
          sleep sleep_time
          retry
        end
        raise
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Sync runner
  # ---------------------------------------------------------------------------
  class SyncRunner
    def initialize(config, logger)
      @config = config
      @logger = logger
      @stats = {
        recordings: 0,
        uploaded: 0,
        skipped: 0,
        missing_local: 0,
        deleted: 0,
        upload_failures: 0,
        delete_failures: 0,
        recording_errors: 0,
        upload_limit_hit: false,
        recording_limit_hit: false,
        deferred_uploads: 0,
      }
    end

    def run!
      @logger.info("=" * 60)
      @logger.info(
        "bbb-s3-sync v#{VERSION} starting " \
        "(dry_run=#{@config.dry_run} upload_limit=#{@config.upload_limit.inspect} " \
        "recording_limit=#{@config.recording_limit.inspect} skip_delete=#{@config.skip_delete})"
      )
      @logger.info("bucket=#{@config.bucket} region=#{@config.region} prefix=#{@config.prefix.inspect}")
      @logger.info("published_root=#{@config.published_root}")

      store = S3Store.new(@config, @logger)
      store.load_existing_keys!

      recordings = BbbRecordings.new(@config, @logger).all
      @stats[:recordings] = recordings.size
      @logger.info("BBB published recordings found: #{recordings.size}")

      # Always enumerate all local IDs so orphan delete stays correct even when upload limits apply.
      local_ids = recordings.keys.to_set

      phase1_upload(recordings, store)

      if @config.skip_delete
        @logger.info("--- Phase 2: skipped (--skip-delete) ---")
      else
        phase2_delete_orphans(local_ids, recordings, store)
      end

      log_summary
      @logger.info("bbb-s3-sync finished")
      0
    end

    private

    def phase1_upload(recordings, store)
      @logger.info("--- Phase 1: upload missing files ---")
      recordings_uploaded = 0

      recordings.each_value do |rec|
        missing = missing_asset_count(rec, store)
        if missing.zero?
          # Still walk assets for skip logging / missing-video warnings.
          sync_recording(rec, store)
          next
        end

        if upload_limit_reached? || recording_limit_reached?(recordings_uploaded)
          @stats[:upload_limit_hit] = true if upload_limit_reached?
          @stats[:recording_limit_hit] = true if recording_limit_reached?(recordings_uploaded)
          defer_remaining_assets(rec, store)
          next
        end

        before = @stats[:uploaded]
        sync_recording(rec, store)
        recordings_uploaded += 1 if @stats[:uploaded] > before || @stats[:upload_failures].positive?
      rescue StandardError => e
        @stats[:recording_errors] += 1
        @logger.error("Recording #{rec.id} failed: #{e.class}: #{e.message}")
      end

      if @stats[:upload_limit_hit] && @config.upload_limit
        @logger.info("Upload limit reached (#{@config.upload_limit}); deferred #{@stats[:deferred_uploads]} missing file(s) to a later run")
      end
      if @stats[:recording_limit_hit] && @config.recording_limit
        @logger.info("Recording upload limit reached (#{@config.recording_limit}); remaining recordings deferred")
      end
    end

    def upload_limit_reached?
      return false if @config.upload_limit.nil?
      @stats[:uploaded] >= @config.upload_limit
    end

    def recording_limit_reached?(recordings_uploaded)
      return false if @config.recording_limit.nil?
      recordings_uploaded >= @config.recording_limit
    end

    def missing_asset_count(rec, store)
      rec.assets.count { |asset| !store.exists?(@config.s3_key(rec.id, asset.s3_rel)) }
    end

    def defer_remaining_assets(rec, store)
      each_asset(rec) do |_local_path, s3_rel|
        key = @config.s3_key(rec.id, s3_rel)
        if store.exists?(key)
          @stats[:skipped] += 1
        else
          @stats[:deferred_uploads] += 1
          @logger.info("Deferred (limit): s3://#{@config.bucket}/#{key}")
        end
      end
    end

    def each_asset(rec)
      if rec.assets.empty?
        @stats[:missing_local] += 1
        return
      end
      rec.assets.each do |asset|
        yield asset.local_path, asset.s3_rel
      end
    end

    def sync_recording(rec, store)
      each_asset(rec) do |local_path, s3_rel|
        if upload_limit_reached?
          @stats[:upload_limit_hit] = true
          key = @config.s3_key(rec.id, s3_rel)
          if store.exists?(key)
            @stats[:skipped] += 1
          else
            @stats[:deferred_uploads] += 1
            @logger.info("Deferred (limit): s3://#{@config.bucket}/#{key}")
          end
          next
        end

        key = @config.s3_key(rec.id, s3_rel)
        if store.exists?(key)
          @stats[:skipped] += 1
          @logger.info("Skip (already in S3): s3://#{@config.bucket}/#{key}")
          next
        end

        if store.upload_file(local_path, key)
          @stats[:uploaded] += 1
        else
          @stats[:upload_failures] += 1
        end
      end
    end

    def phase2_delete_orphans(local_ids, recordings, store)
      @logger.info("--- Phase 2: delete orphaned S3 files ---")
      s3_ids = store.recording_ids_in_s3
      orphans = s3_ids - local_ids
      @logger.info("S3 recording IDs: #{s3_ids.size}; local: #{local_ids.size}; orphans: #{orphans.size}")

      orphans.each do |id|
        keys = store.asset_keys_for(id)
        if keys.empty?
          @logger.warn("Orphan recording #{id}: no managed asset keys found (skipped)")
          next
        end
        delete_managed_keys(id, keys, store, reason: "orphan")
      end

      local_ids.each do |id|
        rec = recordings[id]
        next unless rec
        desired = rec.assets.map { |asset| @config.s3_key(id, asset.s3_rel) }.to_set
        stale = store.asset_keys_for(id).reject { |key| desired.include?(key) }
        delete_managed_keys(id, stale, store, reason: "stale")
      end
    end

    def delete_managed_keys(recording_id, keys, store, reason:)
      return if keys.empty?

      removed = 0
      keys.each do |key|
        if store.delete_key(key, reason: reason)
          @stats[:deleted] += 1
          removed += 1
        else
          @stats[:delete_failures] += 1
        end
      end
      @logger.info("Recording #{recording_id}: cleaned #{removed} #{reason} asset(s)")
    rescue StandardError => e
      @stats[:recording_errors] += 1
      @logger.error("#{reason.capitalize} cleanup for #{recording_id} failed: #{e.class}: #{e.message}")
    end

    def log_summary
      @logger.info("--- Summary ---")
      @logger.info(
        "recordings=#{@stats[:recordings]} " \
        "uploaded=#{@stats[:uploaded]} skipped=#{@stats[:skipped]} " \
        "deferred_uploads=#{@stats[:deferred_uploads]} " \
        "missing_local=#{@stats[:missing_local]} " \
        "deleted=#{@stats[:deleted]} " \
        "upload_failures=#{@stats[:upload_failures]} " \
        "delete_failures=#{@stats[:delete_failures]} " \
        "recording_errors=#{@stats[:recording_errors]}"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # CLI
  # ---------------------------------------------------------------------------
  def self.parse_argv!(argv)
    options = {
      dry_run: false,
      skip_delete: false,
      upload_limit: nil,
      recording_limit: nil,
    }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: bbb-s3-sync [options]"
      opts.on("--dry-run", "Log actions without uploading or deleting") { options[:dry_run] = true }
      opts.on("--skip-delete", "Skip Phase 2 orphan deletes (useful on first backfill)") { options[:skip_delete] = true }
      opts.on("--upload-limit=N", Integer, "Max files to upload this run (full scan still runs)") do |n|
        options[:upload_limit] = n
      end
      opts.on("--recording-limit=N", Integer, "Max recordings that may receive uploads this run") do |n|
        options[:recording_limit] = n
      end
      opts.on("-h", "--help", "Show help") do
        puts opts
        puts <<~HELP

          Limits (for first-run backfill; safe with orphan delete):
            --upload-limit=50       Upload at most 50 missing files, then defer the rest
            --recording-limit=25    Upload for at most 25 recordings that need work
            --skip-delete           Do not delete S3 orphans this run

          Local + S3 enumeration always covers all recordings so orphan detection stays correct.

          Synced per recording id:
            video-*.m4v/mp4, notes.pdf, audio.ogg/webm/mp3, deskshare/screenshare.webm/mp4
            <format>/metadata.xml for video, notes, podcast, screenshare
            presentation/ and statistics/ trees (relative paths)
            recording.zip is never uploaded or deleted by this script

          Environment:
            BBB_S3_BUCKET       Required. S3 bucket name.
            BBB_S3_REGION       Required. AWS region.
            BBB_S3_PREFIX       Optional. Key prefix (default: bbb-recordings).
            BBB_PUBLISHED_ROOT  Optional. Default: /var/bigbluebutton/published
            BBB_S3_LOG          Optional. Default: /var/log/bigbluebutton/bbb-s3-sync.log

          AWS credentials: IAM instance role, env vars, or shared credentials file.

          First-run example:
            bbb-s3-sync --skip-delete --upload-limit=50
        HELP
        exit 0
      end
      opts.on("-v", "--version", "Show version") do
        puts "bbb-s3-sync #{VERSION}"
        exit 0
      end
    end
    parser.parse!(argv)
    options
  end

  def self.main(argv = ARGV)
    options = parse_argv!(argv)
    config = Config.new(
      dry_run: options[:dry_run],
      upload_limit: options[:upload_limit],
      recording_limit: options[:recording_limit],
      skip_delete: options[:skip_delete]
    )

    begin
      config.validate!
    rescue ArgumentError => e
      warn "FATAL: #{e.message}"
      return 1
    end

    require_aws_sdk!
    logger = build_logger(config.log_path)

    begin
      SyncRunner.new(config, logger).run!
    rescue Aws::Errors::MissingCredentialsError => e
      logger.error("FATAL: AWS credentials not found: #{e.message}")
      return 1
    rescue Aws::S3::Errors::ServiceError => e
      logger.error("FATAL: AWS S3 error during init: #{e.class}: #{e.message}")
      return 1
    rescue StandardError => e
      logger.error("FATAL: #{e.class}: #{e.message}")
      logger.error(e.backtrace.first(10).join("\n")) if e.backtrace
      return 1
    end
  end
end

exit BbbS3Sync.main(ARGV) if $PROGRAM_NAME == __FILE__
