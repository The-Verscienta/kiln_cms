defmodule KilnCMS.CodeBlocksTest do
  @moduledoc """
  Code blocks take keyboard focus and carry a name (#2164): `focusable/2` on
  its own, and its one call site, the rich-text `:web` renderer — which every
  delivery, preview and fired artifact goes through, while the `:json`
  artifact and `PortableText.to_html/1` (which seeds the editors) stay plain.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Blocks.RichText
  alias KilnCMS.CodeBlocks

  doctest KilnCMS.CodeBlocks

  @attrs ~s(tabindex="0" role="group" aria-label="Code sample")

  describe "focusable/2" do
    test "a bare <pre> takes focus and a name" do
      assert CodeBlocks.focusable("<pre><code>x</code></pre>") ==
               ~s(<pre #{@attrs}><code>x</code></pre>)
    end

    test "a highlighted <pre> keeps its class first" do
      html = ~s(<pre class="highlight"><code class="language-elixir">x</code></pre>)

      assert CodeBlocks.focusable(html) ==
               ~s(<pre class="highlight" #{@attrs}><code class="language-elixir">x</code></pre>)
    end

    test "every <pre> in the html, not only the first" do
      html =
        "<p>a</p><pre><code>1</code></pre><p>b</p><pre class=\"highlight\"><code>2</code></pre>"

      out = CodeBlocks.focusable(html)

      assert length(Regex.scan(~r/tabindex="0"/, out)) == 2
      assert out =~ "<p>a</p>"
      assert out =~ "<p>b</p>"
    end

    test "is idempotent" do
      once = CodeBlocks.focusable(~s(<pre><code>x</code></pre><pre class="highlight">y</pre>))
      assert CodeBlocks.focusable(once) == once
    end

    test "leaves escaped markup alone" do
      html =
        "<p>Write &lt;pre&gt; for code.</p><code>&lt;pre class=&quot;highlight&quot;&gt;</code>"

      assert CodeBlocks.focusable(html) == html
    end

    test "returns html without a <pre> unchanged" do
      html = "<p>No code here, only <code>inline</code>.</p>"
      assert CodeBlocks.focusable(html) == html
      assert CodeBlocks.focusable("") == ""
    end

    test "does not touch a <pre> that already carries other attributes" do
      html = ~s(<pre data-x="1"><code>x</code></pre>)
      assert CodeBlocks.focusable(html) == html
    end

    test "escapes the label" do
      out = CodeBlocks.focusable("<pre>x</pre>", ~s(a "b" <c> & d))

      assert out ==
               ~s(<pre tabindex="0" role="group" aria-label="a &quot;b&quot; &lt;c&gt; &amp; d">x</pre>)
    end

    test "translates the default label in the caller's locale" do
      out =
        CodeBlocks.with_content_locale("fr", fn -> CodeBlocks.focusable("<pre>x</pre>") end)

      assert out =~ ~s(aria-label="Exemple de code")
    end
  end

  describe "with_content_locale/2" do
    test "an unsupported or nil locale falls back to the site default" do
      for locale <- [nil, "xx", "fr-CA"] do
        inside =
          CodeBlocks.with_content_locale(locale, fn ->
            Gettext.get_locale(KilnCMSWeb.Gettext)
          end)

        assert inside == KilnCMS.I18n.default_locale()
      end
    end

    test "restores the caller's locale afterwards" do
      before = Gettext.get_locale(KilnCMSWeb.Gettext)
      CodeBlocks.with_content_locale("es", fn -> :ok end)
      assert Gettext.get_locale(KilnCMSWeb.Gettext) == before
    end
  end

  defp code(text, language \\ nil) do
    %{
      "_type" => "block",
      "style" => "code",
      "children" => [%{"_type" => "span", "text" => text, "marks" => []}],
      "markDefs" => []
    }
    |> then(fn block -> if language, do: Map.put(block, "language", language), else: block end)
  end

  defp web(block), do: block |> RichText.render(:web) |> IO.iodata_to_binary()

  describe "RichText.render(:web)" do
    test "a plain Portable Text code block" do
      assert web(%RichText{body: [code("x = 1")]}) ==
               ~s(<pre #{@attrs}><code>x = 1</code></pre>)
    end

    test "a highlighted Portable Text code block" do
      html = web(%RichText{body: [code("IO.puts(1)", "elixir")]})
      assert html =~ ~s(<pre class="highlight" #{@attrs}><code class="language-elixir">)
    end

    test "a code block in a language with no lexer" do
      html = web(%RichText{body: [code("x", "cobol")]})
      assert html == ~s(<pre #{@attrs}><code class="language-cobol">x</code></pre>)
    end

    test "legacy_html code, after the scrubber" do
      legacy = ~s{<pre><code class="language-elixir">IO.puts(<em>1</em>)</code></pre>}
      html = web(%RichText{body: [], legacy_html: legacy})

      assert html =~ ~s(<pre #{@attrs}><code class="language-elixir">)
    end

    test "prose without code is unchanged" do
      block = %{
        "_type" => "block",
        "style" => "normal",
        "children" => [%{"_type" => "span", "text" => "Hi", "marks" => []}],
        "markDefs" => []
      }

      assert web(%RichText{body: [block]}) == PortableText.to_html([block])
    end

    test "the :json artifact and PortableText.to_html/1 stay plain" do
      body = [code("x = 1"), code("IO.puts(1)", "elixir")]
      legacy = "<pre><code>y</code></pre>"

      refute PortableText.to_html(body) =~ "tabindex"
      refute inspect(RichText.render(%RichText{body: body}, :json)) =~ "tabindex"

      assert %{"legacy_html" => "<pre><code>y</code></pre>"} =
               RichText.render(%RichText{body: [], legacy_html: legacy}, :json)
    end
  end
end
