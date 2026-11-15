defmodule KilnCMS.Config.Redaction do
  @moduledoc """
  Boot checks that the configuration keeping credentials out of logs and
  traces is still in place. `KilnCMS.Application` runs them and reports a
  problem with `KilnCMS.Config.Report.warn/2`.

    * **`:filter_parameters`.** Phoenix writes the params of a request, a
      socket connect, a channel join and a LiveView mount through
      Phoenix's param filter, which masks a key that *contains* one
      of the listed strings, case-sensitively. `credential_parameters/0` are
      the ones Kiln's own sockets and routes take a credential under; an
      overlay that replaces the list without them is reported.
    * **OpenTelemetry span processors.** `KilnCMSWeb.RedactingSpanProcessor`
      must be the first entry of `config :opentelemetry, :processors`, and
      `:span_processor` must be unset (it replaces the list).
  """

  @processor KilnCMSWeb.RedactingSpanProcessor

  # `Authorization` in both spellings: the match is case-sensitive, and a
  # socket's connect params are whatever the client sent.
  @credential_parameters ~w(password passphrase token secret authorization Authorization api_key unlock)

  @doc "The keys `:filter_parameters` must mask."
  @spec credential_parameters() :: [String.t()]
  def credential_parameters, do: @credential_parameters

  @doc """
  `current` (Phoenix's `:filter_parameters` value) checked against
  `credential_parameters/0`, with the result of
  `KilnCMS.Challenge.Registry.merge_filter_parameters/2`: `:unchanged`,
  `{:ok, list}` for a plain list with the missing keys appended, or
  `{:unfiltered, missing}` for any other shape that misses some.
  """
  @spec merge_filter_parameters(term()) ::
          :unchanged | {:ok, [String.t()]} | {:unfiltered, [String.t()]}
  def merge_filter_parameters(current) do
    KilnCMS.Challenge.Registry.merge_filter_parameters(current, @credential_parameters)
  end

  @doc """
  A problem with the OpenTelemetry processor configuration, or `nil`.
  `enabled?` is whether tracing is on; with it off nothing is checked.
  `env` is the `:opentelemetry` application environment.
  """
  @spec otel_problem(boolean(), keyword()) :: String.t() | nil
  def otel_problem(enabled?, env)

  def otel_problem(false, _env), do: nil

  def otel_problem(true, env) do
    cond do
      Keyword.get(env, :span_processor) != nil ->
        "config :opentelemetry, :span_processor is set, which replaces the :processors list " <>
          "and leaves out #{inspect(@processor)}: request URLs in traces are not redacted. " <>
          "Remove :span_processor and list the processors under :processors."

      not first?(Keyword.get(env, :processors)) ->
        "#{inspect(@processor)} is not the first entry of config :opentelemetry, " <>
          ":processors: request URLs in traces are not redacted before other processors " <>
          "see them. Put {#{inspect(@processor)}, %{}} first."

      true ->
        nil
    end
  end

  defp first?([{@processor, _config} | _rest]), do: true
  defp first?(_processors), do: false
end
