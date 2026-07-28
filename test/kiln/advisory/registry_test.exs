defmodule Kiln.Advisory.RegistryTest do
  @moduledoc """
  The shared advisory framework (#476, #495): a check is a module, the registry
  discovers and runs them, and one bad check can't take the editor down.
  """
  use ExUnit.Case, async: true

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context
  alias Kiln.Advisory.Finding
  alias Kiln.Advisory.Registry

  defmodule PassingCheck do
    use Kiln.Advisory

    @impl Kiln.Advisory
    def check(_context), do: :ok
  end

  defmodule NotApplicableCheck do
    use Kiln.Advisory

    @impl Kiln.Advisory
    def check(_context), do: :n_a
  end

  defmodule FindingCheck do
    use Kiln.Advisory

    @impl Kiln.Advisory
    def check(_context), do: finding(:warning, :something_up, :title)
  end

  defmodule MultiCheck do
    use Kiln.Advisory

    @impl Kiln.Advisory
    def check(_context), do: [:ok, :n_a, finding(:info, :a_nudge)]
  end

  defmodule RaisingCheck do
    use Kiln.Advisory

    @impl Kiln.Advisory
    def check(_context), do: raise("plugin author had a bad day")
  end

  defp context(fields \\ %{}), do: Context.new(fields, %Body{})

  describe "outcomes" do
    test "a check may return one outcome or several" do
      outcomes = Registry.run(context(), [FindingCheck, MultiCheck])

      assert length(outcomes) == 4

      assert [%Finding{code: :something_up}, %Finding{code: :a_nudge}] =
               Registry.findings(outcomes)
    end

    test "tally counts passes over APPLICABLE checks, not all of them" do
      outcomes = Registry.run(context(), [PassingCheck, NotApplicableCheck, FindingCheck])

      # :n_a is neither a pass nor a failure — counting it as a pass would
      # flatter an empty draft, and as a failure would bury the author.
      assert Registry.tally(outcomes) == {1, 2}
    end

    test "every outcome is attributed to the module that produced it" do
      assert [{FindingCheck, %Finding{}}] = Registry.run(context(), [FindingCheck])
    end
  end

  describe "failure containment" do
    @tag :capture_log
    test "a raising check is dropped and the rest still run" do
      # These render on every keystroke in the content editor. Losing one
      # advisory is a far better outcome than losing the author's session.
      outcomes = Registry.run(context(), [PassingCheck, RaisingCheck, FindingCheck])

      assert [{PassingCheck, :ok}, {FindingCheck, %Finding{}}] = outcomes
    end
  end

  describe "discovery" do
    test "core checks come from config" do
      checks = Registry.checks()

      assert KilnCMS.Seo.Checks.Meta in checks
      # The two checks #495 needs live in the neutral namespace so an
      # accessibility panel can register them without depending on SEO.
      assert Kiln.Advisory.Checks.Headings in checks
      assert Kiln.Advisory.Checks.ImageAlt in checks
    end

    test "a plugin contributes checks through the Kiln.Plugin callback" do
      # Mirrors how a plugin adds blocks or field types.
      assert function_exported?(Kiln.Plugins, :advisories, 0)
      assert is_list(Kiln.Plugins.advisories())
    end

    test "a plugin that defines no advisories gets the empty default" do
      defmodule QuietPlugin do
        use Kiln.Plugin

        @impl Kiln.Plugin
        def name, do: "Quiet"
      end

      assert QuietPlugin.advisories() == []
    end
  end

  describe "Context" do
    test "blank fields normalize to \"\" so checks match with one clause" do
      # A blank form input arrives as nil; without this it misses the ""
      # clause, raises inside the check, and the containment above turns the
      # crash into a silently missing advisory.
      ctx = Context.new(%{seo_title: nil, title: "  Spaced  "}, %Body{})

      assert Context.field(ctx, :seo_title) == ""
      assert Context.field(ctx, :title) == "Spaced"
      assert Context.field(ctx, :never_set) == ""
    end

    test "string keys are accepted; unknown ones are dropped rather than made into atoms" do
      # Built at runtime: writing the atom literally anywhere in this file —
      # even in the assertion — would make the compiler create it, and
      # `String.to_existing_atom/1` would then succeed.
      unknown = "never_a_field_#{System.unique_integer([:positive])}"
      ctx = Context.new(%{"title" => "From a form", unknown => "x"}, %Body{})

      assert Context.field(ctx, :title) == "From a form"
      assert Map.keys(ctx.fields) == [:title]
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    test "english?/1 drives the locale-gated heuristics" do
      assert Context.english?(Context.new(%{}, %Body{}, locale: "en-GB"))
      refute Context.english?(Context.new(%{}, %Body{}, locale: "fr"))
    end
  end

  describe "the registered SEO checks never raise" do
    # The containment in the registry means a raising check shows up as a
    # *missing* advisory rather than an error, so assert directly that the
    # shipped checks survive the degenerate inputs.
    test "on an empty context, and on a fully-populated one" do
      empty = Context.new(%{}, %Body{})

      full =
        Context.new(
          %{
            title: "T",
            slug: "t",
            seo_title: String.duplicate("a", 90),
            seo_description: "d",
            seo_keywords: "kiln firing",
            seo_image: "/a.jpg"
          },
          Body.compute([
            %{"_type" => "heading", "text" => "H", "level" => 2},
            %{"_type" => "image", "url" => "/a.jpg", "alt" => ""}
          ])
        )

      for context <- [empty, full], module <- Registry.checks() do
        assert module.check(context) != nil, "#{inspect(module)} returned nil"
      end
    end
  end
end
