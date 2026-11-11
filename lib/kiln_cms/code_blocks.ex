defmodule KilnCMS.CodeBlocks do
  @moduledoc """
  Makes the code blocks in rendered rich text reachable from the keyboard
  (#2164).

  A content `<pre>` scrolls sideways when a line is wider than the column
  (`.kiln-block pre { overflow-x: auto }`), and a scroll container that holds
  no focusable element cannot be scrolled without a mouse or touch. Every
  content `<pre>` therefore gets `tabindex="0"`, so Tab reaches it and the
  arrow keys scroll it, and an accessible name, so a screen reader announces
  what took focus. Whether a block overflows depends on the reader's viewport,
  which the server cannot know, so all of them are made focusable rather than
  only the long ones.

  ## The markup

      <pre tabindex="0" role="group" aria-label="Code sample">
      <pre class="highlight" tabindex="0" role="group" aria-label="Code sample">

  `role="group"` because ARIA prohibits `aria-label` on an element with the
  generic role a bare `pre` has. Not `region`: that is a landmark, and a page
  of code samples would bury its real landmarks under a dozen same-named ones.
  The label is translated and carries no language name — the highlighted code
  says that already.

  ## Where it runs

  Once, at the end of `KilnCMS.Blocks.RichText.render(block, :web)`, over
  both of its branches (Portable Text and sanitized `legacy_html`). Those are
  the only two shapes of `<pre>` that leave it, which is all `focusable/2`
  matches. That one renderer feeds public delivery, every editor preview,
  fragments and columns children, and the fired `:web` artifacts (and through
  them feeds, newsletters and the static export).

  Not in `KilnCMS.Blocks.PortableText.to_html/1`: its output also seeds the
  editors and is compared for equality on the way back in, so presentation
  attributes added there would leak into stored prose. Not in the rich-text
  scrubber (`KilnCMS.HTMLSanitizer.RichText`) either: that still strips every
  attribute an author puts on a `<pre>` except `class="highlight"`, so these
  attributes are always the renderer's, never the author's.

  The `:json` artifact is data and carries the stored prose unchanged; a
  consumer rendering from it adds its own.

  ## Locale

  The label is translated in the calling process's Gettext locale. Delivery
  and firing render in the content's locale (`with_content_locale/2`), not the
  request's: the published-payload cache builds in another process, and a
  fired artifact is rendered by a worker, neither of which has the reader's
  locale.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  # The two `<pre>` start tags the renderers emit: PT's plain block and
  # `KilnCMS.Highlight`'s, which the scrubber also lets through from
  # `legacy_html`. A tag that already carries `tabindex` matches neither, so a
  # second pass changes nothing.
  @pre ~r/<pre( class="highlight")?>/

  @doc """
  Adds `tabindex="0"`, `role="group"` and an `aria-label` to every bare
  `<pre>` and `<pre class="highlight">` in `html`.

  HTML with no `<pre` comes back unchanged. The label is HTML-escaped.

      iex> KilnCMS.CodeBlocks.focusable("<pre><code>x</code></pre>", "Code")
      ~s(<pre tabindex="0" role="group" aria-label="Code"><code>x</code></pre>)
  """
  @spec focusable(String.t(), String.t()) :: String.t()
  def focusable(html, label \\ gettext("Code sample"))

  def focusable(html, label) when is_binary(html) and is_binary(label) do
    if String.contains?(html, "<pre") do
      label = escape(label)

      Regex.replace(@pre, html, fn _tag, class ->
        ~s(<pre#{class} tabindex="0" role="group" aria-label="#{label}">)
      end)
    else
      html
    end
  end

  @doc """
  Runs `fun` with the Gettext locale set to `locale` — a content record's
  locale — so the labels `focusable/2` writes are in the language of the
  content around them. A `nil` or unsupported locale falls back to the
  site's default (`KilnCMS.I18n.normalize/1`).
  """
  @spec with_content_locale(String.t() | nil, (-> result)) :: result when result: term()
  def with_content_locale(locale, fun) when is_function(fun, 0) do
    Gettext.with_locale(KilnCMSWeb.Gettext, KilnCMS.I18n.normalize(locale), fun)
  end

  defp escape(label), do: label |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
