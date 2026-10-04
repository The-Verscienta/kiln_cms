defmodule KilnCMSWeb.SentryScrubber do
  @moduledoc """
  Request-body scrubbing for Sentry events (#726).

  Sentry's default masks `password`, `passwd` and `secret` — enough for the
  first factor and nothing else. Everything this project puts in a request body
  and treats as a credential is listed here instead, so the list is one thing to
  keep current rather than an assumption about a dependency's defaults.

  The one that prompted it: `POST /api/auth/sign_in/verify` takes a
  `pending_token` *and* a `code`, and together those are a completed sign-in for
  a two-factor account. A single 500 on that route would have handed both to
  anyone with Sentry read access, inside the five minutes they remain
  redeemable. `password` being masked while the second factor was not is
  precisely the asymmetry #726 exists to remove.

  Nested and array bodies are walked, because `Sentry.Scrubber` inspects only
  top-level keys and a JSON:API write puts its payload under `data.attributes`.

  ## Two lists, because one rule cannot serve both

  `token`, `password` and `secret` are matched as **substrings**: any spelling
  of them is a credential, and `csrf_token` or `api_key_secret` being masked in
  an error report costs nothing.

  `code` is matched **exactly**. It is the second factor's field name, but it is
  also the tail of `locale_code`, `country_code`, `currency_code` and
  `status_code` — masking those would quietly gut the reports this exists to
  keep useful. The trade is deliberate and is why the two lists are separate
  rather than one regex.

  ## The update feed carries no client address (#1877)

  Every Kiln instance's update check reads kilncms.dev's
  `GET /api/json/entries/published` — the generic published-entries route,
  which any Kiln serves. kilncms.dev has promised not to keep client IPs for
  it, and this is the one place the app itself would: `Sentry.PlugContext`
  attaches the client address (`REMOTE_ADDR`, read from `x-forwarded-for`) and
  every request header to any error event raised while handling a request. So
  for a read of that route, `remote_address/1` reports none and
  `scrub_headers/1` drops the client-address headers as well. Every other
  route keeps Sentry's defaults; widening this would be a policy change about
  error reports in general, not part of the feed's promise.
  """

  # `Sentry.PlugContext` runs ahead of the router, so this is matched on the
  # path; the locale prefix is already stripped by then.
  @update_feed_path ["api", "json", "entries", "published"]

  # Every header a proxy or platform uses to pass the client address on —
  # `RemoteIp`'s defaults (as `KilnCMSWeb.Plugs.ClientIp` honours them) plus
  # the CDN and platform ones it knows.
  @client_address_headers ~w(
    forwarded x-forwarded-for x-client-ip x-real-ip x-cluster-client-ip
    cf-connecting-ip true-client-ip fly-client-ip do-connecting-ip
  )

  @mask "*********"

  # Matched anywhere in the key, case-insensitively.
  @sensitive_substrings ~w(
    password passwd secret token credential authorization cookie signature private_key
  )

  # Matched as the whole key, case-insensitively — see the moduledoc.
  @sensitive_exact ~w(code otp pin api_key apikey)

  @doc """
  `Sentry.PlugContext`'s `:body_scrubber`. Returns the request params with every
  sensitive value replaced.
  """
  @spec scrub_params(Plug.Conn.t()) :: map()
  def scrub_params(%Plug.Conn{params: params}) when is_map(params), do: scrub(params)
  def scrub_params(_conn), do: %{}

  # A struct is a map, so it would otherwise be walked into a shape Sentry
  # renders as an anonymous object. `inspect/1` keeps it readable and cannot
  # leak more than the struct's own inspect protocol already would.
  defp scrub(%_struct{} = value), do: inspect(value)

  defp scrub(value) when is_map(value) do
    Map.new(value, fn {key, val} ->
      if sensitive?(key), do: {key, @mask}, else: {key, scrub(val)}
    end)
  end

  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  defp scrub(value), do: value

  defp sensitive?(key) do
    downcased = key |> to_string() |> String.downcase()

    downcased in @sensitive_exact or
      Enum.any?(@sensitive_substrings, &String.contains?(downcased, &1))
  end

  @doc """
  `Sentry.PlugContext`'s `:remote_address_reader`: Sentry's own reader,
  except that a read of the update-feed route reports no address — see the
  moduledoc.
  """
  @spec remote_address(Plug.Conn.t()) :: String.t()
  def remote_address(%Plug.Conn{} = conn) do
    if update_feed_read?(conn),
      do: "",
      else: Sentry.PlugContext.default_remote_address_reader(conn)
  end

  @doc """
  `Sentry.PlugContext`'s `:header_scrubber`: Sentry's default (which drops
  `authorization`, `authentication` and `cookie`), plus the client-address
  headers on a read of the update-feed route.
  """
  @spec scrub_headers(Plug.Conn.t()) :: map()
  def scrub_headers(%Plug.Conn{} = conn) do
    headers = Sentry.PlugContext.default_header_scrubber(conn)

    if update_feed_read?(conn),
      do: Map.drop(headers, @client_address_headers),
      else: headers
  end

  defp update_feed_read?(%Plug.Conn{method: method, path_info: path})
       when method in ["GET", "HEAD"],
       do: path == @update_feed_path

  defp update_feed_read?(_conn), do: false
end
