require "digest"
require "erb"
require "fileutils"
require "json"
require "securerandom"

module Roundtrips
  # 개발 환경 전용. 요청마다 실행된 PostgreSQL 쿼리, Redis 명령, Rails 캐시 호출을 모아 페이지 아래쪽 패널로 보여 준다.
  # Railtie 가 development 에서만 미들웨어로 붙인다. ROUNDTRIPS=0 으로 서버를 띄우면 꺼진다.
  #
  # 페이지를 그린 요청은 패널에 바로 넣는다. 그 페이지에서 나간 비동기 요청과 Sidekiq 잡은 프로세스가 달라
  # tmp/roundtrips 에 파일로 남기고, 패널이 EVENTS_PATH 로 받아 간다. 어느 페이지 것인지는 page_key 로 묶는다.
  class Panel
    STATE_KEY = :roundtrips_log
    IGNORED_NAMES = %w[SCHEMA TRANSACTION].freeze
    # 터널(ngrok 등)로 연 개발 서버를 외부 사람이 볼 때는 SQL 과 바인드 값을 내보내지 않는다.
    LOCAL_HOST = /\A(localhost|127\.0\.0\.1|\[::1\]|.+\.localhost)\z/
    TEMPLATE_PATH = File.expand_path("panel.html", __dir__)
    MAX_SQL_LENGTH = 4_000
    MAX_BIND_LENGTH = 200
    EVENTS_PATH = "/__roundtrips/events"
    STORE_TTL = 30 * 60 # seconds
    MAX_EVENTS = 50
    PAGE_KEY = /\A\h{32}\z/
    MAX_ARG_LENGTH = 120
    MAX_REDIS_ARGS = 6
    MAX_FRAMES = 8
    # cache_generate 는 블록 안의 SQL 시간까지 포함하고, cache_fetch_hit 는 앞선 read 의 뒤처리라서 뺀다.
    CACHE_EVENT = /\Acache_(read|read_multi|write|write_multi|delete|delete_multi|exist\?|increment|decrement)\.active_support\z/
    REDIS_CACHE_FRAME = "active_support/cache/redis_cache_store"

    Query = Struct.new(:source, :name, :sql, :binds, :ms, :offset_ms, :cached, :frames, :shape, :hit, :via_cache, :identity, keyword_init: true) do
      # 앱 코드 밖의 호출은 nil 이다. 표시 문구는 패널이 언어에 맞춰 채운다.
      def location = frames.first&.sub(/:in .*/, "")
      def select? = sql.match?(/\A\s*(SELECT|WITH)\b/i)
      def exact_key = [source, name, identity || sql, binds]
      def fingerprint = shape || Panel.fingerprint(sql)

      # 앱 코드 밖의 호출(Rack::Attack 등)은 고칠 곳이 없고, 캐시를 거친 Redis 명령은 캐시 줄에서 판정한다.
      def repeat_checked?
        return false if frames.empty? || via_cache

        case source
        when "pg" then select?
        when "cache" then !name.include?("write") # miss 뒤의 write 는 같은 문제를 두 번 세게 된다
        else true
        end
      end
    end

    # redis-client 는 Sidekiq, Rails 캐시, Redis.new 가 모두 지나가는 길목이다.
    module RedisRecorder
      def call(command, redis_config)
        Panel.record_redis([command], redis_config) { super }
      end

      def call_pipelined(commands, redis_config)
        Panel.record_redis(commands, redis_config) { super }
      end
    end

    # 요청에서 넣은 잡이 어느 페이지의 어느 요청에서, 어느 줄로 들어왔는지 잡 데이터에 실어 보낸다.
    class SidekiqClientRecorder
      def call(_job_class, job, _queue, _redis_pool)
        log = Panel.current_log
        if log&.page_key
          job["roundtrips_page"] = log.page_key
          job["roundtrips_parent"] = log.id
          job["roundtrips_origin"] = Panel.app_frames(caller).first&.sub(/:in .*/, "")
        end
        yield
      end
    end

    class SidekiqServerRecorder
      def call(_job_instance, job, _queue, &block)
        Panel.trace_job(job, &block)
      end
    end

    Log = Struct.new(:queries, :started_at, :store_touched, :page_key, :wall_ms, :id) do
      def elapsed_ms = Panel.now_ms - started_at
    end

    class << self
      def now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      def wall_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      def store_dir = Rails.root.join("tmp/roundtrips")

      # 브라우저의 Referer 와 맞출 수 있게 경로와 쿼리만으로 만든다.
      def page_key_for(url)
        uri = URI.parse(url.to_s)
        Digest::MD5.hexdigest([uri.path, uri.query].compact.join("?"))
      rescue URI::InvalidURIError
        nil
      end

      def new_log(page_key) = Log.new([], now_ms, nil, page_key, wall_ms, SecureRandom.hex(8))

      def with_log(log)
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = log
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = nil
      end

      def trace_job(job)
        page_key = job["roundtrips_page"]
        return yield unless page_key.to_s.match?(PAGE_KEY)

        log = new_log(page_key)
        status = "done"
        begin
          with_log(log) { yield }
        rescue Exception # rubocop:disable Lint/RescueException
          status = "failed"
          raise
        ensure
          store(log, kind: "job", label: job["wrapped"] || job["class"], status: status,
                     parent: job["roundtrips_parent"], origin: job["roundtrips_origin"])
        end
      end

      def store(log, kind:, label:, status:, parent: nil, origin: nil)
        return unless log.page_key

        payload = payload_for(log, path: label, total_ms: log.elapsed_ms)
                  .merge(id: log.id, kind: kind, label: label, status: status, parent: parent, origin: origin)
        dir = store_dir
        FileUtils.mkdir_p(dir)
        name = "#{log.page_key}-#{log.wall_ms}-#{payload[:id]}.json"
        File.write(dir.join("#{name}.tmp"), JSON.generate(payload))
        File.rename(dir.join("#{name}.tmp"), dir.join(name))
        prune(dir)
      end

      def events(page_key, after)
        paths = Dir.glob(store_dir.join("#{page_key}-*.json").to_s).filter_map do |path|
          started = File.basename(path).split("-")[1].to_i
          [started, path] if started >= after
        end

        paths.sort.last(MAX_EVENTS).filter_map do |started, path|
          JSON.parse(File.read(path)).merge("started_wall_ms" => started)
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end
      end

      def prune(dir)
        limit = Time.now - STORE_TTL
        Dir.glob(dir.join("*.json*").to_s).each { |path| File.delete(path) if File.mtime(path) < limit }
      rescue Errno::ENOENT
        nil
      end

      def subscribe!
        return if @subscribed

        @subscribed = true
        if defined?(Sidekiq)
          Sidekiq.configure_client { |config| config.client_middleware { |chain| chain.add SidekiqClientRecorder } }
          Sidekiq.configure_server do |config|
            config.client_middleware { |chain| chain.add SidekiqClientRecorder }
            config.server_middleware { |chain| chain.add SidekiqServerRecorder }
          end
        end
        ActiveSupport::Notifications.subscribe("sql.active_record") { |event| record(event) }
        ActiveSupport::Notifications.subscribe(CACHE_EVENT) { |event| record_cache(event) }
        RedisClient.register(RedisRecorder) if defined?(RedisClient)
      end

      def current_log = ActiveSupport::IsolatedExecutionState[STATE_KEY]

      def record(event)
        log = current_log
        return unless log

        payload = event.payload
        return if IGNORED_NAMES.include?(payload[:name])

        log.queries << Query.new(
          source: "pg",
          name: payload[:name].presence || "SQL",
          sql: clean_text(payload[:sql], MAX_SQL_LENGTH),
          binds: bind_values(payload),
          ms: event.duration,
          offset_ms: [log.elapsed_ms - event.duration, 0].max,
          cached: payload[:cached] == true,
          frames: app_frames(caller)
        )
      end

      def record_cache(event)
        log = current_log
        return unless log

        payload = event.payload
        operation = event.name.delete_prefix("cache_").delete_suffix(".active_support")
        operation = "fetch" if payload[:super_operation] == :fetch
        keys = cache_keys(payload[:key])
        hit = cache_hit(payload, keys)
        # Rails 는 요청 안에서 읽은 값을 메모리에 들고 있다. 저장소까지 안 갔으면 쿼리 캐시처럼 왕복이 없는 호출이다.
        in_memory = hit == "hit" && !log.store_touched
        log.store_touched = false

        log.queries << Query.new(
          source: "cache",
          name: "cache #{operation}",
          sql: clean_text(keys.size > 1 ? "×#{keys.size}: #{keys.first(3).join(", ")}" : keys.first, MAX_SQL_LENGTH),
          binds: [],
          ms: event.duration,
          offset_ms: [log.elapsed_ms - event.duration, 0].max,
          cached: in_memory,
          frames: app_frames(caller),
          shape: "#{operation} #{shape_of(keys.first)}",
          hit: hit
        )
      end

      def record_redis(commands, redis_config)
        log = current_log
        return yield unless log

        started_at = now_ms
        begin
          yield
        ensure
          ms = now_ms - started_at
          backtrace = caller
          via_cache = backtrace.any? { |frame| frame.include?(REDIS_CACHE_FRAME) }
          log.store_touched = true if via_cache
          log.queries << Query.new(
            source: "redis",
            name: redis_name(commands, redis_config),
            sql: clean_text(commands.map { |command| redis_text(command) }.join("; "), MAX_SQL_LENGTH),
            binds: [],
            ms: ms,
            offset_ms: started_at - log.started_at,
            cached: false,
            frames: app_frames(backtrace),
            shape: commands.map { |command| redis_shape(command) }.join("; "),
            # 표시용 sql 은 잘려 있어 값이 다른 명령도 같아 보인다.
            identity: Digest::MD5.hexdigest(commands.inspect),
            via_cache: via_cache
          )
        end
      end

      def app_frames(backtrace)
        ignored = Roundtrips.config.ignored_frames
        Rails.backtrace_cleaner.clean(backtrace).reject { |frame| ignored.any? { |pattern| frame.match?(pattern) } }.first(MAX_FRAMES)
      end

      # 키의 숫자와 해시만 다른 호출을 같은 모양으로 묶는다.
      def shape_of(key)
        key.to_s.gsub(/\b[0-9a-f]{8,}\b/i, "?").gsub(/\d+/, "?")
      end

      # 값만 다른 쿼리를 같은 모양으로 묶는다.
      def fingerprint(sql)
        sql.gsub(/'(?:[^']|'')*'/, "?")
           .gsub(/\$\d+/, "?")
           .gsub(/\b\d+(\.\d+)?\b/, "?")
           .gsub(/\bIN\s*\((?:\s*\?\s*,?)+\)/i, "IN (?)")
           .squeeze(" ")
           .strip
      end

      # 같은 호출 경로에서 같은 모양의 호출이 값만 바꿔 반복되면 N+1 이다.
      # 값까지 같으면 N+1 이 아니라 중복으로 구분한다.
      def analyze(queries)
        exact_counts = queries.reject { |query| query.cached || query.via_cache }.map(&:exact_key).tally

        groups = queries.group_by { |query| [query.source, query.fingerprint, query.frames] }.values.map do |members|
          executed = members.reject(&:cached)
          kind = if executed.size >= 2 && members.first.repeat_checked? && executed.map(&:exact_key).uniq.size >= 2
                   "n_plus_one"
                 elsif executed.any? { |query| exact_counts.fetch(query.exact_key, 0) >= 2 }
                   "duplicate"
                 else
                   "normal"
                 end

          { kind: kind, members: members }
        end

        rank = { "n_plus_one" => 0, "duplicate" => 1, "normal" => 2 }
        groups.sort_by { |group| [rank[group[:kind]], -group[:members].sum(&:ms)] }
      end

      def payload_for(log, path:, total_ms:)
        groups = analyze(log.queries)
        group_of = {}
        groups.each_with_index { |group, index| group[:members].each { |query| group_of[query.object_id] = index } }
        by_source = log.queries.reject(&:cached).group_by(&:source)
        in_memory = log.queries.select(&:cached)
        cache_calls = by_source.fetch("cache", [])

        {
          path: path,
          total_ms: total_ms.round(1),
          sources: %w[pg redis cache].to_h do |source|
            calls = by_source.fetch(source, [])
            [source, { count: calls.size, ms: calls.sum(&:ms).round(1) }]
          end,
          cache_store: Rails.cache.class.name.demodulize,
          cache_hits: cache_calls.count { |query| query.hit == "hit" },
          cache_misses: cache_calls.count { |query| query.hit == "miss" },
          cached_count: in_memory.count { |query| query.source == "pg" },
          in_memory_count: in_memory.count { |query| query.source == "cache" },
          n_plus_one_count: groups.count { |group| group[:kind] == "n_plus_one" },
          duplicate_count: groups.count { |group| group[:kind] == "duplicate" },
          groups: groups.map { |group| group_json(group) },
          queries: log.queries.map { |query| query_json(query, group_of[query.object_id], groups) }
        }
      end

      private

      def group_json(group)
        members = group[:members]
        first = members.first

        {
          kind: group[:kind],
          source: first.source,
          # 잡 묶음을 브라우저에서 합칠 때 쓴다.
          shape: first.fingerprint,
          signature: Digest::MD5.hexdigest(first.exact_key.inspect),
          judged: first.repeat_checked?,
          first_binds: first.binds,
          name: first.name,
          sql: first.sql,
          literal_sql: literal_sql(first),
          location: first.location,
          frames: first.frames,
          count: members.count { |query| !query.cached },
          cached_count: members.count(&:cached),
          total_ms: members.sum(&:ms).round(2),
          max_ms: members.map(&:ms).max.round(2),
          hits: members.reject(&:cached).filter_map(&:hit).tally,
          via_cache: first.via_cache == true,
          bind_samples: varying_binds(members)
        }
      end

      # LIMIT 처럼 매번 같은 값은 빼고 실제로 달라진 값만 보여 준다.
      def varying_binds(members)
        rows = members.map(&:binds).uniq
        positions = (0...rows.map(&:size).max.to_i).select { |index| rows.map { |binds| binds[index] }.uniq.size > 1 }

        rows.first(10).map { |binds| binds.values_at(*positions) }
      end

      def query_json(query, group_index, groups)
        {
          group: group_index,
          kind: groups[group_index][:kind],
          source: query.source,
          name: query.name,
          sql: query.sql,
          literal_sql: literal_sql(query),
          location: query.location,
          frames: query.frames,
          ms: query.ms.round(2),
          offset_ms: query.offset_ms.round(2),
          cached: query.cached,
          hit: query.hit,
          via_cache: query.via_cache == true
        }
      end

      # 콘솔에 붙여 넣어 볼 수 있게 바인드 값을 채운 SQL.
      def literal_sql(query)
        return query.sql unless query.source == "pg"

        query.sql.gsub(/\$(\d+)/) do |placeholder|
          value = query.binds[Regexp.last_match(1).to_i - 1]
          next placeholder if value.nil? && query.binds.size < Regexp.last_match(1).to_i

          case value
          when nil then "NULL"
          when Numeric, true, false then value.to_s
          else "'#{value.to_s.gsub("'", "''")}'"
          end
        end
      end

      def cache_keys(key)
        (key.is_a?(Hash) ? key.keys : Array(key)).map(&:to_s)
      end

      def cache_hit(payload, keys)
        return payload[:hit] ? "hit" : "miss" if payload.key?(:hit)
        return "#{payload[:hits].size}/#{keys.size} hit" if payload[:hits]

        nil
      end

      def redis_name(commands, redis_config)
        name = commands.size > 1 ? "PIPELINE ×#{commands.size}" : commands.first.first.to_s.upcase
        "#{name} db#{redis_config.db}"
      end

      def redis_text(command)
        name, *args = command.map { |arg| redis_arg(arg) }
        extra = args.size - MAX_REDIS_ARGS

        [name.upcase, *args.first(MAX_REDIS_ARGS), (extra.positive? ? "…(+#{extra})" : nil)].compact.join(" ")
      end

      # 캐시 값은 압축·직렬화된 바이너리라 글자로 보여도 뜻이 없다.
      def redis_arg(arg)
        text = arg.to_s.dup.force_encoding(Encoding::UTF_8)
        return "<#{text.bytesize}B>" if !text.valid_encoding? || text.match?(/[\x00-\x08\x0e-\x1f]/)

        clean_text(text, MAX_ARG_LENGTH)
      end

      # 값이 아니라 명령과 키로 묶는다.
      def redis_shape(command)
        "#{command.first.to_s.upcase} #{shape_of(command[1])}"
      end

      def bind_values(payload)
        binds = payload[:type_casted_binds]
        binds = binds.call if binds.respond_to?(:call)

        Array(binds).map do |value|
          case value
          when nil, Numeric, true, false then value
          when binary?(value) then "<binary>"
          else clean_text(value.to_s, MAX_BIND_LENGTH)
          end
        end
      end

      def binary?(value)
        defined?(ActiveModel::Type::Binary::Data) && value.is_a?(ActiveModel::Type::Binary::Data)
      end

      def clean_text(text, limit)
        cleaned = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
        cleaned.length > limit ? "#{cleaned[0, limit]}…" : cleaned
      end
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      return events_response(env) if env["PATH_INFO"] == EVENTS_PATH
      return @app.call(env) unless watch?(env)

      document = document_request?(env)
      # 304 로 끝나면 패널 없는 이전 화면이 남으므로 조건부 요청을 지운다.
      %w[HTTP_IF_NONE_MATCH HTTP_IF_MODIFIED_SINCE].each { |header| env.delete(header) } if document

      request = Rack::Request.new(env)
      log = self.class.new_log(self.class.page_key_for(document ? request.fullpath : env["HTTP_REFERER"]))

      self.class.with_log(log) do
        status, headers, body = @app.call(env)
        response = document ? inject(status, headers, body, log, request) : nil
        next response if response

        self.class.store(log, kind: "request", label: "#{request.request_method} #{request.fullpath}", status: status) if env["HTTP_REFERER"].present?
        [status, headers, body]
      end
    end

    private

    def local?(env)
      Rack::Request.new(env).host.to_s.match?(LOCAL_HOST)
    end

    def watch?(env)
      path = env["PATH_INFO"].to_s
      Roundtrips.config.ignored_paths.none? { |pattern| path.match?(pattern) } && local?(env)
    end

    def document_request?(env)
      return false unless env["REQUEST_METHOD"] == "GET"
      return false if env["HTTP_TURBO_FRAME"].present? || env["HTTP_X_REQUESTED_WITH"] == "XMLHttpRequest"

      fetch_dest = env["HTTP_SEC_FETCH_DEST"]
      fetch_dest.blank? || fetch_dest == "document" || env["HTTP_ACCEPT"].to_s.include?("text/html")
    end

    def events_response(env)
      return [404, { "content-type" => "text/plain" }, ["Not Found"]] unless local?(env)

      params = Rack::Utils.parse_query(env["QUERY_STRING"])
      return [400, { "content-type" => "text/plain" }, ["Bad Request"]] unless params["page"].to_s.match?(PAGE_KEY)

      [200, { "content-type" => "application/json", "cache-control" => "no-store" }, [JSON.generate(self.class.events(params["page"], params["after"].to_i))]]
    end

    # 패널을 넣었으면 응답을, 넣을 수 없는 응답이면 nil 을 돌려준다.
    def inject(status, headers, body, log, request)
      return unless injectable?(status, headers, body)

      parts = []
      body.each { |part| parts << part }
      body.close if body.respond_to?(:close)

      html = parts.join.force_encoding(Encoding::UTF_8)
      position = html.rindex("</body>")
      return [status, headers, [html]] unless position

      payload = self.class.payload_for(log, path: request.fullpath, total_ms: log.elapsed_ms).merge(
        id: log.id, kind: "page", label: request.fullpath, status: status,
        page_key: log.page_key, started_wall_ms: log.wall_ms, events_path: EVENTS_PATH,
        locale: Roundtrips.config.locale
      )
      html = html.dup.insert(position, panel_html(payload))
      headers["content-length"] = html.bytesize.to_s if headers.key?("content-length")

      [status, headers, [html]]
    end

    def injectable?(status, headers, body)
      status < 500 &&
        headers["content-type"].to_s.start_with?("text/html") &&
        body.respond_to?(:each) &&
        !body.respond_to?(:to_path)
    end

    def panel_html(payload)
      File.read(TEMPLATE_PATH, encoding: "UTF-8").sub("__ROUNDTRIPS_DATA__") { ERB::Util.json_escape(JSON.generate(payload)) }
    end
  end
end
