defmodule Kiln.Forms.SpamCheck.RegistryTest do
  @moduledoc """
  The shared spam-scoring framework (#477): a check is a module, the registry
  discovers, runs and scores them, and one bad check can't fail a submission.
  """
  use ExUnit.Case, async: true

  alias Kiln.Forms.SpamCheck.Context
  alias Kiln.Forms.SpamCheck.Registry

  defmodule CleanCheck do
    use Kiln.Forms.SpamCheck

    @impl Kiln.Forms.SpamCheck
    def check(_context), do: :ok
  end

  defmodule FlaggingCheck do
    use Kiln.Forms.SpamCheck

    @impl Kiln.Forms.SpamCheck
    def check(_context), do: flag(:something_off, 25)
  end

  defmodule MultiCheck do
    use Kiln.Forms.SpamCheck

    @impl Kiln.Forms.SpamCheck
    def check(_context), do: [:ok, flag(:a_nudge, 5)]
  end

  defmodule RaisingCheck do
    use Kiln.Forms.SpamCheck

    @impl Kiln.Forms.SpamCheck
    def check(_context), do: raise("plugin author had a bad day")
  end

  # The realistic plugin-author mistake this guards against: an `if` with no
  # `else` returns `nil` on the untaken branch, not `:ok`.
  defmodule MalformedCheck do
    use Kiln.Forms.SpamCheck

    @impl Kiln.Forms.SpamCheck
    def check(_context), do: nil
  end

  defp context(data \\ %{}, opts \\ []), do: Context.new(data, opts)

  describe "outcomes and scoring" do
    test "a check may return one outcome or several" do
      outcomes = Registry.run(context(), [FlaggingCheck, MultiCheck])
      assert length(outcomes) == 3
    end

    test "score sums every flagged weight and ignores :ok" do
      outcomes = Registry.run(context(), [CleanCheck, FlaggingCheck, MultiCheck])
      assert Registry.score(outcomes) == 25 + 5
    end

    test "reasons lists every flagged reason code in order" do
      outcomes = Registry.run(context(), [FlaggingCheck, MultiCheck])
      assert Registry.reasons(outcomes) == [:something_off, :a_nudge]
    end

    test "every outcome is attributed to the module that produced it" do
      assert [{FlaggingCheck, {:flag, :something_off, 25}}] =
               Registry.run(context(), [FlaggingCheck])
    end
  end

  describe "failure containment" do
    @tag :capture_log
    test "a raising check is dropped and the rest still run" do
      # A bad plugin check must not fail a visitor's submission.
      outcomes = Registry.run(context(), [CleanCheck, RaisingCheck, FlaggingCheck])

      assert [{CleanCheck, :ok}, {FlaggingCheck, {:flag, :something_off, 25}}] = outcomes
    end

    @tag :capture_log
    test "a malformed (non-raising) outcome is dropped rather than crashing score/1" do
      # An `if` with no `else` returns `nil`, not `:ok` — this must not reach
      # score/1's Enum.reduce/3, which has no clause for it.
      outcomes = Registry.run(context(), [CleanCheck, MalformedCheck, FlaggingCheck])

      assert [{CleanCheck, :ok}, {FlaggingCheck, {:flag, :something_off, 25}}] = outcomes
      assert Registry.score(outcomes) == 25
    end
  end

  describe "discovery" do
    test "core checks come from config" do
      checks = Registry.checks()

      assert Kiln.Forms.SpamCheck.Checks.LinkDensity in checks
      assert Kiln.Forms.SpamCheck.Checks.DisallowedKeywords in checks
      assert Kiln.Forms.SpamCheck.Checks.FillTime in checks
      assert Kiln.Forms.SpamCheck.Checks.LocaleMismatch in checks
    end

    test "a plugin contributes checks through the Kiln.Plugin callback" do
      assert function_exported?(Kiln.Plugins, :spam_checks, 0)
      assert is_list(Kiln.Plugins.spam_checks())
    end

    test "a plugin that defines no spam checks gets the empty default" do
      defmodule QuietSpamPlugin do
        use Kiln.Plugin

        @impl Kiln.Plugin
        def name, do: "QuietSpam"
      end

      assert QuietSpamPlugin.spam_checks() == []
    end
  end

  describe "Context" do
    test "text/1 joins every string field value, dropping non-strings" do
      # Map iteration order is not guaranteed, so assert on content, not order.
      ctx = context(%{"name" => "Ada", "age" => 30, "message" => "hello there"})
      text = Context.text(ctx)
      assert text =~ "Ada"
      assert text =~ "hello there"
      refute text =~ "30"
    end

    test "fact/3 returns the default when the caller never computed it" do
      assert Context.fact(context(), :fill_time_ms) == nil
      assert Context.fact(context(), :fill_time_ms, 0) == 0

      with_fact = context(%{}, facts: %{fill_time_ms: 900})
      assert Context.fact(with_fact, :fill_time_ms) == 900
    end
  end

  describe "the registered core checks never raise" do
    test "on an empty context, and on a fully-populated one" do
      empty = context()

      full =
        context(%{"message" => "Buy now http://a.co http://b.co http://c.co"},
          locale: "en",
          keywords: ["viagra"],
          facts: %{fill_time_ms: 200}
        )

      for c <- [empty, full], module <- Registry.checks() do
        assert module.check(c) != nil, "#{inspect(module)} returned nil"
      end
    end
  end
end
