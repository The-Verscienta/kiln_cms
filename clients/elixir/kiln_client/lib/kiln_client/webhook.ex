defmodule KilnClient.Webhook do
  @moduledoc """
  Verify KilnCMS outbound webhook deliveries.

  Every delivery carries `x-kilncms-webhook-signature: t=<unix>,v1=<hex>`,
  where `v1` is the HMAC-SHA256 of `"<t>.<raw body>"` keyed by the endpoint's
  signing secret. Because the timestamp is inside the MAC, refusing a `t`
  outside a small window refuses a replayed capture. The body also carries a
  `delivery_id`, stable across retries, for dedupe inside the window. See
  Kiln's `docs/webhooks.md`.

  In a Phoenix controller, read the **raw** body (a re-encoded parse won't
  match) — for example with a `Plug.Parsers` `:body_reader` that stashes it:

      with [header] <- get_req_header(conn, KilnClient.Webhook.signature_header()),
           :ok <- KilnClient.Webhook.verify(secret, conn.assigns.raw_body, header) do
        delivery = Jason.decode!(conn.assigns.raw_body)
        # delivery["event"], delivery["delivery_id"], delivery["data"]
      end
  """

  @signature_header "x-kilncms-webhook-signature"
  @delivery_id_header "x-kilncms-delivery-id"
  @tolerance 300

  @doc "The header carrying the timestamped signature."
  def signature_header, do: @signature_header

  @doc "The header echoing the body's `delivery_id`."
  def delivery_id_header, do: @delivery_id_header

  @doc "The window, in seconds, the server documents: five minutes."
  def tolerance, do: @tolerance

  @doc """
  Verify `header` (the `x-kilncms-webhook-signature` value) against the raw
  `body`.

  Returns `:ok`, or `{:error, reason}` where `reason` is `:malformed` (the
  header does not parse), `:expired` (`t` is more than `:tolerance` seconds
  from `:now`) or `:mismatch` (no `v1` matches). Any one of several `v1`
  entries matching is enough.

  Options: `:tolerance` (seconds, default #{@tolerance}) and `:now` (unix
  seconds, default the system clock).
  """
  @spec verify(String.t(), iodata(), String.t() | nil, keyword()) ::
          :ok | {:error, :malformed | :expired | :mismatch}
  def verify(secret, body, header, opts \\ [])

  def verify(secret, body, header, opts) when is_binary(secret) and is_binary(header) do
    tolerance = Keyword.get(opts, :tolerance, @tolerance)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    with {:ok, timestamp, candidates} <- parse(header),
         :ok <- fresh(timestamp, now, tolerance) do
      expected =
        :hmac
        |> :crypto.mac(:sha256, secret, [Integer.to_string(timestamp), ".", body])
        |> Base.encode16(case: :lower)

      if Enum.any?(candidates, &constant_time_equal?(&1, expected)),
        do: :ok,
        else: {:error, :mismatch}
    end
  end

  def verify(_secret, _body, _header, _opts), do: {:error, :malformed}

  defp parse(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.split("=", parts: 2)))

    timestamps = for [k, v] <- pairs, k == "t", do: v
    candidates = for [k, v] <- pairs, k == "v1", v != "", do: String.downcase(v)

    with [raw] <- timestamps,
         {timestamp, ""} <- Integer.parse(raw),
         [_ | _] <- candidates do
      {:ok, timestamp, candidates}
    else
      _ -> {:error, :malformed}
    end
  end

  defp fresh(timestamp, now, tolerance) do
    if abs(now - timestamp) <= tolerance, do: :ok, else: {:error, :expired}
  end

  # `Plug.Crypto.secure_compare/2` without the Plug dependency.
  defp constant_time_equal?(a, b) when byte_size(a) == byte_size(b) do
    a
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(b))
    |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
    |> Kernel.==(0)
  end

  defp constant_time_equal?(_a, _b), do: false
end
