# roundtrips

Rails 개발 환경에서 페이지를 열면 왼쪽 아래에 배지가 뜨고, 그 요청이 저장소에 다녀온 **왕복**을 모두 보여 줍니다.

- PostgreSQL 쿼리, Redis 명령, Rails 캐시 호출을 코드 위치(`파일:줄`)와 함께 모읍니다.
- 같은 호출 경로에서 값만 바뀌어 반복되면 `N+1`, 값까지 같으면 `중복`으로 표시합니다.
- 그 페이지에서 나간 비동기 요청(Turbo Frame, fetch, 폼 제출)과 Sidekiq 잡도 페이지 아래로 묶어 보여 줍니다.
- 줄마다 `복사` 버튼이 있어 SQL, 바뀐 값, 호출 경로를 프롬프트에 붙여 넣기 좋은 형태로 복사합니다.

화면 문구는 한국어입니다.

## 설치

```ruby
# Gemfile
group :development do
  gem "roundtrips", github: "astrocket/roundtrips", tag: "v0.1.0"
end
```

`bundle install` 뒤 서버를 다시 띄우면 됩니다. development 에서만 미들웨어가 붙고, 다른 환경에서는 아무것도 하지 않습니다.

끄려면 `ROUNDTRIPS=0 bin/dev` 처럼 띄웁니다.

## 설정

```ruby
# config/initializers/roundtrips.rb
if defined?(Roundtrips)
  Roundtrips.configure do |config|
    # 패널을 넣지 않을 경로(스크린샷을 찍는 화면 등)
    config.ignored_paths << %r{/captures(/|\z)}
    # 호출 위치에서 건너뛸 코드(요청마다 지나는 미들웨어 등)
    config.ignored_frames << %r{\Aapp/middleware/}
  end
end
```

기본값은 다음과 같습니다.

| 설정 | 기본값 |
|---|---|
| `ignored_paths` | `/vite-dev`, `/vite-test`, `/assets`, `/packs`, `/cable`, `/rails/active_storage` |
| `ignored_frames` | `config/` |
| `enabled` | `ROUNDTRIPS=0` 이 아니면 `true` |

## 동작 방식

- `sql.active_record` 이벤트와 `cache_*.active_support` 이벤트를 구독하고, `RedisClient.register` 로 Redis 명령을 기록합니다. redis-client 를 쓰는 Sidekiq, Rails 캐시, `Redis.new` 가 모두 여기를 지납니다.
- 페이지를 그린 요청은 응답 HTML 의 `</body>` 앞에 패널을 넣습니다.
- 비동기 요청과 Sidekiq 잡은 프로세스가 달라 `tmp/roundtrips` 에 파일로 남기고, 패널이 `/__roundtrips/events` 로 받아 갑니다. 30분 지난 기록은 지웁니다.
- 잡은 Sidekiq 클라이언트 미들웨어가 넣은 요청과 위치를 잡 데이터(`roundtrips_*`)에 실어 보내 페이지 아래로 묶습니다.

## 안전장치

- `localhost`, `127.0.0.1`, `*.localhost` 로 들어온 요청에만 패널을 넣습니다. 터널(ngrok 등)로 연 개발 서버를 외부 사람이 볼 때는 SQL 과 바인드 값을 내보내지 않습니다.
- 500 응답, HTML 이 아닌 응답, 파일 응답은 건드리지 않습니다.
- 조건부 요청 헤더를 지워 304 로 패널 없는 화면이 남지 않게 합니다.

## 한계

- 값을 채운 SQL(`literal_sql`)은 PostgreSQL 의 `$1` 바인드만 채웁니다.
- Sidekiq 잡 묶음은 Sidekiq 을 쓸 때만 동작합니다. ActiveJob 의 다른 어댑터는 기록하지 않습니다.

## 개발

```sh
bundle install
bundle exec rspec
```

앱에서 고치며 보려면 앱 쪽에서 로컬 경로를 씁니다.

```sh
bundle config local.roundtrips ../roundtrips
```

## 라이선스

MIT
