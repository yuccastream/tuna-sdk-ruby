# tuna-sdk-ruby

Open [tuna.am](https://tuna.am) tunnels straight from Ruby code: expose a local
HTTP or TCP service at a public address without installing the `tuna` CLI.

- Two ways in: `Tuna::SDK.listen` hands you each connection as a socket,
  `Tuna::SDK.forward` proxies connections to a local address.
- Survives network failures: reconnects with backoff and keeps the same
  public address.
- Small: only the standard library and [net-ssh](https://github.com/net-ssh/net-ssh).

The API is not stable yet: it may change before v1.

## Install

```shell
gem install tuna-sdk
```

or in a `Gemfile`:

```ruby
gem "tuna-sdk"
```

Requires Ruby 3.1 or later. net-ssh 8 needs the `openssl` gem 3.2 or later:
Ruby 3.3 and newer ship it, on 3.1 and 3.2 it is built on install and needs
the OpenSSL headers (`libssl-dev` or similar).

## Authentication

Create an API key with the `tunnels:connect` scope at
[my.tuna.am](https://my.tuna.am) and pass it as `api_key` or in the
`TUNA_API_KEY` environment variable.

## Forward to a local service

```ruby
require "tuna/sdk"

Tuna::SDK.forward({ protocol: "http" }, "127.0.0.1:3000") do |tunnel|
  puts "public URL: #{tunnel.url}"
  tunnel.wait
end
```

The local address is `host:port` or `unix:///path/to.sock`. Without a block
`forward` blocks until the tunnel ends for good. With a block it yields the
connected tunnel and closes it when the block returns; `tunnel.wait` blocks
until `tunnel.close` is called, for example from a signal handler:

```ruby
trap("TERM") { Thread.new { tunnel.close } }
```

## Handle connections yourself

```ruby
Tuna::SDK.listen(protocol: "tcp", port: "my-db") do |tunnel|
  puts "public URL: #{tunnel.url}"
  while (conn = tunnel.accept)
    Thread.new(conn) do |c|
      c.write(c.gets)
    ensure
      c.close
    end
  end
end
```

`accept` returns a `UNIXSocket` connected to the visitor, or `nil` once the
tunnel is closed. Without a block `listen` returns the tunnel.

[`examples/runner.rb`](examples/runner.rb) is a complete command-line client
built on both calls.

## Options

`options` is a Hash or a `Tuna::SDK::Options`:

| Key | Meaning |
|---|---|
| `protocol` | `"http"` or `"tcp"`, required |
| `api_key` | API key, defaults to `$TUNA_API_KEY` |
| `subdomain`, `domain` | reserved subdomain or custom domain for HTTP |
| `port` | reserved TCP port or its alias |
| `proxy_protocol` | PROXY protocol header version for TCP: `1` or `2` |
| `cidr_allow`, `cidr_deny` | client CIDRs filtered by the tuna.am node, TCP only |
| `location` | only for names and ports reserved in the legacy `ru` or `nl` zones; empty lets the server pick |
| `on_event` | callable receiving a `Tuna::SDK::Event` |
| `connect_timeout` | seconds to wait for the first connection; `nil` means no limit |
| `server_url`, `client_name` | API address and client name reported to the server |

## Events and errors

`on_event` receives a `Tuna::SDK::Event` whose `type` is `:connected`,
`:reconnecting`, `:reconnected`, `:banner`, `:session_expiring`, `:terminated`
or `:local_error`, with `url`, `message`, `reason`, `error`, `retry_in` and
`expires_in` (seconds) where they apply. Calls never overlap and run on the
tunnel's threads, so keep the callback short.

```ruby
on_event = ->(e) { warn "#{e.type} #{e.url || e.error&.message}" }
Tuna::SDK.forward({ protocol: "http", on_event: on_event }, "127.0.0.1:3000")
```

Network failures and temporary server errors are retried: the pause grows from
1 to 15 seconds with random jitter, and `Retry-After` is respected. A silent
node is detected by keepalive within 15 seconds and reported as
`Tuna::SDK::KeepAliveTimeoutError` in a `:reconnecting` event. The tunnel ends
with an error when retrying is pointless; check it with
`Tuna::SDK.permanent?(err)`:

- `Tuna::SDK::ServerError` — the API rejected the request: bad or revoked
  key, missing scope, unknown reserved name, unpaid plan; it carries `status`,
  `code`, `text` and `request_id`;
- `Tuna::SDK::TerminatedError` — the server closed the tunnel: it was
  deleted, suspended or hit the session time limit; `reason` tells which.

## Behaviour worth knowing

- `close` stops accepting and reconnecting, but the tunnel stays connected
  until the last accepted connection is closed.
- When either side of a forwarded connection closes, the connection is closed
  in both directions.
- The `Host` header and the PROXY protocol header reach your service as sent.
- The tunnel runs the SSH connection on its own thread; `accept`, `wait` and
  `close` may be called from any thread.
- The API client is `Net::HTTP`. Use `SSL_CERT_FILE` for a private CA.

## Contributing

This repository is a read-only mirror of the SDK directory in the tuna.am
monorepo. Issues and pull requests are welcome here: accepted changes are
applied upstream and come back with the next release.

## License

[MIT](LICENSE)
