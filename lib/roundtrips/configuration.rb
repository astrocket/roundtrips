module Roundtrips
  class Configuration
    # 패널을 넣지도, 기록하지도 않는 경로. 정적 파일과 웹소켓은 기본으로 뺀다.
    DEFAULT_IGNORED_PATHS = [
      %r{\A/(vite-dev|vite-test|assets|packs|cable|rails/active_storage)(/|\z)}
    ].freeze

    # 호출 위치에서 건너뛸 앱 코드 경로. 여기만 지나는 호출은 "고칠 곳" 이 아니다.
    DEFAULT_IGNORED_FRAMES = [
      %r{\Aconfig/}
    ].freeze

    # false 면 Railtie 가 미들웨어를 붙이지 않는다. 기본은 ROUNDTRIPS=0 이 아니면 켠다.
    attr_accessor :enabled
    attr_reader :ignored_paths, :ignored_frames

    def initialize
      @enabled = ENV["ROUNDTRIPS"] != "0"
      @ignored_paths = DEFAULT_IGNORED_PATHS.dup
      @ignored_frames = DEFAULT_IGNORED_FRAMES.dup
    end
  end
end
