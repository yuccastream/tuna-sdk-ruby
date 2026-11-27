# frozen_string_literal: true

require "minitest/autorun"
require "tuna/sdk"

class SDKTest < Minitest::Test
  SDK = Tuna::SDK

  def server_error(status, body, **kw)
    SDK.parse_response(status, body, **kw)
  rescue SDK::ServerError => e
    e
  end

  def test_dial_target
    assert_equal [:tcp, "127.0.0.1", 8080], SDK.dial_target("127.0.0.1:8080")
    assert_equal [:tcp, "::1", 80], SDK.dial_target("[::1]:80")
    assert_equal [:unix, "/run/app.sock"], SDK.dial_target("unix:///run/app.sock")
    %w[8080 localhost :80 host:port].each do |bad|
      assert_raises(ArgumentError, bad) { SDK.dial_target(bad) }
    end
  end

  def test_json_error
    err = server_error(403, '{"code":"Forbidden","error":"no scope","request_id":"r1"}')
    assert_equal "Forbidden", err.code
    assert_equal "tuna: no scope (request id r1)", err.message
    assert err.permanent?
  end

  def test_permanent_codes
    %w[BadRequest Unauthorized Forbidden NotFound PaymentRequired UpgradeRequired].each do |code|
      assert server_error(400, %({"code":"#{code}","error":"x"})).permanent?, code
    end
    refute server_error(503, '{"code":"ServiceUnavailable","error":"x"}').permanent?
    refute server_error(500, "oops").permanent?
  end

  def test_html_4xx_before_and_after_first_connect
    err = server_error(404, "<html>not found</html>")
    assert_equal "tuna: server responded with status 404", err.message
    refute err.permanent?
    err.before_first_connect!
    assert err.permanent?

    timeout = server_error(429, "slow down")
    timeout.before_first_connect!
    refute timeout.permanent?
  end

  def test_redirect_is_permanent
    err = server_error(301, "", location: "https://elsewhere.example")
    assert err.permanent?
    assert_includes err.message, "https://elsewhere.example"
  end

  def test_retry_after
    assert_equal 3, server_error(503, "{}", retry_after: "3").retry_after
    assert_equal 300, server_error(503, "{}", retry_after: "3600").retry_after
    assert_nil server_error(503, "{}", retry_after: "soon").retry_after
  end

  def test_retry_delay
    fixed = Struct.new(:value) { def rand = value }
    assert_in_delta 1.0, SDK.retry_delay(1.0, nil, rand: fixed.new(0.0))
    assert_in_delta 1.5, SDK.retry_delay(1.0, nil, rand: fixed.new(0.5))
    assert_in_delta 15.0, SDK.retry_delay(15.0, nil, rand: fixed.new(0.99))
    err = server_error(503, "{}", retry_after: "7")
    assert_in_delta 7.0, SDK.retry_delay(1.0, err, rand: fixed.new(0.0))
    100.times do
      wait = SDK.retry_delay(15.0, nil)
      assert wait.between?(1.0, 15.0), wait.to_s
    end
  end

  def test_public_url
    assert_equal "https://a.tuna.am", SDK.public_url({ "public_url" => "https://a.tuna.am", "domain_name" => "b" }, "http")
    assert_equal "https://b.tuna.am", SDK.public_url({ "domain_name" => "b.tuna.am" }, "http")
    assert_equal "tcp://ru.tuna.am:40001", SDK.public_url({ "domain_name" => "ru.tuna.am", "endpoint_port" => 40_001 }, "tcp")
  end

  def test_node_event
    assert_equal [:terminate, "deleted"], SDK.node_event(%({"type":"terminate","reason":"deleted"}\n))
    assert_equal [:session_expiring, 300.0], SDK.node_event(%({"type":"session_expiring","expires_in":300}))
    assert_nil SDK.node_event(%({"type":"pong"}))
    assert_nil SDK.node_event("not json")
    assert_nil SDK.node_event("[]")
  end

  def test_terminated_error
    assert_equal "tuna: tunnel was deleted", SDK::TerminatedError.new("deleted").message
    assert_equal "tuna: tunnel terminated by server (other)", SDK::TerminatedError.new("other").message
    assert SDK.permanent?(SDK::TerminatedError.new("deleted"))
    refute SDK.permanent?(SDK::KeepAliveTimeoutError.new)
    refute SDK.permanent?(RuntimeError.new)
    assert_equal "tuna: keepalive timeout", SDK::KeepAliveTimeoutError.new.message
  end

  def test_normalize
    with_env("TUNA_API_KEY" => "env-key") do
      o = SDK.normalize(protocol: "http")
      assert_equal "env-key", o.api_key
      assert_equal SDK::DEFAULT_SERVER_URL, o.server_url
      assert_equal "tuna-sdk-ruby/#{SDK::VERSION}", o.client_name
      assert_raises(ArgumentError) { SDK.normalize(protocol: "udp") }
      assert_raises(ArgumentError) { SDK.normalize(protocol: "http", server_url: "ftp://x") }
      assert_raises(ArgumentError) { SDK.normalize(protocol: "http", client_name: "a\nb") }
      assert_raises(ArgumentError) { SDK.normalize(protocol: "http", unknown: 1) }
    end
    with_env("TUNA_API_KEY" => nil) do
      assert_raises(ArgumentError) { SDK.normalize(protocol: "http") }
    end
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
