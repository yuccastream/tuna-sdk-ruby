# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require "uri"
require "tuna/sdk"

USAGE = "Usage: runner.rb http|tcp <addr> [-s SUBDOMAIN] [-d DOMAIN] [-p PORT] [--proxy-protocol N] " \
        "[--cidr-allow CIDR]... [--cidr-deny CIDR]... [--listen] [--log-format text|json]"

def local_addr(arg)
  return arg if arg.start_with?("unix://")

  if arg.include?("://")
    uri = URI.parse(arg)
    abort "scheme #{uri.scheme.inspect} is not supported" unless uri.scheme == "http"
    return "#{uri.host}:#{uri.port}"
  end
  return "127.0.0.1:#{arg}" if arg.match?(/\A\d+\z/)

  arg
end

def printer(json)
  lambda do |e|
    if json
      line = { time: Time.now.utc.iso8601, event: e.type.to_s, url: e.url, message: e.message, reason: e.reason,
               error: e.error&.message, retry_in: e.retry_in, expires_in: e.expires_in }.compact
      $stdout.puts(JSON.generate(line))
      $stdout.flush
    else
      warn [e.type, e.url, e.message, e.error&.message].compact.join(" ")
    end
  end
end

def splice(a, b)
  done = Thread::Queue.new
  [[a, b], [b, a]].each do |src, dst|
    Thread.new do
      IO.copy_stream(src, dst)
    rescue StandardError
      nil
    ensure
      done << true
    end
  end
  done.pop
  [a, b].each do |io|
    io.shutdown
  rescue StandardError
    nil
  ensure
    io.close
  end
end

proto = ARGV.shift
abort USAGE unless %w[http tcp].include?(proto)

opts = Tuna::SDK::Options.new(protocol: proto, server_url: ENV.fetch("TUNA_ADDR", nil),
                              location: ENV.fetch("TUNA_LOCATION", nil), cidr_allow: [], cidr_deny: [])
listen = false
log_format = "text"
OptionParser.new(USAGE) do |p|
  p.on("--api-key KEY") { |v| opts.api_key = v }
  p.on("-s SUBDOMAIN") { |v| opts.subdomain = v }
  p.on("-d DOMAIN") { |v| opts.domain = v }
  p.on("-p PORT") { |v| opts.port = v }
  p.on("--proxy-protocol N", Integer) { |v| opts.proxy_protocol = v }
  p.on("--cidr-allow CIDR") { |v| opts.cidr_allow << v }
  p.on("--cidr-deny CIDR") { |v| opts.cidr_deny << v }
  p.on("--listen") { listen = true }
  p.on("--log-format FORMAT", %w[text json]) { |v| log_format = v }
end.parse!
abort USAGE unless ARGV.size == 1
addr = local_addr(ARGV.first)
emit = printer(log_format == "json")
opts.on_event = emit

tunnel = nil
%w[TERM INT].each do |sig|
  trap(sig) { tunnel ? Thread.new { tunnel.close } : exit(0) }
end

begin
  if listen
    Tuna::SDK.listen(opts) do |t|
      tunnel = t
      while (conn = t.accept)
        Thread.new(conn) do |c|
          splice(c, Tuna::SDK.dial_local(addr))
        rescue StandardError => e
          emit.call(Tuna::SDK::Event.new(type: :local_error, error: e))
          c.close
        end
      end
      t.wait
    end
  else
    Tuna::SDK.forward(opts, addr) do |t|
      tunnel = t
      t.wait
    end
  end
rescue Tuna::SDK::TerminatedError
  exit 1
rescue StandardError => e
  emit.call(Tuna::SDK::Event.new(type: :error, error: e))
  exit 1
end
