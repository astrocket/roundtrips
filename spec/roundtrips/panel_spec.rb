require "spec_helper"

RSpec.describe Roundtrips::Panel do
  def query(sql: 'SELECT "uses".* FROM "uses" WHERE "uses"."id" = $1', binds: [1], cached: false, frames: ["app/views/a.erb:1"], ms: 1.0)
    described_class::Query.new(source: "pg", name: "Use Load", sql: sql, binds: binds, ms: ms, offset_ms: 0, cached: cached, frames: frames)
  end

  def redis_call(key, frames: ["app/lib/a.rb:1"], via_cache: false)
    described_class::Query.new(source: "redis", name: "GET db0", sql: "GET #{key}", binds: [], ms: 1.0, offset_ms: 0, cached: false,
                               frames: frames, shape: "GET #{described_class.shape_of(key)}", via_cache: via_cache)
  end

  def cache_call(key, frames: ["app/lib/a.rb:1"], hit: "miss", name: "cache read", cached: false)
    described_class::Query.new(source: "cache", name: name, sql: key, binds: [], ms: 1.0, offset_ms: 0, cached: cached,
                               frames: frames, shape: "#{name} #{described_class.shape_of(key)}", hit: hit)
  end

  def kinds(*queries)
    described_class.analyze(queries).map { |group| group[:kind] }
  end

  describe ".fingerprint" do
    it "값과 IN 목록 길이가 달라도 같은 모양으로 본다" do
      expect(described_class.fingerprint("SELECT * FROM a WHERE id IN (1, 2, 3) AND name = 'x'"))
        .to eq(described_class.fingerprint("SELECT * FROM a WHERE id IN (4) AND name = 'it''s'"))
    end
  end

  describe ".analyze" do
    it "같은 호출 경로에서 값만 바뀌는 SELECT 는 N+1 이다" do
      expect(kinds(query(binds: [1]), query(binds: [2]))).to eq(["n_plus_one"])
    end

    it "값까지 같으면 중복이다" do
      expect(kinds(query, query)).to eq(["duplicate"])
    end

    it "호출 경로가 다르면 N+1 로 묶지 않는다" do
      expect(kinds(query(binds: [1]), query(binds: [2], frames: ["app/views/b.erb:9"]))).to eq(%w[normal normal])
    end

    it "쿼리 캐시로 끝난 반복은 N+1 이 아니다" do
      expect(kinds(query(binds: [1]), query(binds: [2], cached: true))).to eq(["normal"])
    end

    it "SELECT 가 아닌 반복은 N+1 로 보지 않는다" do
      sql = 'UPDATE "uses" SET "n" = $1'
      expect(kinds(query(sql: sql, binds: [1]), query(sql: sql, binds: [2]))).to eq(["normal"])
    end

    it "같은 위치에서 키만 바뀌는 Redis 명령은 N+1 이다" do
      expect(kinds(redis_call("post:1"), redis_call("post:2"))).to eq(["n_plus_one"])
    end

    it "같은 위치에서 키만 바뀌는 캐시 호출은 N+1 이다" do
      expect(kinds(cache_call("views/post/1"), cache_call("views/post/2"))).to eq(["n_plus_one"])
    end

    it "같은 키를 두 번 읽는 캐시 호출은 중복이다" do
      expect(kinds(cache_call("views/post/1"), cache_call("views/post/1"))).to eq(["duplicate"])
    end

    it "miss 뒤의 write 는 같은 키라도 중복이 아니다" do
      expect(kinds(cache_call("post/1"), cache_call("post/1", name: "cache write", hit: nil))).to eq(%w[normal normal])
    end

    it "반복되는 cache write 는 N+1 로 세지 않는다" do
      writes = %w[post/1 post/2].map { |key| cache_call(key, name: "cache write", hit: nil) }

      expect(kinds(*writes)).to eq(["normal"])
    end

    it "요청 메모리로 끝난 캐시 호출은 N+1 이 아니다" do
      expect(kinds(cache_call("post/1", hit: "hit", cached: true), cache_call("post/2", hit: "hit", cached: true))).to eq(["normal"])
    end

    it "캐시를 거친 Redis 명령은 N+1 로 세지 않아 한 문제가 두 번 잡히지 않는다" do
      queries = [
        cache_call("post/1"), cache_call("post/2"),
        redis_call("post/1", via_cache: true), redis_call("post/2", via_cache: true)
      ]

      expect(described_class.analyze(queries).map { |group| [group[:members].first.source, group[:kind]] })
        .to contain_exactly(["cache", "n_plus_one"], ["redis", "normal"])
    end

    it "앱 코드 밖에서 반복된 Redis 명령은 고칠 곳이 없어 N+1 로 보지 않는다" do
      expect(kinds(redis_call("throttle:1", frames: []), redis_call("throttle:2", frames: []))).to eq(["normal"])
    end

    it "PostgreSQL 과 Redis 는 모양이 같아도 묶지 않는다" do
      sql = described_class::Query.new(source: "pg", name: "SQL", sql: "GET post:1", binds: [], ms: 1, offset_ms: 0, cached: false, frames: ["app/lib/a.rb:1"], shape: "GET post:?")

      expect(described_class.analyze([sql, redis_call("post:2")]).size).to eq(2)
    end

    it "저장소별 건수와 캐시 적중을 따로 센다" do
      log = described_class::Log.new([query, redis_call("a"), cache_call("b", hit: "hit"), cache_call("c", hit: "miss")], 0)
      payload = described_class.payload_for(log, path: "/", total_ms: 1)

      expect(payload[:sources].transform_values { |source| source[:count] }).to eq("pg" => 1, "redis" => 1, "cache" => 2)
      expect(payload.values_at(:cache_hits, :cache_misses)).to eq([1, 1])
    end

    it "패널에는 매번 같은 값을 빼고 달라진 값만 넘긴다" do
      log = described_class::Log.new([query(binds: [5, 1]), query(binds: [6, 1])], 0)

      expect(described_class.payload_for(log, path: "/", total_ms: 1)[:groups].first[:bind_samples]).to eq([[5], [6]])
    end

    it "N+1 을 가장 위에 둔다" do
      slow = query(sql: 'SELECT "x".* FROM "x"', binds: [], frames: ["app/x.rb:1"], ms: 500)
      groups = described_class.analyze([slow, query(binds: [1]), query(binds: [2])])

      expect(groups.first[:kind]).to eq("n_plus_one")
    end
  end

  describe "미들웨어" do
    def run(host: "localhost", content_type: "text/html; charset=utf-8", body: "<html><body>본문</body></html>", env: {})
      app = lambda do |_env|
        ActiveSupport::Notifications.instrument("sql.active_record", name: "Use Load", sql: 'SELECT "a" FROM "b" WHERE "c" = \'</script><img>\'', type_casted_binds: [])
        [200, { "content-type" => content_type, "content-length" => body.bytesize.to_s }, [body]]
      end

      described_class.subscribe!
      status, headers, response = described_class.new(app).call(Rack::MockRequest.env_for("http://#{host}/page", env))
      [status, headers, response.to_enum(:each).to_a.join]
    end

    it "HTML 응답의 body 끝에 패널을 넣고 content-length 를 맞춘다" do
      _status, headers, html = run

      expect(html).to include("roundtrips-data")
      expect(html.index("roundtrips-host")).to be < html.rindex("</body>")
      expect(headers["content-length"].to_i).to eq(html.bytesize)
    end

    it "쿼리 안의 script 닫는 태그가 페이지를 깨지 않게 이스케이프한다" do
      expect(run.last).not_to include("</script><img>")
    end

    it "요청 안의 Rails 캐시 호출과 Redis 명령을 소스별로 모은다" do
      described_class.subscribe!
      log = described_class::Log.new([], described_class.now_ms)
      ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY] = log
      config = instance_double(RedisClient::Config, db: 2)

      ActiveSupport::Notifications.instrument("cache_read.active_support", key: "post/1", hit: true, super_operation: :fetch)
      described_class.record_redis([["GET", "post:1"]], config) { "값" }
      described_class.record_redis([["SET", "a", "1"], ["SET", "b", "2"]], config) { "OK" }

      expect(log.queries.map { |item| [item.source, item.name, item.sql, item.hit] }).to eq([
        ["cache", "cache fetch", "post/1", "hit"],
        ["redis", "GET db2", "GET post:1", nil],
        ["redis", "PIPELINE ×2 db2", "SET a 1; SET b 2", nil]
      ])
    ensure
      ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY] = nil
    end

    it "저장소에 가지 않은 캐시 hit 은 요청 메모리로, 간 것은 저장소 hit 으로 구분한다" do
      described_class.subscribe!
      log = described_class::Log.new([], described_class.now_ms)
      ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY] = log

      ActiveSupport::Notifications.instrument("cache_read.active_support", key: "memory", hit: true)
      log.store_touched = true
      ActiveSupport::Notifications.instrument("cache_read.active_support", key: "store", hit: true)

      expect(log.queries.map(&:cached)).to eq([true, false])
    ensure
      ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY] = nil
    end

    it "표시용으로 잘린 부분만 다른 Redis 명령도 N+1 로 본다" do
      described_class.subscribe!
      log = described_class::Log.new([], described_class.now_ms)
      config = instance_double(RedisClient::Config, db: 1)
      payloads = ["#{"a" * 200}1", "#{"a" * 200}2"]

      described_class.with_log(log) do
        payloads.each { |payload| described_class.record_redis([["LPUSH", "queue:default", payload]], config) { 1 } }
      end
      log.queries.each { |query| query.frames = ["app/lib/a.rb:1"] }

      expect(described_class.analyze(log.queries).map { |group| group[:kind] }).to eq(["n_plus_one"])
    end

    it "바이너리 값은 크기만 보여 준다" do
      described_class.subscribe!
      log = described_class::Log.new([], described_class.now_ms)
      ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY] = log

      described_class.record_redis([["SET", "post:1", "\x00\xFFabc".b]], instance_double(RedisClient::Config, db: 1)) { "OK" }

      expect(log.queries.first.sql).to eq("SET post:1 <5B>")
    ensure
      ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY] = nil
    end

    it "요청 밖의 Redis 명령은 기록 없이 그대로 실행한다" do
      expect(described_class.record_redis([["GET", "a"]], nil) { "값" }).to eq("값")
    end

    context "비동기 요청과 잡" do
      around do |example|
        Dir.mktmpdir do |dir|
          @dir = Pathname(dir)
          example.run
        end
      end

      before do
        described_class.subscribe!
        allow(described_class).to receive(:store_dir) { @dir }
      end

      let(:page_key) { described_class.page_key_for("/posts/abc") }

      def request_with(env, status: 200, content_type: "text/vnd.turbo-stream.html", path: "/posts/abc/likes", method: "POST")
        app = lambda do |_env|
          ActiveSupport::Notifications.instrument("sql.active_record", name: "Post Load", sql: 'SELECT "posts".* FROM "posts"', type_casted_binds: [])
          [status, { "content-type" => content_type }, ["<turbo-stream></turbo-stream>"]]
        end

        described_class.new(app).call(Rack::MockRequest.env_for("http://localhost#{path}", { method: method }.merge(env)))
      end

      it "Turbo 요청을 Referer 페이지 아래에 남긴다" do
        request_with({ "HTTP_REFERER" => "http://localhost:3400/posts/abc", "HTTP_ACCEPT" => "text/vnd.turbo-stream.html" })

        event = described_class.events(page_key, 0).sole
        expect(event).to include("kind" => "request", "label" => "POST /posts/abc/likes", "status" => 200)
        expect(event.dig("sources", "pg", "count")).to eq(1)
      end

      it "fetch 로 온 HTML 조각에는 패널을 넣지 않고 기록만 남긴다" do
        _status, _headers, body = request_with(
          { "HTTP_REFERER" => "http://localhost/posts/abc", "HTTP_SEC_FETCH_DEST" => "empty", "HTTP_ACCEPT" => "*/*" },
          content_type: "text/html", path: "/posts/abc/comments", method: "GET"
        )

        expect(body.to_enum(:each).to_a.join).not_to include("roundtrips")
        expect(described_class.events(page_key, 0).size).to eq(1)
      end

      it "Referer 가 없는 요청은 남기지 않는다" do
        request_with({})

        expect(Dir.children(@dir)).to be_empty
      end

      it "요청이 넣은 잡에 페이지 표식을 싣고, 잡의 호출을 그 페이지 아래에 남긴다" do
        job = { "class" => "Wrapper", "wrapped" => "NotifyJob" }
        described_class.with_log(described_class.new_log(page_key)) { described_class::SidekiqClientRecorder.new.call("Wrapper", job, "default", nil) { "넣음" } }

        described_class::SidekiqServerRecorder.new.call(nil, job, "default") do
          ActiveSupport::Notifications.instrument("sql.active_record", name: "Post Load", sql: 'SELECT "posts".* FROM "posts"', type_casted_binds: [])
        end

        event = described_class.events(page_key, 0).sole
        expect(event).to include("kind" => "job", "label" => "NotifyJob", "status" => "완료")
        expect(event.dig("sources", "pg", "count")).to eq(1)
      end

      it "같은 요청이 넣은 잡끼리 묶을 수 있게 요청과 넣은 위치를 남긴다" do
        log = described_class.new_log(page_key)
        jobs = Array.new(2) { { "class" => "Wrapper", "wrapped" => "NotifyJob" } }
        allow(described_class).to receive(:app_frames).and_return(["app/controllers/a_controller.rb:148:in 'create'"])

        described_class.with_log(log) do
          jobs.each { |job| described_class::SidekiqClientRecorder.new.call("Wrapper", job, "default", nil) { "넣음" } }
        end
        jobs.each { |job| described_class::SidekiqServerRecorder.new.call(nil, job, "default") { "실행" } }

        events = described_class.events(page_key, 0)
        expect(events.map { |event| event.values_at("parent", "origin") }.uniq).to eq([[log.id, "app/controllers/a_controller.rb:148"]])
      end

      it "다른 잡을 합칠 때 쓸 묶음 정보를 내보낸다" do
        log = described_class::Log.new([query(binds: [5, 1])], 0)
        group = described_class.payload_for(log, path: "/", total_ms: 1)[:groups].first

        expect(group).to include(judged: true, first_binds: [5, 1])
        expect(group[:shape]).to include("WHERE")
        expect(group[:signature]).to match(/\A\h{32}\z/)
      end

      it "잡이 실패해도 그때까지의 호출을 남기고 예외는 그대로 올린다" do
        job = { "class" => "Wrapper", "roundtrips_page" => page_key }

        expect { described_class::SidekiqServerRecorder.new.call(nil, job, "default") { raise "터짐" } }.to raise_error("터짐")
        expect(described_class.events(page_key, 0).sole).to include("status" => "실패")
      end

      it "페이지 표식이 없는 잡은 기록 없이 그대로 실행한다" do
        expect(described_class::SidekiqServerRecorder.new.call(nil, { "class" => "Cron" }, "default") { "결과" }).to eq("결과")
        expect(Dir.children(@dir)).to be_empty
      end

      it "기준 시각 이전 기록은 돌려주지 않는다" do
        request_with({ "HTTP_REFERER" => "http://localhost/posts/abc" })

        expect(described_class.events(page_key, described_class.wall_ms + 60_000)).to be_empty
      end

      it "받아 가는 주소는 잘못된 페이지 표식과 외부 주소를 막는다" do
        panel = described_class.new(->(_env) { [200, {}, []] })
        bad = panel.call(Rack::MockRequest.env_for("http://localhost#{described_class::EVENTS_PATH}?page=../../secret*"))
        remote = panel.call(Rack::MockRequest.env_for("http://29ab.ngrok-free.app#{described_class::EVENTS_PATH}?page=#{page_key}"))

        expect([bad.first, remote.first]).to eq([400, 404])
      end
    end

    it "HTML 이 아닌 응답은 건드리지 않는다" do
      expect(run(content_type: "application/json", body: "{}").last).to eq("{}")
    end

    it "localhost 가 아닌 주소로 들어오면 쿼리를 내보내지 않는다" do
      expect(run(host: "29ab.ngrok-free.app").last).not_to include("roundtrips")
    end

    it "조건부 요청 헤더를 지워 304 로 끝나지 않게 한다" do
      seen = nil
      app = lambda do |env|
        seen = env.values_at("HTTP_IF_NONE_MATCH", "HTTP_IF_MODIFIED_SINCE")
        [200, { "content-type" => "text/html" }, ["<body></body>"]]
      end

      described_class.new(app).call(Rack::MockRequest.env_for("http://localhost/", "HTTP_IF_MODIFIED_SINCE" => "어제"))

      expect(seen).to eq([nil, nil])
    end
  end
end
