defmodule KilnCMS.Config.RedactionTest do
  @moduledoc """
  The configuration that keeps credentials out of logs and traces, and the
  boot checks that report it missing.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Config.Redaction

  @secret "T0kenSecretValue123"

  describe ":filter_parameters" do
    test "the configured list masks every credential key a socket or link sends" do
      params = %{
        "token" => @secret,
        "Authorization" => "Bearer #{@secret}",
        "authorization" => "Bearer #{@secret}",
        "api_key" => @secret,
        "secret" => @secret,
        "preview_token" => @secret,
        "vsn" => "2.0.0"
      }

      filtered = Phoenix.Logger.filter_values(params)

      refute inspect(filtered) =~ @secret
      assert filtered["vsn"] == "2.0.0"
    end

    test "the configured list already holds every required key" do
      assert Redaction.merge_filter_parameters(Application.get_env(:phoenix, :filter_parameters)) ==
               :unchanged
    end

    test "a plain list that drops one gets it back; another shape is reported" do
      assert {:ok, list} = Redaction.merge_filter_parameters(["password"])
      assert "token" in list and "Authorization" in list and "api_key" in list

      compiled = Phoenix.Logger.compile_filter(["password"])
      assert {:unfiltered, missing} = Redaction.merge_filter_parameters(compiled)
      assert "token" in missing

      assert Redaction.merge_filter_parameters({:keep, ["id"]}) == :unchanged
    end
  end

  describe "otel_problem/2" do
    @first {KilnCMSWeb.RedactingSpanProcessor, %{}}

    test "nothing is checked with tracing off" do
      assert Redaction.otel_problem(false, span_processor: :batch) == nil
    end

    test "the processor first, and no span_processor, is fine" do
      assert Redaction.otel_problem(true, processors: [@first, {:otel_batch_processor, %{}}]) ==
               nil
    end

    test "span_processor set replaces the list and is reported" do
      assert Redaction.otel_problem(true, span_processor: :batch, processors: [@first]) =~
               ":span_processor is set"
    end

    test "the processor missing or not first is reported" do
      assert Redaction.otel_problem(true, processors: [{:otel_batch_processor, %{}}]) =~
               "not the first entry"

      assert Redaction.otel_problem(true, processors: [{:otel_batch_processor, %{}}, @first]) =~
               "not the first entry"

      assert Redaction.otel_problem(true, []) =~ "not the first entry"
    end
  end
end
