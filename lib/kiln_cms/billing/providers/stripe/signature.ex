defmodule KilnCMS.Billing.Providers.Stripe.Signature do
  @moduledoc """
  `Stripe-Signature` verification: HMAC-SHA256 over the **raw** request bytes.

  The header looks like `t=1699999999,v1=<hex>,v1=<hex>` — more than one `v1`
  while a signing secret is being rotated, and possibly a legacy `v0` we ignore.
  The signed payload is exactly `"<t>.<raw_body>"`, so the raw bytes matter:
  re-encoding the parsed JSON does not reproduce them (key order, whitespace and
  unicode escaping all differ), which is why
  `KilnCMSWeb.Plugs.RawBodyReader` exists.

  Verification happens **before** JSON decoding, so unauthenticated bytes never
  reach the decoder's allocation path.

  The HMAC shape matches the repo's outbound webhook signer
  (`KilnCMS.Webhooks.signature/2`) so inbound and outbound read identically.
  """

  # Stripe's own default tolerance. Bounds replay of a captured request; the
  # durable defence is the event-id dedupe in `KilnCMS.Billing.WebhookEvent`.
  @default_tolerance_seconds 300

  @doc """
  Verify `raw_body` against `header` and return the decoded event.

  Options:

    * `:tolerance` — permitted clock skew in seconds (default #{@default_tolerance_seconds}).
    * `:now` — unix seconds, injectable so tests pin time instead of sleeping.
  """
  @spec verify(binary(), String.t() | nil, String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :invalid_signature
             | :timestamp_out_of_tolerance
             | :malformed_signature
             | :malformed_payload}
  def verify(raw_body, header, secret, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance_seconds)
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, timestamp, signatures} <- parse(header),
         :ok <- check_tolerance(timestamp, now, tolerance),
         :ok <- check_signature(raw_body, timestamp, signatures, secret) do
      decode(raw_body)
    end
  end

  @doc "The signed payload for `timestamp` and `raw_body` — exposed for tests."
  @spec signed_payload(integer() | String.t(), binary()) :: binary()
  def signed_payload(timestamp, raw_body), do: "#{timestamp}." <> raw_body

  @doc "Lowercase hex HMAC-SHA256 of the signed payload, keyed by `secret`."
  @spec sign(integer() | String.t(), binary(), String.t()) :: String.t()
  def sign(timestamp, raw_body, secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, signed_payload(timestamp, raw_body))
    |> Base.encode16(case: :lower)
  end

  # A nil/blank header is a client error, not a crash.
  defp parse(header) when header in [nil, ""], do: {:error, :malformed_signature}

  defp parse(header) when is_binary(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    timestamp =
      Enum.find_value(parts, fn
        ["t", value] -> parse_timestamp(value)
        _other -> nil
      end)

    signatures = for ["v1", value] <- parts, value != "", do: String.downcase(value)

    if is_integer(timestamp) and signatures != [] do
      {:ok, timestamp, signatures}
    else
      {:error, :malformed_signature}
    end
  end

  defp parse(_header), do: {:error, :malformed_signature}

  defp parse_timestamp(value) do
    case Integer.parse(value) do
      {seconds, ""} -> seconds
      _other -> nil
    end
  end

  # Reject far-future timestamps too, not just stale ones: a clock-skewed or
  # forged `t` must not buy an attacker an unbounded replay window.
  defp check_tolerance(timestamp, now, tolerance) do
    if abs(now - timestamp) <= tolerance,
      do: :ok,
      else: {:error, :timestamp_out_of_tolerance}
  end

  defp check_signature(raw_body, timestamp, signatures, secret) do
    expected = sign(timestamp, raw_body, secret)

    # `reduce` with `or acc` rather than `Enum.any?`: every candidate is
    # compared, so the number of rotation candidates tried is not observable in
    # the response time.
    matched? =
      Enum.reduce(signatures, false, fn candidate, acc ->
        secure_equal?(candidate, expected) or acc
      end)

    if matched?, do: :ok, else: {:error, :invalid_signature}
  end

  # `:crypto.hash_equals/2` raises on a size mismatch, so a malformed
  # (truncated, odd-length) candidate must be length-checked first — otherwise a
  # bad header is a 500 instead of a 400.
  defp secure_equal?(candidate, expected) when byte_size(candidate) == byte_size(expected),
    do: :crypto.hash_equals(candidate, expected)

  defp secure_equal?(_candidate, _expected), do: false

  # Only reached once the signature is verified.
  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = event} -> {:ok, event}
      _other -> {:error, :malformed_payload}
    end
  end
end
