defmodule KilnCMS.Federation.HttpSignature do
  @moduledoc """
  Draft-cavage HTTP Signatures, the authentication every ActivityPub
  implementation actually speaks (#491).

  The spec is an expired IETF draft that the fediverse standardised on anyway,
  so this implements what Mastodon implements: `rsa-sha256` over a
  `(request-target) host date digest` signing string, with the `Digest` header
  carrying `SHA-256=<base64>` of the exact body bytes.

  ## Signing and the pinned-IP problem

  `KilnCMS.SafeFetch` connects to a pinned IP literal and restores the real
  hostname in a `Host` header. The signature must cover that **real** host, not
  the IP — so `sign/4` takes the true URL, and the caller must not supply its
  own `host` header (SafeFetch appends the correct one, and a second would make
  the signed value ambiguous).

  ## Verifying, and what phase 1 does with it

  `verify/4` is here because the inbox needs it: an unsigned `Follow` is an
  anonymous claim that some actor wants your posts, and honouring it would let
  anyone subscribe anyone else's server to your firehose. It checks the
  signature against the key the *sending actor* publishes, and it checks the
  `Digest` against the raw body — a signature over a digest of different bytes
  than the ones parsed is the classic way this gets implemented wrong.

  `Date` is checked against a window (`@max_skew_seconds`) so a captured
  request cannot be replayed forever. That is weaker than a nonce store and
  deliberately so: nonce tracking across a cluster is phase-2 work, and the
  window is what Mastodon itself enforces.
  """

  @max_skew_seconds 300
  # A plain list, not `~w`: the sigil's own delimiter cannot survive the
  # parentheses in `(request-target)`.
  @signed_headers ["(request-target)", "host", "date", "digest"]

  # What an inbound signature must cover to be worth anything. `date` bounds a
  # replay, `digest` binds the signature to the body, and the other two bind it
  # to *this* request rather than any other the actor ever signed.
  @required_coverage ["(request-target)", "host", "date", "digest"]

  # `hs2019` is the draft's later spelling; both mean RSA-SHA256 in practice.
  @accepted_algorithms ["rsa-sha256", "hs2019"]

  @doc """
  Sign a request, returning the headers to send with it.

  `body` is signed as given — the same bytes must reach the wire, or the
  receiver's `Digest` check fails.
  """
  @spec sign(String.t(), String.t(), iodata(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def sign(url, key_id, body, opts \\ []) do
    uri = URI.parse(url)
    body = IO.iodata_to_binary(body)

    with {:ok, private_key} <- private_key(opts) do
      date = Keyword.get_lazy(opts, :date, &http_date/0)
      digest = "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))
      host = host_header(uri)

      signing_string = signing_string(request_target(uri), host, date, digest)

      signature =
        signing_string
        |> :public_key.sign(:sha256, private_key)
        |> Base.encode64()

      header =
        ~s(keyId="#{key_id}",algorithm="rsa-sha256",) <>
          ~s(headers="#{Enum.join(@signed_headers, " ")}",signature="#{signature}")

      # No `host` header here on purpose — SafeFetch appends the real one, and
      # supplying a second would leave the signed value ambiguous.
      {:ok,
       [
         {"date", date},
         {"digest", digest},
         {"signature", header},
         {"content-type", "application/activity+json"}
       ]}
    end
  end

  @doc """
  Verify an inbound request's signature against `public_key_pem`.

  `headers` is the request's header list (as Plug gives it: lowercase names).
  `body` must be the **raw** bytes, not a re-encoded parse of them.
  """
  @spec verify(
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          binary(),
          String.t(),
          keyword()
        ) ::
          :ok | {:error, String.t()}
  def verify(method, request_path, headers, body, public_key_pem, opts \\ []) do
    with {:ok, params} <- parse_signature(header(headers, "signature")),
         :ok <- check_algorithm(params),
         {:ok, signature} <- decode_signature(params),
         :ok <- check_date(header(headers, "date")),
         :ok <- check_digest(header(headers, "digest"), body),
         {:ok, public_key} <- public_key(public_key_pem),
         {:ok, signing_string} <- rebuild(params, method, request_path, headers, opts) do
      if :public_key.verify(signing_string, :sha256, signature, public_key) do
        :ok
      else
        {:error, "signature does not verify"}
      end
    end
  end

  @doc """
  Record a **verified** signature in the replay nonce store (#967), refusing it
  if it has been seen already.

  Called by the inbox after `verify/6` says `:ok`, never before. The row's
  expiry is twice the date window, so a signature is held for as long as its
  `Date` could still verify. `:ok`, or `{:error, "signature replayed"}`; a
  store that cannot be written answers `:ok` and logs — a nonce-store outage
  must not take the inbox down, and the date window still bounds replay to
  what phase 1 accepted.
  """
  @spec record_seen([{String.t(), String.t()}]) :: :ok | {:error, String.t()}
  def record_seen(headers) do
    with {:ok, params} <- parse_signature(header(headers, "signature")),
         {:ok, signature} <- Map.fetch(params, "signature") do
      hash = :crypto.hash(:sha256, signature) |> Base.encode16(case: :lower)
      expires_at = DateTime.add(DateTime.utc_now(), 2 * @max_skew_seconds, :second)

      %{signature_hash: hash, expires_at: expires_at}
      |> KilnCMS.Federation.record_seen_signature(authorize?: false)
      |> interpret_record()
    else
      _ -> {:error, "signature header is malformed"}
    end
  rescue
    error -> log_nonce_failure(error)
  end

  defp interpret_record({:ok, _row}), do: :ok

  # The primary-key conflict is the replay; anything else is the store failing.
  defp interpret_record({:error, %Ash.Error.Invalid{errors: errors}}) do
    if Enum.any?(errors, &match?(%{field: :signature_hash}, &1)),
      do: {:error, "signature replayed"},
      else: log_nonce_failure(errors)
  end

  defp interpret_record({:error, error}), do: log_nonce_failure(error)

  defp log_nonce_failure(detail) do
    require Logger

    Logger.warning(
      "federation replay store unavailable, accepting on the date window: #{inspect(detail)}"
    )

    :ok
  end

  @doc "The `keyId` a signature header claims, without verifying anything."
  @spec key_id([{String.t(), String.t()}]) :: {:ok, String.t()} | {:error, String.t()}
  def key_id(headers) do
    with {:ok, params} <- parse_signature(header(headers, "signature")) do
      case Map.fetch(params, "keyid") do
        {:ok, key_id} -> {:ok, key_id}
        :error -> {:error, "signature header has no keyId"}
      end
    end
  end

  @doc "An RFC 7231 IMF-fixdate, which is what the `Date` header must carry."
  @spec http_date(DateTime.t()) :: String.t()
  def http_date(datetime \\ DateTime.utc_now()) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end

  # ── signing string ──────────────────────────────────────────────────────────

  defp signing_string(request_target, host, date, digest) do
    Enum.join(
      [
        "(request-target): #{request_target}",
        "host: #{host}",
        "date: #{date}",
        "digest: #{digest}"
      ],
      "\n"
    )
  end

  # Rebuild from the header list the sender said it signed, in that order — not
  # from our own fixed list. A sender is free to sign a different set, and
  # verifying against the set *we* would have chosen would reject valid
  # requests (and, worse, could verify a string the sender never signed).
  #
  # But the declared set must still *cover* the request. `@required_coverage`
  # is the floor, and it is the whole security property: without `digest` in
  # the signed set, a signature is not bound to a body at all. `check_digest/2`
  # binds the Digest **header** to the bytes, so an attacker who captures any
  # signed request from an actor can replay it inside the skew window with
  # `headers="date"`, an arbitrary activity, and a freshly computed Digest —
  # the signing string is unchanged, the signature verifies, and the substituted
  # activity executes as that actor. Mastodon requires the same four for POSTs.
  defp rebuild(params, method, request_path, headers, opts) do
    names = params |> Map.get("headers", "date") |> String.split(" ", trim: true)

    if Enum.all?(@required_coverage, &(&1 in names)) do
      lines =
        Enum.map(names, fn
          "(request-target)" ->
            "(request-target): #{String.downcase(method)} #{request_path}"

          # `host` comes from the caller, not the header list. Plug puts the
          # authority on `conn.host` rather than in `req_headers`, and HTTP/2
          # has no `Host` header at all — only an `:authority` pseudo-header the
          # adapter has already turned into `conn.host`. Reading the header would
          # rebuild an empty host and refuse every valid HTTP/2 request.
          "host" ->
            "host: #{Keyword.get(opts, :host) || header(headers, "host")}"

          name ->
            "#{name}: #{header(headers, name)}"
        end)

      {:ok, Enum.join(lines, "\n")}
    else
      missing = Enum.reject(@required_coverage, &(&1 in names))
      {:error, "signature does not cover #{Enum.join(missing, ", ")}"}
    end
  end

  defp request_target(uri) do
    query = if uri.query in [nil, ""], do: "", else: "?" <> uri.query
    "post #{uri.path || "/"}#{query}"
  end

  defp host_header(uri) do
    default_port = if uri.scheme == "https", do: 443, else: 80
    if uri.port in [nil, default_port], do: uri.host, else: "#{uri.host}:#{uri.port}"
  end

  # ── parsing ─────────────────────────────────────────────────────────────────

  defp parse_signature(nil), do: {:error, "missing signature header"}

  defp parse_signature(value) do
    params =
      ~r/(\w+)="([^"]*)"/
      |> Regex.scan(value)
      |> Map.new(fn [_all, key, val] -> {String.downcase(key), val} end)

    if map_size(params) == 0, do: {:error, "malformed signature header"}, else: {:ok, params}
  end

  # Today this can only be RSA — `Keys.rsa_public_key_from_pem/1` refuses
  # anything else, so a bogus `algorithm` cannot select a different primitive.
  # Checked anyway, so the property is stated here rather than inherited from a
  # key parser two modules away that has no idea it is load-bearing.
  defp check_algorithm(params) do
    case Map.get(params, "algorithm") do
      nil -> :ok
      algorithm when algorithm in @accepted_algorithms -> :ok
      other -> {:error, "unsupported signature algorithm #{inspect(other)}"}
    end
  end

  defp decode_signature(params) do
    with {:ok, encoded} <- Map.fetch(params, "signature"),
         {:ok, raw} <- Base.decode64(encoded) do
      {:ok, raw}
    else
      _other -> {:error, "signature is not valid base64"}
    end
  end

  defp check_date(nil), do: {:error, "missing date header"}

  defp check_date(value) do
    case parse_http_date(value) do
      {:ok, sent} ->
        if abs(DateTime.diff(DateTime.utc_now(), sent)) <= @max_skew_seconds,
          do: :ok,
          else: {:error, "date outside the accepted window"}

      :error ->
        {:error, "unparseable date header"}
    end
  end

  # `Digest` is compared against the raw body. Verifying a signature over a
  # digest of bytes other than the ones acted on is the classic way this is
  # implemented wrong — it lets a proxy swap the payload under a valid header.
  defp check_digest(nil, _body), do: {:error, "missing digest header"}

  defp check_digest(value, body) do
    expected = Base.encode64(:crypto.hash(:sha256, body))

    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value({:error, "digest does not match body"}, &matching_digest(&1, expected))
  end

  defp matching_digest(part, expected) do
    case String.split(part, "=", parts: 2) do
      [algorithm, digest] -> if sha256_match?(algorithm, digest, expected), do: :ok
      _other -> nil
    end
  end

  # `secure_compare` rather than `==`: the comparison is against a value an
  # attacker supplies and can time.
  defp sha256_match?(algorithm, digest, expected) do
    String.downcase(algorithm) in ["sha-256", "sha256"] and
      Plug.Crypto.secure_compare(digest, expected)
  end

  defp public_key(pem) do
    case KilnCMS.Keys.rsa_public_key_from_pem(pem) do
      {:ok, key} -> {:ok, key}
      {:error, _reason} -> {:error, "could not read the sending actor's public key"}
    end
  end

  defp private_key(opts) do
    case Keyword.fetch(opts, :private_key_pem) do
      {:ok, pem} when is_binary(pem) ->
        case KilnCMS.Keys.rsa_private_key(pem) do
          {:ok, key} -> {:ok, key}
          {:error, reason} -> {:error, "unusable signing key: #{inspect(reason)}"}
        end

      _other ->
        {:error, "no signing key available"}
    end
  end

  defp header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # IMF-fixdate only. `DateTime.from_iso8601` cannot read it, and the two
  # obsolete formats RFC 7231 also permits are not what any fediverse server
  # sends — accepting them would widen the parser for no real traffic.
  defp parse_http_date(value) do
    with [_day, day, month, year, time, _zone] <-
           String.split(String.trim(value), [" ", ", "], trim: true),
         month_index when month_index != nil <- Enum.find_index(@months, &(&1 == month)),
         [hour, minute, second] <- String.split(time, ":"),
         {:ok, date} <- Date.new(String.to_integer(year), month_index + 1, String.to_integer(day)),
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _other -> :error
    end
  rescue
    _error -> :error
  end
end
