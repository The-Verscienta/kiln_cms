defmodule KilnCMS.Ask.GeneratorTest do
  @moduledoc """
  The `KilnCMS.Ask` generation half: gating, egress classification, output
  normalization, budgets and the two-arity behaviour contract (#339 phase 2).

  Swaps global app env, so `async: false`. **No test here touches the network** —
  the shipped ReqLLM adapter is only ever exercised through its unconfigured
  path, where it refuses before building a request.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Ask

  # A generator on the OLD (#361) contract: two arities only. Its continued
  # working is the compatibility guarantee, so it is the one used wherever the
  # test isn't specifically about locale.
  defmodule LegacyGenerator do
    @behaviour KilnCMS.Ask.Generator
    @impl true
    def generate(question, sources), do: {:ok, "legacy:#{question}:#{length(sources)}"}
  end

  defmodule LocaleGenerator do
    @behaviour KilnCMS.Ask.Generator
    @impl true
    def generate(_question, _sources), do: {:ok, "no-locale"}
    @impl true
    def generate(_question, _sources, opts), do: {:ok, "locale:#{opts[:locale]}"}
  end

  defmodule EchoGenerator do
    @behaviour KilnCMS.Ask.Generator
    @impl true
    def generate(question, _sources), do: {:ok, question}
  end

  defmodule BoomGenerator do
    @behaviour KilnCMS.Ask.Generator
    @impl true
    def generate(_question, _sources), do: raise("model exploded")
  end

  defmodule ExitGenerator do
    @behaviour KilnCMS.Ask.Generator
    @impl true
    def generate(_question, _sources), do: exit(:boom)
  end

  defmodule ShapeGenerator do
    @behaviour KilnCMS.Ask.Generator
    @impl true
    def generate(_question, _sources), do: :yes_please
  end

  defp put_ask(overrides) do
    previous = Application.get_env(:kiln_cms, KilnCMS.Ask, [])
    Application.put_env(:kiln_cms, KilnCMS.Ask, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Ask, previous) end)
  end

  # Retrieval needs the DB; these tests are about everything *after* it, so they
  # go through `answer/2` with a question that retrieves nothing rather than
  # standing up content. A generator still runs on an empty retrieval — that is
  # the case `Ask.Prompt` labels explicitly.
  defp ask(question, opts), do: Ask.answer(question, opts)
  defp ask(question), do: Ask.answer(question, [])

  describe "disabled by default" do
    test "a default install reports generation off and returns retrieval-only" do
      # No put_ask/1 here on purpose: this is the shipped config.
      refute Ask.enabled?()
      refute Ask.egress?()
      assert Ask.generator() == nil
      assert Ask.model() == nil
    end

    test "the shipped adapter refuses rather than calling out when no model is set" do
      # Configured as the generator but with no model spec — nothing to call,
      # and it must not fall through to some provider default.
      assert {:error, :no_model} = KilnCMS.Ask.Generator.ReqLLM.generate("q", [])
    end
  end

  describe "egress classification" do
    test "on-prem providers at their default local daemon are not egress" do
      for spec <- ["ollama:llama3.1", "vllm:mistral-7b"] do
        put_ask(generator: LegacyGenerator, model: spec, base_url: nil)
        assert Ask.enabled?()
        refute Ask.egress?()
      end
    end

    test "an on-prem provider pointed at a REMOTE host is egress" do
      put_ask(
        generator: LegacyGenerator,
        model: "ollama:llama3.1",
        base_url: "https://gpu.example"
      )

      assert Ask.egress?()
      assert Ask.endpoint_host() == "gpu.example"
      assert Ask.provider() == "ollama"
    end

    test "a hosted provider is egress" do
      put_ask(generator: LegacyGenerator, model: "anthropic:claude-sonnet-5")
      assert Ask.egress?()
    end

    test "a bespoke generator with no model spec is enabled but not classified as egress" do
      # We cannot see where someone else's module sends things. Reporting egress
      # we can't demonstrate is as misleading as denying egress we can — and the
      # boot warning names a provider, which there isn't one of here.
      put_ask(generator: LegacyGenerator, model: nil)
      assert Ask.enabled?()
      refute Ask.egress?()
    end

    test "base_url reaches the request, not just the classifier" do
      # Read only by `egress?/0` it would be a key that silences the warning
      # while req_llm still fell back to the vendor's default endpoint.
      put_ask(generator: LegacyGenerator, model: "ollama:x", base_url: "http://10.0.0.5:11434")
      assert Ask.request_opts()[:base_url] == "http://10.0.0.5:11434"
    end
  end

  describe "the generator contract" do
    test "a two-arity generator written against #361 still works untouched" do
      put_ask(generator: LegacyGenerator)
      assert %{answer: "legacy:hello:0", generated: true} = ask("hello")
    end

    test "a three-arity generator is preferred and receives the content locale" do
      put_ask(generator: LocaleGenerator)
      assert %{answer: "locale:en"} = ask("hello", locale: "en")
    end

    test "an unknown locale is normalized before it reaches the generator" do
      put_ask(generator: LocaleGenerator)
      assert %{answer: answer} = ask("hello", locale: "not-a-locale")
      assert answer == "locale:#{KilnCMS.I18n.default_locale()}"
    end
  end

  describe "degradation" do
    test "a crashing generator degrades to retrieval-only" do
      put_ask(generator: BoomGenerator)
      assert %{answer: nil, generated: false} = ask("hello")
    end

    test "an EXITING generator degrades too, rather than taking the caller down" do
      # A `rescue` alone doesn't catch this: a req_llm call that times out at
      # the transport layer exits, and an uncaught exit in the controller
      # process is a 500 on an endpoint documented to degrade.
      put_ask(generator: ExitGenerator)
      assert %{answer: nil, generated: false} = ask("hello")
    end

    test "a generator returning something that isn't {:ok, binary} degrades" do
      put_ask(generator: ShapeGenerator)
      assert %{answer: nil, generated: false} = ask("hello")
    end
  end

  describe "output normalization" do
    test "the answer is trimmed, and whitespace-only counts as no answer" do
      put_ask(generator: EchoGenerator)

      assert %{answer: "spaced"} = ask("  spaced  ")
      assert %{answer: nil, generated: false} = ask(" ")
    end

    test "an over-long answer is capped rather than echoed whole" do
      # The answer is returned to an anonymous HTTP caller; a model ignoring the
      # length rule must not get to choose the response size.
      put_ask(generator: EchoGenerator, max_output_chars: 20)

      assert %{answer: answer, generated: true} = ask(String.duplicate("x", 500))
      assert String.length(answer) == 20
    end
  end

  describe "generation budget" do
    test "an exhausted caller bucket degrades to retrieval-only, it does not fail" do
      # /api/ask is public: the per-caller bucket is usually keyed on an IP.
      client = "ip:198.51.100.#{System.unique_integer([:positive])}"
      put_ask(generator: LegacyGenerator, per_user_limit: {2, :timer.minutes(1)})

      assert %{generated: true} = ask("q", client_id: client)
      assert %{generated: true} = ask("q", client_id: client)

      # Third call in the window: no answer, but still a well-formed result.
      assert %{answer: nil, generated: false, sources: []} = ask("q", client_id: client)
    end

    test "a different client is not affected by an exhausted neighbour" do
      one = "ip:198.51.100.#{System.unique_integer([:positive])}"
      two = "ip:198.51.100.#{System.unique_integer([:positive])}"
      put_ask(generator: LegacyGenerator, per_user_limit: {1, :timer.minutes(1)})

      assert %{generated: true} = ask("q", client_id: one)
      assert %{generated: false} = ask("q", client_id: one)
      assert %{generated: true} = ask("q", client_id: two)
    end

    test "with neither an actor nor a client id the caller bucket is skipped" do
      # A mix task or a test has no request context; `KilnCMS.LLM.Budget` treats
      # a nil id as "not identifiable" everywhere else and this is no different.
      put_ask(generator: LegacyGenerator, per_user_limit: {1, :timer.minutes(1)})

      assert %{generated: true} = ask("q")
      assert %{generated: true} = ask("q")
    end

    test "an empty question never reaches the generator or the budget" do
      put_ask(generator: LegacyGenerator, per_user_limit: {1, :timer.minutes(1)})

      assert %{question: "", answer: nil, generated: false, sources: []} = ask("   ")
    end
  end
end
