defmodule KilnCMS.Challenge.Providers.Turnstile do
  @moduledoc """
  Cloudflare Turnstile (#2249), the built-in human-verification provider and
  the recommended one.

  Recommended over the alternatives because of what it adds to the auth pages'
  Content-Security-Policy: one origin, `https://challenges.cloudflare.com`, in
  `script-src` and `frame-src`, which serves nothing but the widget. A provider
  whose script lives on a general-purpose origin (reCAPTCHA's `www.google.com`)
  widens `script-src` to a host that also serves JSONP endpoints — a known way
  round a strict policy.

  ## Verification

  `POST https://challenges.cloudflare.com/turnstile/v0/siteverify` with the
  secret and the token (and the client address only when the operator turned
  `send_remote_ip` on). The answer is trusted only when it says `success` *and*
  names a hostname this deployment serves *and* the action the widget was drawn
  for — a token solved on someone else's page that uses the same site key, or on
  this deployment's form for another purpose, is refused.

  Cloudflare's error codes map onto the provider contract like this:

    * `timeout-or-duplicate` → `:expired` (a token is good for one verification
      and five minutes);
    * `missing-input-response`, `invalid-input-response`, `bad-request` and any
      code not listed here → `:invalid`, a refusal;
    * `missing-input-secret`, `invalid-input-secret` →
      `{:unavailable, :not_configured}` — the operator's key is wrong, which
      says nothing about the visitor;
    * `internal-error`, a 5xx or 429, or a body that is not the expected JSON →
      unavailable;
    * any other non-200 status (a 4xx) → `:invalid`, a refusal.
  """
  @behaviour KilnCMS.Challenge.Provider

  @origin "https://challenges.cloudflare.com"
  @verify_url @origin <> "/turnstile/v0/siteverify"

  @impl true
  def id, do: "turnstile"

  @impl true
  def label, do: "Cloudflare Turnstile"

  @impl true
  def script_url, do: @origin <> "/turnstile/v0/api.js?render=explicit"

  @impl true
  def global, do: "turnstile"

  @impl true
  def csp_sources, do: %{script_src: [@origin], frame_src: [@origin], connect_src: []}

  @impl true
  def verify(token, opts) do
    fields =
      [{"secret", Keyword.fetch!(opts, :secret)}, {"response", token}] ++
        case Keyword.get(opts, :remote_ip) do
          ip when is_binary(ip) -> [{"remoteip", ip}]
          _not_sent -> []
        end

    post = Keyword.fetch!(opts, :post)

    answered(post.(@verify_url, fields), opts)
  end

  defp answered({:ok, %{status: 200, body: body}}, opts), do: judge(body, opts)

  defp answered({:ok, %{status: status}}, _opts) when status == 429 or status >= 500,
    do: {:error, {:unavailable, :http_status}}

  # Any other status is Cloudflare refusing the request itself: a refusal,
  # never a reason to admit.
  defp answered({:ok, %{status: _client_error}}, _opts), do: {:error, :invalid}
  defp answered({:error, :timeout}, _opts), do: {:error, {:unavailable, :timeout}}

  defp answered({:error, :malformed_response}, _opts),
    do: {:error, {:unavailable, :malformed_response}}

  defp answered({:error, _transport}, _opts), do: {:error, {:unavailable, :transport}}

  defp judge(body, opts) do
    case Jason.decode(body) do
      {:ok, %{"success" => true} = answer} -> accept(answer, opts)
      {:ok, %{"success" => false} = answer} -> refusal(Map.get(answer, "error-codes"))
      _not_an_answer -> {:error, {:unavailable, :malformed_response}}
    end
  end

  defp accept(answer, opts) do
    cond do
      not hostname_ok?(answer["hostname"], Keyword.get(opts, :hostname?)) ->
        {:error, :hostname_mismatch}

      not action_ok?(answer["action"], Keyword.get(opts, :action)) ->
        {:error, :action_mismatch}

      true ->
        :ok
    end
  end

  defp hostname_ok?(_hostname, nil), do: true
  defp hostname_ok?(hostname, check) when is_binary(hostname), do: check.(hostname) == true
  defp hostname_ok?(_hostname, _check), do: false

  defp action_ok?(_action, nil), do: true
  defp action_ok?(action, expected), do: action == expected

  defp refusal(codes) when is_list(codes) do
    cond do
      Enum.any?(codes, &(&1 in ["missing-input-secret", "invalid-input-secret"])) ->
        {:error, {:unavailable, :not_configured}}

      "internal-error" in codes ->
        {:error, {:unavailable, :http_status}}

      "timeout-or-duplicate" in codes ->
        {:error, :expired}

      true ->
        {:error, :invalid}
    end
  end

  defp refusal(_codes), do: {:error, :invalid}
end
