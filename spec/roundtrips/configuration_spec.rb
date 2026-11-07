RSpec.describe Roundtrips::Configuration do
  around do |example|
    original = Roundtrips.instance_variable_get(:@config)
    Roundtrips.instance_variable_set(:@config, nil)
    example.run
  ensure
    Roundtrips.instance_variable_set(:@config, original)
  end

  def call(path, frames_app: nil)
    app = frames_app || ->(_env) { [200, { "content-type" => "text/html" }, ["<body></body>"]] }
    Roundtrips::Panel.new(app).call(Rack::MockRequest.env_for("http://localhost#{path}")).last.to_enum(:each).to_a.join
  end

  it "앱이 더한 경로에는 패널을 넣지 않는다" do
    Roundtrips.configure { |config| config.ignored_paths << %r{/captures(/|\z)} }

    expect(call("/posts/1/captures")).not_to include("roundtrips-data")
    expect(call("/posts/1")).to include("roundtrips-data")
  end

  it "기본으로 정적 파일 경로는 건너뛴다" do
    expect(call("/assets/app.css")).not_to include("roundtrips-data")
  end

  it "앱이 더한 코드 경로는 호출 위치에서 뺀다" do
    Roundtrips.configure { |config| config.ignored_frames << %r{\Aapp/middleware/} }
    allow(Rails.backtrace_cleaner).to receive(:clean).and_return(["app/middleware/a.rb:1", "app/models/post.rb:2"])

    expect(Roundtrips::Panel.app_frames([])).to eq(["app/models/post.rb:2"])
  end

  describe "#locale" do
    around do |example|
      locales = I18n.available_locales
      original = I18n.default_locale
      example.run
    ensure
      I18n.available_locales = locales
      I18n.default_locale = original
    end

    it "앱의 기본 언어가 ko 면 한국어, 그 밖에는 영어다" do
      I18n.available_locales = %i[en ko ja]
      I18n.default_locale = :ko
      expect(described_class.new.locale).to eq("ko")

      I18n.default_locale = :ja
      expect(described_class.new.locale).to eq("en")
    end

    it "정한 언어를 따르고, 없는 언어는 영어로 돌린다" do
      config = described_class.new
      config.locale = :ko
      expect(config.locale).to eq("ko")

      config.locale = :fr
      expect(config.locale).to eq("en")
    end

    it "패널 데이터에 언어를 싣는다" do
      Roundtrips.configure { |config| config.locale = :ko }

      expect(call("/posts/1")).to include('"locale":"ko"')
    end
  end

  it "ROUNDTRIPS=0 이면 끈다" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ROUNDTRIPS").and_return("0")

    expect(described_class.new.enabled).to be(false)
  end
end
