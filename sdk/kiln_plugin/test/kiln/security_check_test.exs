defmodule Kiln.SecurityCheckTest do
  @moduledoc """
  `Kiln.Security.Check` on its own, with no KilnCMS core loaded (kiln_cms#2252):
  the helpers, `conformance/1`, and `Result.sanitize/1`'s limits.
  """
  use ExUnit.Case, async: true

  alias Kiln.Security.Check
  alias Kiln.Security.Check.Context
  alias Kiln.Security.Check.Result

  defmodule Good do
    use Kiln.Security.Check

    @impl Kiln.Security.Check
    def id, do: "acme.webhook_secret"

    @impl Kiln.Security.Check
    def title, do: "Webhook signing secret"

    @impl Kiln.Security.Check
    def scope, do: :deployment

    @impl Kiln.Security.Check
    def run(%Context{build_env: :prod}), do: fail("Not signed.", facts: %{signed: false})
    def run(_context), do: n_a("Only checked on production builds.")
  end

  defmodule Described do
    use Kiln.Security.Check

    def id, do: "acme.described"
    def title, do: "Described"
    def scope, do: :site
    def description, do: "Why it matters."
    def timeout, do: 2500
    def run(_context), do: pass("Fine.")
  end

  defmodule Broken do
    def id, do: "Core-Thing"
    def title, do: ""
    def scope, do: :everywhere
    def description, do: 42
    def timeout, do: 0
    def run(_context), do: :ok
  end

  defmodule Raising do
    def id, do: raise("no id")
    def title, do: throw(:no_title)
    def scope, do: :site
    def run(_context), do: :ok
  end

  defmodule Plugin do
    use Kiln.Plugin
  end

  test "a plugin contributes no checks unless it says so" do
    assert Plugin.security_checks() == []
  end

  test "the helpers build results with every option" do
    assert %Result{status: :pass, summary: "ok", details: [], facts: %{}} = Check.pass("ok")

    assert %Result{status: :warn, details: ["a"], fix_path: "/editor/x", docs_url: "https://d"} =
             Check.warn("w", details: ["a"], fix_path: "/editor/x", docs_url: "https://d")

    assert Check.fail("f").status == :fail
    assert Check.unknown("u").status == :unknown
    assert Check.n_a("n").status == :n_a
  end

  test "use imports the helpers into the check" do
    context = %Context{build_env: :prod, now: DateTime.utc_now()}
    assert %Result{status: :fail, facts: %{signed: false}} = Good.run(context)
    assert %Result{status: :n_a} = Good.run(%{context | build_env: :dev})
  end

  describe "conformance/1" do
    test "a valid check conforms, with the defaults filled in" do
      assert Check.conformance(Good) == :ok

      assert {:ok, %{id: "acme.webhook_secret", scope: :deployment, timeout: 1000} = described} =
               Check.describe(Good)

      assert described.description == nil

      assert {:ok, %{description: "Why it matters.", timeout: 2500}} = Check.describe(Described)
    end

    test "names every problem" do
      assert {:error, problems} = Check.conformance(Broken)
      assert Enum.any?(problems, &(&1 =~ "id/0 must be dotted lowercase"))
      assert Enum.any?(problems, &(&1 =~ "title/0 must be a non-empty string"))
      assert Enum.any?(problems, &(&1 =~ "scope/0 must return :site or :deployment"))
      assert Enum.any?(problems, &(&1 =~ "description/0 must return a string"))
      assert Enum.any?(problems, &(&1 =~ "timeout/0 must return a positive integer"))
    end

    test "a raising callback is a problem, not a crash" do
      assert {:error, problems} = Check.conformance(Raising)
      assert "id/0 raised: no id" in problems
      assert Enum.any?(problems, &(&1 =~ "title/0 raised: throw: :no_title"))
    end

    test "a module that is not a check, or not a module, does not conform" do
      assert {:error, [problem]} = Check.conformance(Plugin)
      assert problem =~ "does not implement Kiln.Security.Check"
      assert {:error, [_]} = Check.conformance(Kiln.SecurityCheckTest.NoSuchModule)
      assert {:error, [_]} = Check.conformance("acme.check")
    end

    test "an id needs a dot, and stays short" do
      for id <- ["single", "acme.", ".acme", "acme..x", String.duplicate("a", 60) <> ".long"] do
        module = Module.concat(__MODULE__, "Id#{System.unique_integer([:positive])}")

        Module.create(
          module,
          quote do
            def id, do: unquote(id)
            def title, do: "T"
            def scope, do: :site
            def run(_context), do: nil
          end,
          Macro.Env.location(__ENV__)
        )

        assert {:error, [problem]} = Check.conformance(module), "#{inspect(id)} conformed"
        assert problem =~ "id/0"
      end
    end
  end

  describe "Result.sanitize/1" do
    test "keeps a result inside the limits as it is" do
      result =
        Check.warn("Two admins have no second factor.",
          details: ["a@example.com"],
          fix_path: "/editor/team",
          docs_url: "https://example.com/docs#2fa",
          facts: %{"enabled" => true, admins_without: 2, ratio: 0.5, mode: "warn", none: nil}
        )

      assert {:ok, clean} = Result.sanitize(result)
      assert clean.summary == result.summary
      assert clean.details == ["a@example.com"]
      assert clean.fix_path == "/editor/team"
      assert clean.docs_url == "https://example.com/docs#2fa"

      assert clean.facts == %{
               "admins_without" => 2,
               "enabled" => true,
               "ratio" => 0.5,
               "mode" => "warn",
               "none" => nil
             }
    end

    test "trims the summary and details, and caps how many details and facts" do
      long = String.duplicate("x", 400)
      many_facts = Map.new(1..30, &{"fact_#{&1}", &1})

      {:ok, clean} =
        Result.sanitize(
          Check.pass(long,
            details: Enum.map(1..15, &"d#{&1}") ++ [long, :not_text],
            facts: many_facts
          )
        )

      assert String.length(clean.summary) == 300
      assert String.ends_with?(clean.summary, "…")
      assert length(clean.details) == 10
      assert map_size(clean.facts) == 20
    end

    test "drops a fact that is not a scalar, or whose key is not a name" do
      {:ok, clean} =
        Result.sanitize(
          Check.pass("ok", facts: %{{1, 2} => 3, "" => 1, list: [1], map: %{a: 1}, kept: 1})
        )

      assert clean.facts == %{"kept" => 1}
      assert {:ok, %{facts: %{}}} = Result.sanitize(Check.pass("ok", facts: [a: 1]))
    end

    test "drops a fix path outside the console, and a docs URL that is not https" do
      for path <- [
            "https://evil.example/editor/x",
            "//evil.example/editor/x",
            "/editor//evil.example",
            "/editor/\\evil",
            "/account",
            "editor/x",
            "/editor/x y",
            "javascript:alert(1)"
          ] do
        assert {:ok, %{fix_path: nil}} = Result.sanitize(Check.pass("ok", fix_path: path)),
               "#{inspect(path)} was kept"
      end

      for url <- [
            "http://example.com",
            "javascript:alert(1)",
            "https://user:pw@example.com",
            "https://",
            "/docs"
          ] do
        assert {:ok, %{docs_url: nil}} = Result.sanitize(Check.pass("ok", docs_url: url)),
               "#{inspect(url)} was kept"
      end
    end

    test "replaces invalid UTF-8 in the summary, details, fact keys and fact values" do
      bad = "a" <> <<0xFF>>

      {:ok, clean} =
        Result.sanitize(Check.warn(bad, details: [bad], facts: %{bad => 1, "text" => bad}))

      assert clean.summary == "a�"
      assert clean.details == ["a�"]
      assert clean.facts == %{"a�" => 1, "text" => "a�"}
      assert String.valid?(clean.summary)
    end

    test "trims by graphemes after replacing invalid bytes" do
      {:ok, clean} = Result.sanitize(Check.pass(String.duplicate(<<0xFF>>, 400)))

      assert String.valid?(clean.summary)
      assert String.length(clean.summary) == 300
    end

    test "drops a fix path or docs URL that is not valid UTF-8" do
      assert {:ok, %{fix_path: nil, docs_url: nil}} =
               Result.sanitize(
                 Check.pass("ok",
                   fix_path: "/editor/team" <> <<0xFF>>,
                   docs_url: "https://example.com/" <> <<0xFF>>
                 )
               )

      assert Result.fix_path("/editor/" <> <<0xC3>>) == nil
      assert Result.docs_url("https://example.com/" <> <<0xC3, 0x28>>) == nil
    end

    test "is :error for anything that is not a result" do
      assert Result.sanitize(:ok) == :error
      assert Result.sanitize(%{status: :pass, summary: "ok"}) == :error
      assert Result.sanitize(%Result{status: :great, summary: "ok"}) == :error
      assert Result.sanitize(%Result{status: :pass, summary: nil}) == :error
    end
  end
end
