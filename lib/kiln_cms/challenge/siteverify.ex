defmodule KilnCMS.Challenge.Siteverify do
  @moduledoc """
  The `siteverify` exchange Turnstile and reCAPTCHA share (#2249): one
  form-encoded `POST` of the secret and the token, and a JSON answer of
  `success`, `error-codes`, `hostname` and (Turnstile) `action`.

  Answers in the provider contract (`Kiln.Challenge.Provider`): a pass is
  `{:ok, claims}` carrying the reported `hostname` and `action`, which the
  core then checks (`KilnCMS.Challenge.verify/4`). Two rules differ between
  the providers and are options here:

    * `require_action: true` — an answer that names no action is refused as
      `:action_mismatch`. Turnstile always reports the action the widget was
      drawn with, so one without it was not drawn by Kiln's widget.
    * `reject_score: true` — an answer carrying a `score` is refused as
      `:invalid`. That is reCAPTCHA v3 (or Enterprise), whose tokens pass on a
      threshold Kiln does not guess; a v2 key never reports one.

  The error codes both providers use map like this:

    * `timeout-or-duplicate` → `:expired`;
    * `missing-input-secret`, `invalid-input-secret` →
      `{:unavailable, :not_configured}` — the operator's key is wrong, which
      says nothing about the visitor;
    * `internal-error` → `{:unavailable, :http_status}`;
    * anything else (`invalid-input-response`, `bad-request`, a code not
      listed here) → `:invalid`, a refusal.

  A `5xx` or `429` is unavailable; any other non-`200` status is a refusal. A
  body that is not the expected JSON is unavailable.
  """

  @doc """
  Verifies `token` at `url` with the provider options the core passed
  (`:secret`, `:remote_ip`, `:post`) under `rules` (see the moduledoc).
  """
  @spec verify(String.t(), String.t(), keyword(), keyword()) :: Kiln.Challenge.Provider.result()
  def verify(url, token, opts, rules \\ []) do
    fields =
      [{"secret", Keyword.fetch!(opts, :secret)}, {"response", token}] ++
        case Keyword.get(opts, :remote_ip) do
          ip when is_binary(ip) -> [{"remoteip", ip}]
          _not_sent -> []
        end

    post = Keyword.fetch!(opts, :post)

    answered(post.(url, fields), rules)
  end

  defp answered({:ok, %{status: 200, body: body}}, rules), do: judge(body, rules)

  defp answered({:ok, %{status: status}}, _rules) when status == 429 or status >= 500,
    do: {:error, {:unavailable, :http_status}}

  # Any other status is the provider refusing the request itself: a refusal,
  # never a reason to admit.
  defp answered({:ok, %{status: _client_error}}, _rules), do: {:error, :invalid}
  defp answered({:error, :timeout}, _rules), do: {:error, {:unavailable, :timeout}}

  defp answered({:error, :malformed_response}, _rules),
    do: {:error, {:unavailable, :malformed_response}}

  defp answered({:error, _transport}, _rules), do: {:error, {:unavailable, :transport}}

  defp judge(body, rules) do
    case Jason.decode(body) do
      {:ok, %{"success" => true} = answer} -> accept(answer, rules)
      {:ok, %{"success" => false} = answer} -> refusal(Map.get(answer, "error-codes"))
      _not_an_answer -> {:error, {:unavailable, :malformed_response}}
    end
  end

  defp accept(answer, rules) do
    cond do
      Keyword.get(rules, :reject_score, false) and Map.has_key?(answer, "score") ->
        {:error, :invalid}

      Keyword.get(rules, :require_action, false) and not is_binary(answer["action"]) ->
        {:error, :action_mismatch}

      true ->
        {:ok, %{hostname: string(answer["hostname"]), action: string(answer["action"])}}
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_other), do: nil

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
