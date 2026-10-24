defmodule Kiln.SafeFetch do
  @moduledoc """
  Outbound HTTP to a URL a plugin did not write itself — one that came from
  content, a setting, or an allowlist an editor maintains (#2047). A feed
  poller, a link unfurler, a webhook to a configured endpoint.

  Inside a KilnCMS build every call goes to the core's implementation,
  `KilnCMS.SafeFetch`, which every fetch of a content-chosen URL in the core
  goes through too. What it promises:

    * **The address is checked, then pinned.** The host is resolved once, every
      answer must be a public address (no loopback, private, link-local or
      metadata ranges), and the connection is made to that address as a
      literal, with TLS still verified against the real hostname. A name that
      answers with a public address while it is checked and
      `169.254.169.254` a moment later reaches nothing.
    * **Redirects are not followed** unless `:max_redirects` asks, and then
      each hop is checked and pinned again as if the caller had passed it.
      `authorization`, `cookie` and `proxy-authorization` headers are dropped
      when a hop changes host. The hop count is capped whatever the caller
      asks for.
    * **The body is capped** (`:max_bytes`, 256KB by default) by counting
      bytes as they arrive, not by trusting `content-length`.
    * **The body is bytes.** Nothing is decoded; parse it after the call.

  ## Calling it

      case Kiln.SafeFetch.get(feed_url, max_bytes: 2_000_000, max_redirects: 3) do
        {:ok, %{status: 200, body: body}} -> parse(body)
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end

  `{:error, reason}` covers a refused address, a transport failure and an
  over-length body alike. `reason` is a message for a log or an operator; its
  wording is not part of the contract, so don't match on it.

  A response that is still a redirect when the hops run out is returned as
  that `3xx`, so "too many redirects" reads differently from "refused".

  ## Options

  Only these are accepted, on every function:

    * `:headers` — a list of `{name, value}` string pairs;
    * `:body` — iodata, for `request/3` (`post/3` takes it as an argument);
    * `:max_bytes` — the body cap (default `262_144`);
    * `:truncate_body` — when `true`, a body over the cap is cut at the cap
      and returned as an ordinary response instead of an error, for a caller
      that only wants the status (default `false`);
    * `:max_redirects` — how many redirects to follow (default `0`);
    * `:connect_timeout` and `:receive_timeout` — in milliseconds (defaults
      5s and 10s);
    * `:plug` — a `Req.Test` stub, `{Req.Test, name}`, for tests. The request
      is answered by the stub and never reaches the network.

  Anything else is dropped before the call. In particular there is no way to
  hand the HTTP client its own options: those are where the pinning lives.

  ## Outside a KilnCMS build

  The SDK has no HTTP client of its own. In a plugin's standalone test suite,
  with no core loaded, every call returns `{:error, reason}` unless the
  plugin's test config names a module that implements this behaviour:

      # the plugin's config/test.exs
      config :kiln_plugin, :safe_fetch, MyPlugin.FakeFetch

  That setting is read **only** when `KilnCMS.SafeFetch` is absent. Inside a
  KilnCMS build the core's implementation is always the one called, so the
  guarantees above can't be configured away.
  """

  @typedoc "The HTTP methods a fetch may use."
  @type method :: :get | :head | :post | :put | :patch | :delete

  @typedoc "One accepted option. See *Options* above."
  @type option ::
          {:headers, [{String.t(), String.t()}]}
          | {:body, iodata()}
          | {:max_bytes, pos_integer()}
          | {:truncate_body, boolean()}
          | {:max_redirects, non_neg_integer()}
          | {:connect_timeout, pos_integer()}
          | {:receive_timeout, pos_integer()}
          | {:plug, term()}

  @typedoc """
  A response. `headers` maps each lower-cased header name to its list of
  values; `body` is the raw bytes, never decoded.
  """
  @type response :: %{
          status: integer(),
          headers: %{optional(String.t()) => [String.t()]},
          body: binary()
        }

  @typedoc "The result of every function in this module."
  @type result :: {:ok, response()} | {:error, String.t()}

  @doc """
  Fetch `url` with `method`, under every rule in the moduledoc.

  The one callback an implementation provides. It receives only the options
  listed above.
  """
  @callback request(method(), String.t(), [option()]) :: result()

  @core KilnCMS.SafeFetch
  @compile {:no_warn_undefined, @core}

  @accepted [
    :headers,
    :body,
    :max_bytes,
    :truncate_body,
    :max_redirects,
    :connect_timeout,
    :receive_timeout,
    :plug
  ]

  @methods [:get, :head, :post, :put, :patch, :delete]

  @doc "`GET` `url`."
  @spec get(String.t(), [option()]) :: result()
  def get(url, opts \\ []), do: request(:get, url, opts)

  @doc """
  `HEAD` `url` — whether a URL is there, without its body. Plenty of servers
  answer `HEAD` with 405 or answer it wrongly; a caller that cares retries with
  `get/2`.
  """
  @spec head(String.t(), [option()]) :: result()
  def head(url, opts \\ []), do: request(:head, url, opts)

  @doc """
  `POST` `body` to `url`. A `301`, `302` or `303` it follows becomes a `GET`
  without the body, so a redirect can't replay the body at a host the caller
  didn't choose.
  """
  @spec post(String.t(), iodata(), [option()]) :: result()
  def post(url, body, opts \\ []), do: request(:post, url, Keyword.put(opts, :body, body))

  @doc """
  Fetch `url` with any of `t:method/0`. Pass a body as `:body`.
  """
  @spec request(method(), String.t(), [option()]) :: result()
  def request(method, url, opts \\ [])

  def request(method, url, opts) when method in @methods and is_binary(url) and is_list(opts) do
    case implementation() do
      nil -> {:error, "no Kiln.SafeFetch implementation: KilnCMS is not loaded"}
      impl -> impl.request(method, url, Keyword.take(opts, @accepted))
    end
  end

  def request(method, _url, _opts) when method not in @methods,
    do: {:error, "unsupported method: #{inspect(method)}"}

  def request(_method, _url, _opts), do: {:error, "blocked URL: must be a valid URL with a host"}

  # The core, whenever it is loaded. The config key is a seam for a plugin's
  # standalone test suite only — read when the core is absent, so no setting
  # inside a KilnCMS build can route a fetch around the pin.
  defp implementation do
    if Code.ensure_loaded?(@core),
      do: @core,
      else: Application.get_env(:kiln_plugin, :safe_fetch)
  end
end
