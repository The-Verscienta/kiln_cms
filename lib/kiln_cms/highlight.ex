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

  # Collapse common editor spellings onto the names the bundled lexers
  # register (elixir/iex, erlang/erl, eex/heex, js/ts, html, json, css).
  @aliases %{
    "ex" => "elixir",
    "exs" => "elixir",
    "erl" => "erlang",
    "javascript" => "js",
    "jsx" => "js",
    "typescript" => "ts",
    "tsx" => "ts",
    "htm" => "html",
    "html.eex" => "eex",
    "html_eex" => "eex"
  }

  # Also the safety gate for `class="language-…"`: a tag that fails this
  # pattern is dropped entirely, so it can never break out of the attribute.
  @language_format ~r/^[a-z0-9_.+#-]{1,32}$/

  @doc """
  Normalize a user-supplied language tag to its canonical lowercase form, or
  `nil` when absent or not a plausible language token.
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(language) when is_binary(language) do
    tag = language |> String.trim() |> String.downcase()
    tag = Map.get(@aliases, tag, tag)
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
    case Makeup.Registry.fetch_lexer_by_name(language) do
      {:ok, {lexer, options}} ->
        inner =
          code
          |> Makeup.highlight_inner_html(lexer: lexer, lexer_options: options)
          # Bracket-matching metadata with a random per-render prefix: it would
          # make fired artifacts nondeterministic (and needs JS to do anything).
          |> String.replace(~r/ data-group-id="[^"]*"/, "")

        {:ok, ~s(<pre class="highlight"><code class="language-#{language}">#{inner}</code></pre>)}

      :error ->
        :error
    end
  rescue
    _lexer_crash -> :error
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
