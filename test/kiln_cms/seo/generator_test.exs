defmodule KilnCMS.Seo.GeneratorTest do
  @moduledoc """
  The `KilnCMS.Seo` facade: gating, degradation and the guarantees that hold
  before any provider is involved.

  Swaps global app env, so `async: false`. **No test here touches the network** —
  the shipped ReqLLM adapter is never selected.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Seo
  alias KilnCMS.Seo.Document

  @long_body String.duplicate("The kiln firing process takes patience and care. ", 20)

  defp put_seo(overrides) do
    previous = Application.get_env(:kiln_cms, KilnCMS.Seo, [])
    Application.put_env(:kiln_cms, KilnCMS.Seo, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Seo, previous) end)
  end

  defp document(attrs \\ %{}) do
    Document.new(Map.merge(%{title: "Kiln firing", body_text: @long_body, locale: "en"}, attrs))
  end

  describe "disabled by default" do
    test "a default install reports drafting off and sends nothing" do
      # No put_seo/1 here on purpose: this is the shipped config.
      refute Seo.enabled?()
      refute Seo.egress?()
      assert Seo.generator() == nil
      assert {:error, :disabled} = Seo.draft(document())
    end

    test "a generator without a model is still disabled" do
      put_seo(generator: KilnCMS.StubSeoGenerator, model: nil)
      refute Seo.enabled?()
      assert {:error, :disabled} = Seo.draft(document())
    end
  end

  describe "egress classification" do
    test "on-prem providers at their default local daemon are not egress" do
      for spec <- ["ollama:llama3.1", "vllm:mistral-7b"] do
        put_seo(generator: KilnCMS.StubSeoGenerator, model: spec, base_url: nil)
        assert Seo.enabled?()
        refute Seo.egress?()
      end
    end

    test "an on-prem provider pointed at a REMOTE host is egress" do
      # The whole point: `base_url` is overridable — the mechanism docs/seo.md
      # recommends for on-prem — so classifying by provider name alone reported
      # "no egress" while every page body left the deployment, silencing both
      # the boot warning and the editor notice.
      put_seo(
        generator: KilnCMS.StubSeoGenerator,
        model: "ollama:llama3.1",
        base_url: "https://llm.vendor.example"
      )

      assert Seo.egress?()
      assert Seo.endpoint_host() == "llm.vendor.example"
    end

    test "an on-prem provider on a private network host is not egress" do
      put_seo(
        generator: KilnCMS.StubSeoGenerator,
        model: "ollama:llama3.1",
        base_url: "http://10.0.0.5:11434"
      )

      refute Seo.egress?()
    end

    test "hosted providers are egress" do
      put_seo(generator: KilnCMS.StubSeoGenerator, model: "anthropic:claude-sonnet-5")
      assert Seo.egress?()
      assert Seo.provider() == "anthropic"
    end

    test "an unrecognized provider errs toward egress" do
      # Safer to over-warn about a provider we don't know than to quietly
      # promise an operator their content stayed home.
      put_seo(generator: KilnCMS.StubSeoGenerator, model: "some-new-vendor:model-x")
      assert Seo.egress?()
    end
  end

  describe "draft/2" do
    setup do
      put_seo(generator: KilnCMS.StubSeoGenerator, model: "stub:stub")
      :ok
    end

    test "normalizes whatever the generator returns and stamps the model" do
      assert {:ok, draft} = Seo.draft(document())

      assert draft.seo_title == "SEO: Kiln firing"
      assert draft.model == "stub:stub"
      # Normalization ran: keywords are downcased and capped.
      assert draft.seo_keywords == ["stub keyphrase", "second"]
    end

    test "refuses to draft from a near-empty document" do
      # Generating meta for a page with no content is burning tokens to
      # hallucinate, so it never reaches the provider.
      assert {:error, :too_short} = Seo.draft(document(%{body_text: "Three words only."}))
    end

    test "the record's locale travels with the document" do
      assert {:ok, draft} = Seo.draft(document(%{locale: "fr"}))
      assert draft.seo_description =~ "in fr"
    end
  end

  describe "degradation" do
    test "a generator error is passed through, not raised" do
      put_seo(generator: KilnCMS.StubSeoGenerator.Failing, model: "stub:stub")
      assert {:error, :boom} = Seo.draft(document())
    end

    test "a generator that raises degrades to {:error, :crashed}" do
      put_seo(generator: KilnCMS.StubSeoGenerator.Raising, model: "stub:stub")
      assert {:error, :crashed} = Seo.draft(document())
    end
  end

  describe "telemetry" do
    setup do
      put_seo(generator: KilnCMS.StubSeoGenerator, model: "stub:stub")
      :ok
    end

    test "emits a stop event carrying usage and provider, so spend is visible" do
      handler = "seo-draft-test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:kiln_cms, :seo, :draft, :stop],
        fn _event, measurements, metadata, _ ->
          send(parent, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _draft} = Seo.draft(document(), org_id: "org-1")

      assert_receive {:telemetry, measurements, metadata}
      assert measurements.input_tokens == 100
      assert measurements.output_tokens == 20
      assert metadata.outcome == :ok
      assert metadata.provider == "stub"
      assert metadata.org_id == "org-1"
    end
  end

  describe "rate limiting" do
    setup do
      put_seo(
        generator: KilnCMS.StubSeoGenerator,
        model: "stub:stub",
        per_user_limit: {2, :timer.minutes(1)},
        per_org_limit: {100, :timer.hours(1)}
      )

      :ok
    end

    test "the per-user bucket stops a runaway caller" do
      user = "user-#{System.unique_integer([:positive])}"

      assert {:ok, _} = Seo.draft(document(), user_id: user)
      assert {:ok, _} = Seo.draft(document(), user_id: user)
      assert {:error, {:rate_limited, retry_after}} = Seo.draft(document(), user_id: user)
      assert retry_after > 0
    end

    test "callers with no request context are not blocked by a limiter that can't identify them" do
      for _ <- 1..5, do: assert({:ok, _} = Seo.draft(document()))
    end
  end
end
