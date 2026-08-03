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
  """

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
end
