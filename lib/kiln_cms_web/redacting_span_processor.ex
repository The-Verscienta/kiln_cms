defmodule KilnCMSWeb.RedactingSpanProcessor do
  @moduledoc """
  An OpenTelemetry span processor that takes credentials out of a span's URL
  attributes when the span starts, before any exporter can see them.

  The HTTP server instrumentation records the request path and query string
  on every server span, and some routes carry a credential in one or the
  other (a sign-in or invitation link's path segment, a `?preview_token=`).
  This processor rewrites:

    * `url.path` — the secret segments, by `KilnCMSWeb.RequestRedaction`;
    * `url.query` — the credential parameters' values;
    * `url.full`, `http.target`, `http.url` — both, by
      `KilnCMSWeb.UrlRedaction.url/1`.

  Each becomes `[FILTERED]` if it cannot be redacted. A span with none of
  these attributes is returned untouched, without a copy.

  It must be the **first** processor (`config/runtime/observability.exs`), so
  that no other processor sees a span before it is redacted, and the
  `span_processor` key must be unset, because it replaces the `processors`
  list. `KilnCMS.Config.Redaction.otel_problem/2` checks both at boot.
  """
  @behaviour :otel_span_processor

  require Record

  alias KilnCMSWeb.RequestRedaction
  alias KilnCMSWeb.UrlRedaction

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @path_keys [:"url.path", "url.path"]
  @query_keys [:"url.query", "url.query"]
  @url_keys [:"url.full", :"http.target", :"http.url", "url.full", "http.target", "http.url"]
  @keys @path_keys ++ @query_keys ++ @url_keys

  @doc "The attribute keys this processor rewrites."
  @spec keys() :: [atom() | String.t()]
  def keys, do: @keys

  @impl :otel_span_processor
  def on_start(_ctx, span, _config), do: redact_span(span)

  @impl :otel_span_processor
  def on_end(_span, _config), do: true

  @impl :otel_span_processor
  def force_flush(_config), do: :ok

  @doc """
  The span record with its URL attributes redacted. Never raises: a span it
  cannot read is returned as given.
  """
  @spec redact_span(tuple()) :: tuple()
  def redact_span(span) when Record.is_record(span, :span) do
    attributes = span(span, :attributes)

    case present(attributes) do
      [] -> span
      present -> span(span, attributes: redact_attributes(attributes, present))
    end
  rescue
    _error -> span
  end

  def redact_span(other), do: other

  defp present(attributes) do
    map = :otel_attributes.map(attributes)
    for key <- @keys, Map.has_key?(map, key), do: {key, Map.fetch!(map, key)}
  rescue
    _error -> []
  end

  defp redact_attributes(attributes, present) do
    Enum.reduce(present, attributes, fn {key, value}, acc ->
      :otel_attributes.set(key, redact(key, value), acc)
    end)
  end

  @doc """
  The redacted value of URL attribute `key`. `[FILTERED]` for a value that is
  not a string or cannot be redacted.
  """
  @spec redact(atom() | String.t(), term()) :: String.t()
  def redact(key, value) when is_binary(value) do
    cond do
      key in @path_keys -> RequestRedaction.redact_encoded_path(value)
      key in @query_keys -> UrlRedaction.query_string(value)
      true -> UrlRedaction.url(value)
    end
  rescue
    _error -> UrlRedaction.filtered()
  end

  def redact(_key, _value), do: UrlRedaction.filtered()
end
