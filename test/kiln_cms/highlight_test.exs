defmodule KilnCMS.HighlightTest do
  @moduledoc "Fire-time code-block syntax highlighting via Makeup (#503)."
  use ExUnit.Case, async: true

  alias KilnCMS.Highlight

  describe "normalize/1" do
    test "lowercases, trims, and resolves aliases onto registered lexer names" do
      assert Highlight.normalize("Elixir") == "elixir"
      assert Highlight.normalize(" ex ") == "elixir"
      assert Highlight.normalize("JavaScript") == "js"
      assert Highlight.normalize("TSX") == "ts"
      assert Highlight.normalize("HEEx") == "heex"
    end

    test "keeps plausible tags it has no lexer for (they ride the :json surface)" do
      assert Highlight.normalize("python") == "python"
      assert Highlight.normalize("c#") == "c#"
    end

    test "rejects absent or implausible tags" do
      assert Highlight.normalize(nil) == nil
      assert Highlight.normalize("") == nil
      assert Highlight.normalize("<script>") == nil
      assert Highlight.normalize(~s(js" onmouseover=")) == nil
      assert Highlight.normalize(String.duplicate("a", 33)) == nil
      assert Highlight.normalize(123) == nil
    end
  end

  describe "highlight/2" do
    test "renders Makeup token markup for a registered language" do
      assert {:ok, html} = Highlight.highlight("IO.puts(1)", "elixir")

      assert html =~ ~s(<pre class="highlight"><code class="language-elixir">)
      assert html =~ ~s(<span class="nc">IO</span>)
      assert String.ends_with?(html, "</code></pre>")
    end

    test "escapes code content" do
      assert {:ok, html} = Highlight.highlight(~s|IO.puts("<script>")|, "elixir")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "strips Makeup's nondeterministic bracket-group metadata" do
      assert {:ok, html} = Highlight.highlight("IO.puts(1)", "elixir")

      refute html =~ "data-group-id"
    end

    test "every bundled lexer answers to its editor-facing names" do
      for language <- ~w(elixir iex erlang eex heex js ts html json css) do
        assert {:ok, html} = Highlight.highlight("x", language),
               "expected a registered lexer for #{language}"

        assert html =~ ~s(<code class="language-#{language}">)
      end
    end

    test "returns :error for unregistered languages" do
      assert Highlight.highlight("print(1)", "python") == :error
    end
  end

  describe "span_classes/0" do
    test "covers the classes Makeup emits, with unselectable variants" do
      classes = Highlight.span_classes()

      assert "k" in classes
      assert "nc" in classes
      assert "k unselectable" in classes
      assert Enum.all?(classes, &is_binary/1)
    end
  end
end
