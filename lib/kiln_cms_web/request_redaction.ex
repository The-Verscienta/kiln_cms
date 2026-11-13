defmodule KilnCMSWeb.RequestRedaction do
  @moduledoc """
  Takes credentials out of a request path before it is written down (#2449).

  A magic sign-in link, a password reset, an invitation, a preview grant and a
  newsletter link all carry their secret in the URL **path**, and a path is
  something the app writes down: Phoenix's request line (`GET /magic_link/…`,
  at `:info`, the production level) and the 404 list editors can read.
  `:filter_parameters` cannot help there — it applies to params maps, never to
  a path.

  ## Which segments are secret

  The rule is read off the router rather than kept as a list of prefixes, so a
  new token route is covered the day it is added: a route segment is secret
  when its parameter name contains `token` or `secret` (`credential_param?/1`),
  which covers `:token`, `:invite_token`, `:unlock_token` and any plugin
  `get`/`post`/`match` route that follows the same naming. Routes inside a
  forwarded sub-router (a `forward` in the router, or a plugin's `{:forward, …}`
  plug route) are invisible here: `Phoenix.Router.routes/1` lists only the
  mount point, so a sub-router must keep credentials out of its paths.
  `test/kiln_cms_web/request_redaction_test.exs`
  pins the resulting set against an explicit table, so a route that slips the
  rule fails a test instead of reaching a log.

  Each such route becomes a **prefix pattern**: its segments up to and
  including the last secret one. A path matches when every literal segment of
  the pattern is equal; trailing segments beyond the pattern are allowed and
  kept, so a mangled link (`/magic_link/<token>/x`, which routes to the 404
  catch-all) is still caught. A secret glob redacts everything after it.

  Matching deliberately over-redacts rather than reproducing the router:

    * **Every** matching pattern applies, and the redacted positions are their
      union. `/preview/release/<token>` matches both `/preview/:token` and
      `/preview/release/:token`; taking only the first would redact `release`
      and log the token.
    * Patterns are tried at offset 0 **and** 1, whatever locales are
      configured. `Plug.Telemetry` runs before `KilnCMSWeb.Plugs.SetLocale`
      strips a locale prefix, so `/fr/magic_link/<token>` must be caught as
      written. Treating any first segment as a possible prefix costs nothing
      but the odd harmless `[FILTERED]` on a non-token path.
    * A conn is matched on its `path_info` (empty segments dropped, each
      segment percent-decoded), which is what the router matched on, and the
      redacted path is rebuilt from it — so `//magic_link/<token>`, which
      routes to the sign-in page, is caught too.

  A path no pattern matches comes back byte-identical.

  ## Failing closed

  The patterns are built once, lazily, and kept in `:persistent_term`. If the
  build fails, the failure is remembered too (retried after 30 seconds, so a
  broken router doesn't rebuild on every request) and until it succeeds **every** path counts as secret and is written
  as `"/[FILTERED]"`. Nothing here raises: a redaction that cannot run drops
  the path rather than logging it.
  """

  require Logger

  @filtered "[FILTERED]"
  @cache_key {__MODULE__, :patterns}
  @retry_ms 30_000

  @typedoc "A route path segment: a literal, or a parameter/glob flagged secret or not."
  @type segment :: {:lit, String.t()} | {:param, boolean()} | {:glob, boolean()}

  @doc """
  True when a route parameter called `name` carries a credential: its name
  contains `token` or `secret`, in any case.
  """
  @spec credential_param?(String.t()) :: boolean()
  def credential_param?(name) when is_binary(name) do
    String.contains?(String.downcase(name), ["token", "secret"])
  end

  @doc """
  Redact the secret segments of a conn's path, or of a path string.

  Returns `{:redacted, path}` when any segment was secret (or when redaction
  could not run, as `{:redacted, "/[FILTERED]"}`), otherwise `:unchanged`.

  A conn is matched on its decoded `path_info`. A string is split on `/` and
  matched as given, for a caller that already holds a decoded path.

  Patterns are tried at the start of the path and one segment in, because
  the request log runs before the locale prefix is stripped. A caller whose
  path has already lost its locale passes `locale_stripped: true` to match at
  the start only.
  """
  @spec redact(Plug.Conn.t() | String.t(), keyword()) ::
          {:redacted, String.t()} | :unchanged
  def redact(conn_or_path, opts \\ [])

  def redact(%Plug.Conn{path_info: segments}, opts),
    do: redact_segments(segments, &decode/1, offsets(opts))

  def redact(path, opts) when is_binary(path) do
    path |> String.split("/", trim: true) |> redact_segments(& &1, offsets(opts))
  end

  defp offsets(opts), do: if(opts[:locale_stripped], do: [0], else: [0, 1])

  @doc """
  The path to write down: redacted when it carries a secret, otherwise the
  conn's `request_path` (or the given string) byte-identical.
  """
  @spec redact_path(Plug.Conn.t() | String.t()) :: String.t()
  def redact_path(conn_or_path) do
    case redact(conn_or_path) do
      {:redacted, path} -> path
      :unchanged -> original(conn_or_path)
    end
  end

  @doc "True when the conn's path (or the path string) carries a secret. Options as `redact/2`."
  @spec secret?(Plug.Conn.t() | String.t(), keyword()) :: boolean()
  def secret?(conn_or_path, opts \\ []), do: redact(conn_or_path, opts) != :unchanged

  @doc """
  The route paths with at least one secret segment, as the router spells
  them. For the drift test; `{:error, reason}` when the router can't be read.
  """
  @spec secret_routes() :: {:ok, [String.t()]} | {:error, term()}
  def secret_routes do
    {:ok,
     router()
     |> Phoenix.Router.routes()
     |> Enum.map(& &1.path)
     |> Enum.filter(fn path -> path |> parse() |> Enum.any?(&secret_segment?/1) end)
     |> Enum.uniq()}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Forget the cached patterns (and any cached build failure)."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp original(%Plug.Conn{request_path: path}), do: path
  defp original(path) when is_binary(path), do: path

  defp redact_segments(segments, decode, offsets) do
    case patterns() do
      {:ok, patterns} ->
        decoded = Enum.map(segments, decode)

        case secret_positions(decoded, patterns, offsets) do
          [] -> :unchanged
          positions -> {:redacted, rebuild(segments, MapSet.new(positions))}
        end

      :error ->
        fail_closed()
    end
  rescue
    _ -> fail_closed()
  end

  defp fail_closed, do: {:redacted, "/" <> @filtered}

  # A malformed escape (`%zz`) can't name a literal route segment either way,
  # so it is compared as written.
  defp decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end

  defp secret_positions(segments, patterns, offsets) do
    for offset <- offsets,
        rest <- [Enum.drop(segments, offset)],
        pattern <- patterns,
        positions <- [match(pattern, rest, offset, [])],
        is_list(positions),
        position <- positions,
        do: position
  end

  # `nil` for no match, otherwise the indexes of the secret segments.
  defp match([], _rest, _index, acc), do: acc

  defp match([{:glob, true} | _], rest, index, acc),
    do: Enum.to_list(index..(index + length(rest) - 1)//1) ++ acc

  defp match([{:glob, false} | _], _rest, _index, acc), do: acc
  defp match([_ | _], [], _index, _acc), do: nil

  defp match([{:lit, literal} | pattern], [literal | rest], index, acc),
    do: match(pattern, rest, index + 1, acc)

  defp match([{:lit, _} | _], _rest, _index, _acc), do: nil

  defp match([{:param, true} | pattern], [_ | rest], index, acc),
    do: match(pattern, rest, index + 1, [index | acc])

  defp match([{:param, false} | pattern], [_ | rest], index, acc),
    do: match(pattern, rest, index + 1, acc)

  defp rebuild(segments, positions) do
    redacted =
      segments
      |> Enum.with_index()
      |> Enum.map(fn {segment, index} ->
        if MapSet.member?(positions, index), do: @filtered, else: segment
      end)

    "/" <> Enum.join(redacted, "/")
  end

  defp patterns do
    case :persistent_term.get(@cache_key, nil) do
      {:ok, patterns} ->
        {:ok, patterns}

      {:error, failed_at} ->
        if now() - failed_at < @retry_ms, do: :error, else: build_and_store()

      nil ->
        build_and_store()
    end
  end

  defp build_and_store do
    entry =
      try do
        {:ok, build(router())}
      catch
        kind, reason ->
          Logger.error(
            "request path redaction could not read the router " <>
              "(#{inspect(kind)}: #{inspect(reason, limit: 5)}); " <>
              "every request path is logged as /#{@filtered} until it can"
          )

          {:error, now()}
      end

    :persistent_term.put(@cache_key, entry)

    case entry do
      {:ok, patterns} -> {:ok, patterns}
      {:error, _} -> :error
    end
  end

  defp build(router) do
    router
    |> Phoenix.Router.routes()
    |> Enum.map(&parse(&1.path))
    |> Enum.filter(&Enum.any?(&1, fn segment -> secret_segment?(segment) end))
    |> Enum.map(&through_last_secret/1)
    |> Enum.uniq()
  end

  @spec parse(String.t()) :: [segment()]
  defp parse(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      "*" <> name ->
        {:glob, credential_param?(name)}

      segment ->
        # A parameter may follow a literal prefix in its segment (`v:version`);
        # the prefix is not checked, which can only over-redact.
        case String.split(segment, ":", parts: 2) do
          [_prefix, name] -> {:param, credential_param?(name)}
          [literal] -> {:lit, literal}
        end
    end)
  end

  defp secret_segment?({_kind, true}), do: true
  defp secret_segment?(_segment), do: false

  defp through_last_secret(segments) do
    last = segments |> Enum.reverse() |> Enum.drop_while(&(not secret_segment?(&1)))
    Enum.reverse(last)
  end

  defp router do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:router, KilnCMSWeb.Router)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
