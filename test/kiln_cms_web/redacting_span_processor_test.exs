defmodule KilnCMSWeb.RedactingSpanProcessorTest do
  @moduledoc """
  A span's URL attributes lose their credentials when the span starts, before
  any exporter sees it.
  """
  use ExUnit.Case, async: true

  require Record

  alias KilnCMSWeb.RedactingSpanProcessor

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  # The SDK's tracer record lives in its `src/`, not its `include/`.
  Record.defrecordp(
    :tracer,
    Record.extract(:tracer,
      from: Path.join(Mix.Project.deps_paths()[:opentelemetry], "src/otel_tracer.hrl")
    )
  )

  @secret "T0kenSecretValue123"

  defp span_with(attributes) do
    span(attributes: :otel_attributes.new(attributes, 128, :infinity), name: "GET")
  end

  defp attributes(span), do: span |> span(:attributes) |> :otel_attributes.map()

  test "url.path, url.query, url.full, http.target and http.url are redacted" do
    span =
      span_with(%{
        "url.path": "/magic_link/#{@secret}",
        "url.query": "preview_token=#{@secret}&page=2",
        "url.full": "https://example.com/password-reset/#{@secret}?unlock=#{@secret}",
        "http.target": "/preview/#{@secret}?x=1",
        "http.url": "https://example.com/ws/collab/websocket?token=#{@secret}",
        "http.request.method": "GET"
      })

    redacted =
      span |> then(&RedactingSpanProcessor.on_start(:otel_ctx.new(), &1, %{})) |> attributes()

    refute inspect(redacted) =~ @secret
    assert redacted[:"url.path"] == "/magic_link/[FILTERED]"
    assert redacted[:"url.query"] == "preview_token=[FILTERED]&page=2"
    assert redacted[:"http.target"] == "/preview/[FILTERED]?x=1"
    assert redacted[:"http.request.method"] == "GET"
  end

  test "string keys are redacted the same way" do
    span = span_with(%{"url.path" => "/newsletter/confirm/#{@secret}"})
    assert attributes(RedactingSpanProcessor.redact_span(span))["url.path"] =~ "[FILTERED]"
  end

  test "a span with no URL attributes comes back as the same term" do
    span = span_with(%{"db.statement": "SELECT 1"})
    assert RedactingSpanProcessor.on_start(:otel_ctx.new(), span, %{}) === span

    bare = span(attributes: :undefined)
    assert RedactingSpanProcessor.on_start(:otel_ctx.new(), bare, %{}) === bare
  end

  test "a value it cannot redact is filtered, not passed through" do
    span = span_with(%{"url.full": [1, 2, 3]})
    assert attributes(RedactingSpanProcessor.redact_span(span))[:"url.full"] == "[FILTERED]"
  end

  test "an ordinary path is left as it was" do
    span = span_with(%{"url.path": "/blog/hello", "url.query": "page=2"})
    redacted = attributes(RedactingSpanProcessor.redact_span(span))
    assert redacted[:"url.path"] == "/blog/hello"
    assert redacted[:"url.query"] == "page=2"
  end

  test "on_end and force_flush are no-ops" do
    assert RedactingSpanProcessor.on_end(span_with(%{}), %{}) == true
    assert RedactingSpanProcessor.force_flush(%{}) == :ok
  end

  test "a span started through a real tracer reaches the end processors redacted" do
    parent = self()
    ctx = :otel_ctx.new()

    tracer =
      tracer(
        module: :otel_tracer_default,
        sampler: :otel_sampler.new(:always_on),
        on_start_processors: fn ctx, span -> RedactingSpanProcessor.on_start(ctx, span, %{}) end,
        on_end_processors: fn span ->
          send(parent, {:ended, span})
          true
        end,
        id_generator: :otel_id_generator,
        instrumentation_scope: :undefined
      )

    span_ctx =
      :otel_tracer_default.start_span(ctx, {:otel_tracer_default, tracer}, "GET", %{
        kind: :server,
        links: [],
        start_time: :opentelemetry.timestamp(),
        attributes: %{
          "url.path": "/auth/invite/#{@secret}",
          "url.query": "token=#{@secret}"
        }
      })

    :otel_span.end_span(span_ctx)

    assert_receive {:ended, ended}
    refute inspect(attributes(ended)) =~ @secret
    assert attributes(ended)[:"url.path"] == "/auth/invite/[FILTERED]"
  end
end
