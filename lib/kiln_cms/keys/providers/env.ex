defmodule KilnCMS.Keys.Providers.Env do
  @moduledoc """
  Key provider reading PEM material from an environment variable
  (config: `%{"var" => "DKIM_PRIVATE_KEY"}`).

  ## Newlines in a `.env` value (#609)

  The keys this serves are multi-line PKCS#1 PEMs, and most `.env` files can't
  carry an embedded newline — so an operator reaches for the escaped one-line
  form, optionally quoted:

      KILN_PROVENANCE_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----\\nMIIE…\\n-----END RSA PRIVATE KEY-----"

  Read verbatim, that literal `\\n` makes `:public_key.pem_decode/1` return `[]`
  → the key silently fails to load and every anchor writes unsigned. So the
  value is normalized on the way out: surrounding quotes are stripped and a
  literal `\\n`/`\\r\\n` becomes a real newline. A value that already carries
  real newlines (docker-compose v2's double-quoted multi-line form, or a
  process-manager that preserves them) has no literal `\\n` to touch and is
  returned unchanged.

  Normalization runs for every key this provider serves, not only PEMs (it also
  backs the DKIM key and the billing secret/webhook keys). That is safe: a
  single-line secret with no literal `\\n` and no wrapping quotes — a Stripe
  `sk_live_…`/`whsec_…`, say — is returned byte-for-byte, and stripping quotes
  an operator wrapped it in is if anything a fix.
  """
  @behaviour KilnCMS.Keys.Provider

  @default_var "DKIM_PRIVATE_KEY"

  @impl true
  def fetch(config) do
    var = var(config)

    case System.get_env(var) do
      value when value in [nil, ""] -> {:error, {:env_var_unset, var}}
      value -> {:ok, normalize(value)}
    end
  end

  @impl true
  def writable?, do: false

  defp var(config), do: config["var"] || @default_var

  # Turn the `.env`-friendly escaped form back into a real PEM. Order matters:
  # unquote first (the quotes wrap the escaped body), then unescape `\r\n`
  # before the bare `\n`/`\r` so a Windows-style pair doesn't leave a stray CR.
  defp normalize(value) do
    value
    |> unquote_wrapping()
    |> String.replace("\\r\\n", "\n")
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\n")
  end

  defp unquote_wrapping(<<?", _::binary>> = value) do
    if String.length(value) >= 2 and String.ends_with?(value, ~s(")),
      do: String.slice(value, 1..-2//1),
      else: value
  end

  defp unquote_wrapping(value), do: value
end
