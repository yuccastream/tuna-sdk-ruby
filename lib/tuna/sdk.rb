# frozen_string_literal: true

require "json"
require "net/http"
require "net/ssh"
require "rbconfig"
require "socket"
require "timeout"
require "uri"
require_relative "sdk/version"

module Tuna
  # Opens tuna.am tunnels from Ruby code.
  #
  # Tuna::SDK.listen returns a Tunnel whose #accept yields connections arriving
  # at the public address. Tuna::SDK.forward proxies them to a local address.
  #
  # A tunnel survives network failures: it reconnects with backoff and keeps
  # its public address. It ends on Tunnel#close or a permanent error (see
  # Tuna::SDK.permanent?).
  module SDK
    # The tuna.am API used when Options#server_url is empty.
    DEFAULT_SERVER_URL = "https://api.tuna.am"

    CLIENT_VERSION = 2
    SSH_USER = "tuna"
    DIAL_TIMEOUT = 10
    API_TIMEOUT = 15
    KEEPALIVE_REQUEST = "keepalive@openssh.com"
    KEEPALIVE_INTERVAL = 5
    KEEPALIVE_TIMEOUT = 15
    LOOP_TICK = 0.1
    MIN_BACKOFF = 1.0
    MAX_BACKOFF = 15.0
    MAX_RETRY_AFTER = 300
    PERMANENT_CODES = %w[PaymentRequired Unauthorized AuthorizationRequired Forbidden BadRequest NotFound UpgradeRequired].freeze
    TERMINATE_MESSAGES = {
      "deleted" => "tunnel was deleted",
      "suspended" => "tunnel was suspended",
      "session_limit" => "session time limit reached",
      "session_ended" => "client session ended",
      "reconnect" => "tunnel was taken over by another connection"
    }.freeze
    private_constant :CLIENT_VERSION, :SSH_USER, :DIAL_TIMEOUT, :API_TIMEOUT, :KEEPALIVE_REQUEST,
                     :KEEPALIVE_INTERVAL, :KEEPALIVE_TIMEOUT, :LOOP_TICK, :MIN_BACKOFF, :MAX_BACKOFF,
                     :MAX_RETRY_AFTER, :PERMANENT_CODES, :TERMINATE_MESSAGES

    # Tunnel settings. Only +protocol+ is required.
    #
    # api_key:: tuna.am API key with the tunnels:connect scope, defaults to $TUNA_API_KEY
    # protocol:: "http" or "tcp"
    # location:: only for names and ports reserved in the legacy "ru" or "nl" zones
    # subdomain, domain:: reserved subdomain or custom domain for HTTP tunnels
    # port:: reserved TCP port or its alias
    # proxy_protocol:: PROXY protocol header version for TCP tunnels, 1 or 2
    # cidr_allow, cidr_deny:: client CIDRs allowed or rejected by a TCP tunnel
    # server_url:: tuna.am API address, defaults to DEFAULT_SERVER_URL
    # client_name:: name reported to the server, defaults to "tuna-sdk-ruby/<VERSION>"
    # connect_timeout:: seconds to wait for the first connection, nil means no limit
    # on_event:: callable receiving an Event; calls never overlap and come from
    #            the tunnel's own threads, so it must return quickly
    Options = Struct.new(:api_key, :protocol, :location, :subdomain, :domain, :port, :proxy_protocol,
                         :cidr_allow, :cidr_deny, :server_url, :client_name, :connect_timeout, :on_event,
                         keyword_init: true)

    # A change in the tunnel state.
    #
    # type:: :connected, :reconnected, :reconnecting, :banner, :session_expiring,
    #        :terminated or :local_error
    # url:: public address, for :connected and :reconnected
    # message:: human-readable text, for :banner and :terminated
    # reason:: machine-readable cause, for :terminated
    # error:: the cause, for :reconnecting and :local_error
    # retry_in:: seconds before the next attempt, for :reconnecting
    # expires_in:: seconds left, for :session_expiring
    Event = Struct.new(:type, :url, :message, :reason, :error, :retry_in, :expires_in, keyword_init: true)

    # Base class of SDK errors.
    class Error < StandardError
      # Whether retrying after this error is pointless.
      def permanent?
        false
      end
    end

    # An error response from the tuna.am API.
    class ServerError < Error
      # HTTP status code.
      attr_reader :status
      # Machine-readable error code.
      attr_reader :code
      # Human-readable error text.
      attr_reader :text
      # Identifies the request for tuna.am support.
      attr_reader :request_id
      # Delay in seconds requested by the server, or nil.
      attr_reader :retry_after

      # Creates the error; +before_first_connect+ makes non-JSON 4xx permanent.
      def initialize(status:, text:, code: nil, request_id: nil, retry_after: nil, before_first_connect: false)
        @status = status
        @text = text
        @code = code
        @request_id = request_id
        @retry_after = retry_after
        @before_first_connect = before_first_connect
        super(request_id.to_s.empty? ? "tuna: #{text}" : "tuna: #{text} (request id #{request_id})")
      end

      # Marks the error as received before the tunnel ever came up.
      def before_first_connect!
        @before_first_connect = true
      end

      # Whether retrying after this error is pointless.
      def permanent?
        return true if status.between?(300, 399)
        return true if @before_first_connect && status.between?(400, 499) && ![408, 429].include?(status)

        PERMANENT_CODES.include?(code)
      end
    end

    # The server closed the tunnel for good.
    class TerminatedError < Error
      # Machine-readable cause, e.g. "deleted" or "session_limit".
      attr_reader :reason

      # Creates the error for a terminate reason.
      def initialize(reason)
        @reason = reason
        super("tuna: #{text}")
      end

      # Human-readable cause.
      def text
        TERMINATE_MESSAGES.fetch(reason) { "tunnel terminated by server (#{reason})" }
      end

      # Always true.
      def permanent?
        true
      end
    end

    # The node stopped answering keepalive requests.
    class KeepAliveTimeoutError < Error
      # Creates the error.
      def initialize(msg = "tuna: keepalive timeout")
        super
      end
    end

    class HostKeyVerifier
      def initialize(blobs)
        @blobs = blobs
      end

      def verify(arguments)
        @blobs.include?(arguments[:key_blob])
      end

      def verify_signature
        yield
      end
    end
    private_constant :HostKeyVerifier

    class << self
      # Connects a tunnel that proxies connections to +addr+ ("host:port" or
      # "unix:///path.sock") and blocks until it ends: returns nil after
      # Tunnel#close, raises on a permanent error. With a block, yields the
      # connected Tunnel, closes it when the block returns and returns the
      # block's value.
      def forward(options, addr)
        dial_target(addr)
        tunnel = Tunnel.new(options, addr)
        return tunnel.wait unless block_given?

        begin
          yield tunnel
        ensure
          tunnel.close
        end
      end

      # Connects a tunnel and returns it once it is up; Tunnel#accept returns
      # its connections. With a block, yields the Tunnel, closes it when the
      # block returns and returns the block's value.
      def listen(options)
        tunnel = Tunnel.new(options)
        return tunnel unless block_given?

        begin
          yield tunnel
        ensure
          tunnel.close
        end
      end

      # Whether retrying after +err+ is pointless.
      def permanent?(err)
        err.respond_to?(:permanent?) && err.permanent?
      end

      # Splits "host:port", "[v6]:port" or "unix:///path" into a socket target.
      def dial_target(addr)
        return [:unix, addr.delete_prefix("unix://")] if addr.start_with?("unix://")

        host, sep, port = addr.rpartition(":")
        raise ArgumentError, "tuna: invalid address #{addr.inspect}: want host:port or unix:///path.sock" if sep.empty? || host.empty? || port !~ /\A\d+\z/

        [:tcp, host.delete_prefix("[").delete_suffix("]"), Integer(port, 10)]
      end

      # Opens a connection to a local address with the SDK's dial timeout.
      def dial_local(addr)
        kind, host, port = dial_target(addr)
        return UNIXSocket.new(host) if kind == :unix

        Socket.tcp(host, port, connect_timeout: DIAL_TIMEOUT)
      end

      # Pause before the next attempt for the current backoff and error.
      def retry_delay(backoff, err, rand: Random)
        wait = [MAX_BACKOFF, MIN_BACKOFF + rand.rand * backoff].min
        wait = err.retry_after.to_f if err.is_a?(ServerError) && err.retry_after && err.retry_after > wait
        wait
      end

      # Public address from a /v1/connect response.
      def public_url(response, protocol)
        url = response["public_url"].to_s
        return url unless url.empty?
        return "tcp://#{response['domain_name']}:#{response['endpoint_port'].to_i}" if protocol == "tcp"

        "https://#{response['domain_name']}"
      end

      # Parses a /v1/connect response or raises ServerError.
      def parse_response(status, body, location: nil, retry_after: nil)
        return JSON.parse(body) if status.between?(200, 299)

        fields = {}
        if status.between?(300, 399)
          fields[:text] = "server redirects to #{location.to_s.inspect}, check the server URL"
        else
          parsed = begin
            JSON.parse(body.to_s)
          rescue JSON::ParserError
            nil
          end
          if parsed.is_a?(Hash) && !parsed["error"].to_s.empty?
            fields = { text: parsed["error"], code: parsed["code"], request_id: parsed["request_id"] }
          else
            fields[:text] = "server responded with status #{status}"
          end
        end
        secs = Integer(retry_after.to_s, 10, exception: false)
        fields[:retry_after] = [secs, MAX_RETRY_AFTER].min if secs&.positive?
        raise ServerError.new(status: status, **fields)
      end

      # Event from a line of the node's events channel: [:terminate, reason],
      # [:session_expiring, seconds] or nil for anything else.
      def node_event(line)
        ev = JSON.parse(line)
        return unless ev.is_a?(Hash)

        case ev["type"]
        when "terminate" then [:terminate, ev["reason"].to_s]
        when "session_expiring" then [:session_expiring, ev["expires_in"].to_f]
        end
      rescue JSON::ParserError
        nil
      end

      # Operating system name as the server expects it.
      def os_name
        case RbConfig::CONFIG["host_os"]
        when /linux/ then "linux"
        when /darwin/ then "darwin"
        when /mswin|mingw|cygwin/ then "windows"
        when /freebsd/ then "freebsd"
        when /openbsd/ then "openbsd"
        else RbConfig::CONFIG["host_os"]
        end
      end

      # CPU architecture as the server expects it.
      def arch_name
        case RbConfig::CONFIG["host_cpu"]
        when /x86_64|amd64|x64/ then "amd64"
        when /aarch64|arm64/ then "arm64"
        when /i[3-6]86/ then "386"
        else RbConfig::CONFIG["host_cpu"]
        end
      end

      # Options with defaults applied, or ArgumentError.
      def normalize(options)
        o = options.is_a?(Options) ? options.dup : Options.new(**options)
        o.api_key = ENV.fetch("TUNA_API_KEY", "") if o.api_key.to_s.empty?
        raise ArgumentError, "tuna: API key is required: set api_key or TUNA_API_KEY" if o.api_key.to_s.empty?

        o.protocol = o.protocol.to_s
        raise ArgumentError, "tuna: unsupported protocol #{o.protocol.inspect}" unless %w[http tcp].include?(o.protocol)

        o.server_url = DEFAULT_SERVER_URL if o.server_url.to_s.empty?
        uri = URI.parse(o.server_url)
        raise ArgumentError, "tuna: invalid server URL #{o.server_url.inspect}: want https://host" unless %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

        o.client_name = "tuna-sdk-ruby/#{VERSION}" if o.client_name.to_s.empty?
        raise ArgumentError, "tuna: client_name must not contain control characters" if o.client_name.match?(/[[:cntrl:]]/)

        o
      rescue URI::InvalidURIError => e
        raise ArgumentError, "tuna: invalid server URL: #{e.message}"
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # A connected tunnel. It survives reconnects; it ends after #close or a
    # permanent error.
    class Tunnel
      # Current public address, e.g. https://name.tuna.am or tcp://ru.tuna.am:40000.
      attr_reader :url

      # Connects and returns once the tunnel is up; raises on a permanent
      # error or when Options#connect_timeout passes. Use Tuna::SDK.listen or
      # Tuna::SDK.forward instead of calling it directly.
      def initialize(options, forward_to = nil)
        @o = SDK.normalize(options)
        @forward_to = forward_to
        @lock = Mutex.new
        @cond = ConditionVariable.new
        @emit_lock = Mutex.new
        @conns = Thread::Queue.new
        @state = :connecting
        @closing = false
        @error = nil
        @last_error = nil
        @ever_up = false
        @session_id = ""
        @banner_shown = false
        @thread = Thread.new { run }
        wait_ready
      end

      # Waits for the next connection to the public address and returns it as
      # a socket. Returns nil after #close; raises the error that ended the
      # tunnel.
      def accept
        io = @conns.pop
        return io if io

        @lock.synchronize { raise @error if @error }
        nil
      end

      # Stops accepting connections and reconnecting. Connections accepted
      # earlier keep working: the tunnel stays connected to the node until the
      # last of them is closed. Does not wait; see #wait.
      def close
        @lock.synchronize do
          @closing = true
          @cond.broadcast
        end
        @conns.close
        drain
        nil
      end

      # Blocks until the tunnel ends: returns nil after #close, raises the
      # permanent error otherwise.
      def wait
        @lock.synchronize { @cond.wait(@lock) until @state == :done }
        raise @error if @error

        nil
      end

      private

      def drain
        loop { @conns.pop(true).close }
      rescue ThreadError
        nil
      end

      def closing?
        @lock.synchronize { @closing }
      end

      def wait_ready
        timeout = @o.connect_timeout
        deadline = timeout && SDK.monotonic + timeout
        @lock.synchronize do
          while @state == :connecting
            left = deadline && deadline - SDK.monotonic
            if left && left <= 0
              @closing = true
              @cond.broadcast
              raise Error, start_error("tuna: tunnel did not come up within #{timeout}s")
            end
            @cond.wait(@lock, left)
          end
          raise @error || Error.new("tuna: tunnel closed before it came up") if @state == :done && !@ever_up
        end
      end

      def start_error(msg)
        @last_error ? "#{msg} (last attempt: #{@last_error.message})" : msg
      end

      def emit(**fields)
        return unless @o.on_event

        @emit_lock.synchronize { @o.on_event.call(Event.new(**fields)) }
      end

      def finish(err)
        @lock.synchronize do
          return if @state == :done

          @error = err
          @state = :done
          @cond.broadcast
        end
        @conns.close
      end

      def sleep_unless_closed(seconds)
        deadline = SDK.monotonic + seconds
        @lock.synchronize do
          until @closing
            left = deadline - SDK.monotonic
            return false if left <= 0

            @cond.wait(@lock, left)
          end
          true
        end
      end

      def run
        backoff = MIN_BACKOFF
        loop do
          connected, err = session
          return finish(nil) if closing?

          err.before_first_connect! if err.is_a?(ServerError) && !@ever_up
          @last_error = err
          if SDK.permanent?(err)
            emit(type: :terminated, reason: err.reason, message: err.text) if err.is_a?(TerminatedError)
            return finish(err)
          end
          backoff = MIN_BACKOFF if connected
          wait = SDK.retry_delay(backoff, err)
          emit(type: :reconnecting, error: err, retry_in: wait)
          return finish(nil) if sleep_unless_closed(wait)

          backoff = [backoff * 2, MAX_BACKOFF].min
        end
      rescue StandardError => e
        finish(e)
      end

      def session
        cr = connect
        @session_id = cr["tunnel_session_id"].to_s
        if !cr["banner"].to_s.empty? && !@banner_shown
          @banner_shown = true
          emit(type: :banner, message: cr["banner"])
        end
        return [false, nil] if closing?

        serve(dial(cr), cr)
      rescue StandardError => e
        [false, e]
      end

      def connect
        uri = URI.parse("#{@o.server_url.chomp('/')}/v1/connect")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = http.read_timeout = http.write_timeout = API_TIMEOUT
        req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "User-Agent" => @o.client_name)
        req.body = JSON.generate(connect_body)
        resp = http.request(req)
        SDK.parse_response(resp.code.to_i, resp.body, location: resp["Location"], retry_after: resp["Retry-After"])
      end

      def connect_body
        body = {
          client_version: CLIENT_VERSION,
          client_name: @o.client_name,
          sdk_version: VERSION,
          forwards_to: @forward_to.to_s,
          protocol: @o.protocol,
          location: @o.location.to_s,
          subdomain: @o.subdomain.to_s,
          domain: @o.domain.to_s,
          token: @o.api_key,
          os: SDK.os_name,
          arch: SDK.arch_name,
          port_or_alias: @o.port.to_s,
          tunnel_session_id: @session_id,
          proxy_protocol: @o.proxy_protocol.to_i
        }
        body[:cidr_allow_list] = Array(@o.cidr_allow) unless Array(@o.cidr_allow).empty?
        body[:cidr_deny_list] = Array(@o.cidr_deny) unless Array(@o.cidr_deny).empty?
        body
      end

      def dial(cr)
        blobs = Array(cr["host_keys"]).map do |hk|
          Net::SSH::Buffer.from(:key, Net::SSH::KeyFactory.load_data_public_key(hk["key"].to_s)).to_s
        rescue StandardError => e
          raise Error, "tuna: parse host key: #{e.message}"
        end
        _, host, port = SDK.dial_target(cr["address"].to_s)
        Timeout.timeout(DIAL_TIMEOUT, Error, "tuna: node did not answer within #{DIAL_TIMEOUT}s") do
          Net::SSH.start(host, SSH_USER,
                         port: port, password: cr["token"].to_s, auth_methods: ["password"],
                         verify_host_key: HostKeyVerifier.new(blobs), timeout: DIAL_TIMEOUT,
                         config: false, use_agent: false, keys: [], keys_only: true, non_interactive: true,
                         number_of_password_prompts: 0, user_known_hosts_file: [], global_known_hosts_file: [])
        end
      end

      def serve(ssh, cr)
        failure = nil
        fail = ->(err) { failure ||= err }
        connected = false
        last_reply = last_ping = SDK.monotonic
        ssh.forward
        ssh.on_open_channel("forwarded-tcpip") { |_s, channel, _packet| accept_channel(ssh, channel) }
        ssh.send_global_request("tcpip-forward", :string, "127.0.0.1", :long, 0) do |ok, _response|
          next fail.call(Error.new("tuna: remote forward: request refused")) unless ok

          open_events(ssh, fail)
          connected = true
          up(cr)
        end
        begin
          ssh.loop(LOOP_TICK) do
            now = SDK.monotonic
            if now - last_reply > KEEPALIVE_TIMEOUT
              fail.call(KeepAliveTimeoutError.new)
            elsif now - last_ping >= KEEPALIVE_INTERVAL
              last_ping = now
              ssh.send_global_request(KEEPALIVE_REQUEST) { last_reply = SDK.monotonic }
            end
            failure.nil? && !(closing? && ssh.channels.values.none? { |c| c[:tuna_conn] })
          end
        rescue StandardError => e
          fail.call(Error.new("tuna: connection to node lost: #{e.message}"))
        ensure
          begin
            ssh.shutdown!
          rescue StandardError
            nil
          end
        end
        [connected, failure]
      end

      def up(cr)
        @url = SDK.public_url(cr, @o.protocol)
        if @ever_up
          emit(type: :reconnected, url: @url)
        else
          @ever_up = true
          emit(type: :connected, url: @url)
          @lock.synchronize do
            @state = :up if @state == :connecting
            @cond.broadcast
          end
        end
      end

      def open_events(ssh, fail)
        buf = +""
        channel = ssh.open_channel do |ch|
          ch.exec("events") { |_c, _ok| nil }
          ch.on_data do |c, data|
            buf << data
            while (i = buf.index("\n"))
              kind, value = SDK.node_event(buf.slice!(0..i))
              case kind
              when :terminate
                fail.call(TerminatedError.new(value))
                c.close
              when :session_expiring
                emit(type: :session_expiring, expires_in: value)
              end
            end
          end
        end
        channel.on_open_failed { |*| nil }
      end

      def accept_channel(ssh, channel)
        ours, theirs = UNIXSocket.pair
        channel[:tuna_conn] = true
        ssh.forward.send(:prepare_client, ours, channel, :remote)
        return theirs.close if closing?
        return Thread.new { pipe(theirs) } if @forward_to

        begin
          @conns << theirs
        rescue ClosedQueueError
          theirs.close
        end
      end

      def pipe(remote)
        local = begin
          SDK.dial_local(@forward_to)
        rescue StandardError => e
          emit(type: :local_error, error: e)
          return remote.close
        end
        done = Thread::Queue.new
        [[remote, local], [local, remote]].each do |src, dst|
          Thread.new do
            IO.copy_stream(src, dst)
          rescue StandardError
            nil
          ensure
            done << true
          end
        end
        done.pop
        [remote, local].each do |io|
          io.shutdown
        rescue StandardError
          nil
        ensure
          io.close
        end
      end
    end
  end
end
