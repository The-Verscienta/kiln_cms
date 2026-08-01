defmodule KilnCMS.LLM do
  @moduledoc """
  Provider classification shared by every optional LLM feature (#60).

  Kiln has more than one place a model can be plugged in — `KilnCMS.Seo`
  drafts metadata, `KilnCMS.Assist` drafts body prose — and each carries its
  own switch, its own model and its own budget. What they must *not* each carry
  is their own copy of the question "does turning this on send content off the
  box?", because that answer is subtle enough to get wrong in one place and
  right in another.

  So the classification lives here once and both features delegate to it.
  Nothing in this module reads configuration; callers pass the model spec they
  resolved from their own config key, which is what keeps the switches separate.

  ## Why the host, not the provider name

  `req_llm` lets any provider's `base_url` be overridden — the very mechanism
  the docs recommend for on-prem — so keying on the name alone was wrong in the
  one direction that matters: `ollama:` pointed at a rented GPU box reported
  "no egress" while every page body left the deployment.

  `egress?/2` is therefore `false` only when the resolved host is loopback or a
  private address. An unknown host reads as egress: over-warning is cheap, and
  quietly promising an operator their content stayed home is not.
  """

  # Providers that run inside the deployment. Anything else is egress.
  @local_providers ~w(ollama vllm)

  @doc ~S"""
  The provider name from a `"provider:model"` spec.

      iex> KilnCMS.LLM.provider("ollama:llama3.1")
      "ollama"
  """
  @spec provider(String.t() | nil) :: String.t() | nil
  def provider(nil), do: nil
  def provider(spec), do: spec |> to_string() |> String.split(":", parts: 2) |> hd()

  @doc """
  The endpoint host `model_spec` would talk to, as configured.

  `base_url` is the feature's own override, checked first; `req_llm`'s
  per-provider setting is checked next; failing both, the provider's documented
  default. `nil` when the provider's default isn't visible from here.
  """
  @spec endpoint_host(String.t() | nil, String.t() | nil) :: String.t() | nil
  def endpoint_host(model_spec, base_url \\ nil) do
    name = provider(model_spec)

    with nil <- host_from(base_url),
         nil <- host_from(provider_base_url(name)) do
      default_host_for(name)
    end
  end

  @doc """
  Whether content sent to `model_spec` leaves the deployment.

  `false` for an unconfigured feature (nothing is sent at all) and for a
  loopback or private endpoint. Everything else, including an unresolvable
  host, is treated as egress.
  """
  @spec egress?(String.t() | nil, String.t() | nil) :: boolean()
  def egress?(model_spec, base_url \\ nil)
  def egress?(nil, _base_url), do: false

  def egress?(model_spec, base_url) do
    case endpoint_host(model_spec, base_url) do
      nil -> true
      host -> not (loopback?(host) or private?(host))
    end
  end

  # An operator may override the endpoint in req_llm's own config. The shape
  # req_llm actually reads is `Application.get_env(:req_llm, :<provider>)`, a
  # keyword list carrying `:base_url` — see
  # `ReqLLM.Provider.Options.effective_base_url/3` and the `## Configuration`
  # section of each provider module. An earlier version of this looked for a
  # flat `:<provider>_base_url` key, which req_llm never defines, so a real
  # on-prem override was invisible here and `egress?/2` reported "stayed home"
  # about a request going to a vendor.
  #
  # Both shapes are accepted now: the flat one costs nothing and an operator
  # who wrote it should not be told their content is local when it isn't.
  #
  # Keys are matched by comparing existing atoms' names rather than
  # interpolating one (`:"#{name}"`): the provider name comes from config, and
  # minting atoms from configurable input is the pattern sobelow's
  # DOS.BinToAtom check exists to stop.
  defp provider_base_url(nil), do: nil

  defp provider_base_url(name) do
    :req_llm
    |> Application.get_all_env()
    |> Enum.find_value(&matching_env(&1, name))
  end

  defp matching_env({key, value}, name) do
    case Atom.to_string(key) do
      ^name -> value |> nested_base_url() |> normalize_url()
      other -> if other == name <> "_base_url", do: normalize_url(value)
    end
  end

  defp nested_base_url(value) when is_list(value) do
    if Keyword.keyword?(value), do: Keyword.get(value, :base_url)
  end

  defp nested_base_url(%{} = value), do: Map.get(value, :base_url)
  defp nested_base_url(_value), do: nil

  defp normalize_url(url) when is_binary(url) and url != "", do: url
  defp normalize_url(_url), do: nil

  defp host_from(nil), do: nil

  defp host_from(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host

      # A scheme-less value — `gpu.example.com:11434`, `ollama.corp.example` —
      # parses with a nil host and the whole string in `:path`, which fell
      # through to the provider's *default* host and reported a remote box as
      # local. Re-parse it as an authority so the operator gets the warning.
      _ ->
        authority_host(url)
    end
  end

  # `URI.parse/1` is permissive about what an authority may contain — "not a
  # url" parses to that whole string as a host — so the result has to look like
  # a hostname or an IP literal before it is trusted. Rejecting it here means
  # an unusable value falls through to the provider default rather than
  # becoming a host that happens not to be loopback.
  @host_pattern ~r/^(?:\[[0-9A-Fa-f:.]+\]|[\p{L}\p{N}][\p{L}\p{N}._-]*)$/u

  defp authority_host(url) do
    case URI.parse("//" <> String.trim_leading(url, "/")) do
      %URI{host: host} when is_binary(host) and host != "" ->
        if Regex.match?(@host_pattern, host), do: host

      _ ->
        nil
    end
  end

  # With no override, the on-prem providers default to a local daemon; every
  # other provider defaults to its own cloud API.
  defp default_host_for(name) when name in @local_providers, do: "localhost"
  defp default_host_for(_name), do: nil

  defp loopback?(host), do: host in ~w(localhost 127.0.0.1 ::1 0.0.0.0)

  defp private?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {127, _, _, _}} -> true
      _ -> String.ends_with?(host, ".local") or String.ends_with?(host, ".internal")
    end
  end
end
