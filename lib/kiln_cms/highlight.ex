defmodule KilnCMS.Highlight do
  @moduledoc """
  Server-side syntax highlighting for rich-text code blocks (#503).

  Code blocks carry an optional `language` tag (set in the editor, stored on
  the Portable Text block). At fire time the `:web` surface renders known
  languages through Makeup — Elixir-native, zero client JS, works in static
  export — while the `:json` surface keeps `{code, language}` raw so headless
  frontends highlight with their own stack.

  Each Makeup lexer is its own OTP app that registers its language names with
  `Makeup.Registry` on boot, so "known language" simply means "a registered
  lexer name after aliasing". Unknown or absent languages fall back to the
  plain escaped `<pre>` the renderer always produced.
  """

  # Spellings the bundled lexers don't register under, resolved at LOOKUP time
  # only — stored PT keeps the author's tag (a headless consumer's highlighter
  # may distinguish jsx from js even though Makeup doesn't), and editing this
  # map can never retroactively change what stored/fired content means.
  @lookup_aliases %{
    "ex" => "elixir",
    "exs" => "elixir",
    "jsx" => "js",
    "tsx" => "ts",
    "htm" => "html",
    "html.eex" => "eex",
    "html_eex" => "eex"
  }

  # Also the safety gate for `class="language-…"`: a tag that fails this
  # pattern is dropped entirely, so it can never break out of the attribute.
  @language_format ~r/^[a-z0-9_.+#-]{1,32}$/

  @doc """
  Normalize a user-supplied language tag — trim, downcase, and validate the
  format; `nil` when absent or not a plausible language token. Deliberately no
  aliasing: what the author wrote is what gets stored.
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(language) when is_binary(language) do
    tag = language |> String.trim() |> String.downcase()
    if Regex.match?(@language_format, tag), do: tag
  end

  def normalize(_other), do: nil

  @doc """
  Highlight `code` as `language` (already normalized). Returns the full
  `<pre class="highlight"><code class="language-…">` markup, or `:error` when
  no lexer is registered under that name (callers fall back to plain `<pre>`).

  A lexer crash also falls back rather than failing the fire: highlighting is
  progressive enhancement, never the reason an artifact refuses to build.
  """
  @spec highlight(String.t(), String.t()) :: {:ok, String.t()} | :error
  def highlight(code, language) when is_binary(code) and is_binary(language) do
    case fetch_lexer(language) do
      {:ok, {lexer, options}} ->
        inner =
          code
          |> Makeup.highlight_inner_html(lexer: lexer, lexer_options: options)
          # Bracket-matching metadata with a random per-render prefix: it would
          # make fired artifacts nondeterministic (and needs JS to do anything).
          |> String.replace(~r/ data-group-id="[^"]*"/, "")

        # The emitted class carries the author's tag, not the lexer's name, so
        # fired markup always matches the stored PT block.
        {:ok, ~s(<pre class="highlight"><code class="language-#{language}">#{inner}</code></pre>)}

      :error ->
        :error
    end
  rescue
    _lexer_crash -> :error
  end

  defp fetch_lexer(language) do
    case Makeup.Registry.fetch_lexer_by_name(language) do
      {:ok, _} = hit ->
        hit

      :error ->
        case @lookup_aliases do
          %{^language => canonical} -> Makeup.Registry.fetch_lexer_by_name(canonical)
          _ -> :error
        end
    end
  end

  @doc """
  Every `class` value Makeup's HTML formatter can put on a token `<span>` —
  the short Pygments-style token classes, each also with the formatter's
  ` unselectable` suffix. Compile-time input for the sanitizer allowlist.
  """
  @spec span_classes() :: [String.t()]
  def span_classes do
    classes =
      Makeup.Token.Utils.token_to_class_map()
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    classes ++ Enum.map(classes, &(&1 <> " unselectable"))
  end
end
