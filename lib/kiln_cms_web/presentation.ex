defmodule KilnCMSWeb.Presentation do
  @moduledoc """
  Config for the visual-editing **Presentation console** (#355) — the Kiln admin
  page that iframes an external headless front end for side-by-side editing.

  Kiln doesn't render the external front end, so it must be told **where** that
  front end serves a given document. `PRESENTATION_PREVIEW_URL` is a template:

      PRESENTATION_PREVIEW_URL="https://front.example.com{path}?kilnPreview=1"

  Placeholders substituted per document: `{path}` (the locale-prefixed public
  path Kiln's own delivery would use, e.g. `/blog/hello` or `/fr/blog/hello`),
  `{type}`, `{slug}`, `{locale}`. A template with **no** placeholder is treated
  as a base URL and `{path}` is appended. Unset ⇒ the console renders a setup
  hint instead of an iframe.

  The `?kilnPreview=1`-style query param (yours to name) is how the front end's
  edit-mode build knows to load `bridge.js` and render the annotated preview.
  """

  alias KilnCMS.CMS.ContentTypes

  @placeholder_re ~r/\{(path|type|slug|locale)\}/

  @doc "Whether a preview-URL template is configured (and visual editing is on)."
  @spec configured?() :: boolean()
  def configured?, do: KilnCMS.VisualEditing.enabled?() and not is_nil(template())

  @doc "The raw template, or `nil` when unset."
  @spec template() :: String.t() | nil
  def template, do: Application.get_env(:kiln_cms, :presentation_preview_url)

  @doc """
  Build the external front end's preview URL for `record` of content type `ct`,
  or `nil` when no template is configured.
  """
  @spec preview_url(ContentTypes.t(), struct()) :: String.t() | nil
  def preview_url(ct, record) do
    case template() do
      nil -> nil
      tmpl -> render_template(tmpl, ct, record)
    end
  end

  defp render_template(tmpl, ct, record) do
    if Regex.match?(@placeholder_re, tmpl) do
      Regex.replace(@placeholder_re, tmpl, fn _, key -> placeholder(key, ct, record) end)
    else
      # A bare base URL: append the public path.
      String.trim_trailing(tmpl, "/") <> public_path(ct, record)
    end
  end

  defp placeholder("path", ct, record), do: public_path(ct, record)
  defp placeholder("type", ct, _record), do: to_string(ct.type)
  defp placeholder("slug", _ct, record), do: record.slug
  defp placeholder("locale", _ct, record), do: record.locale

  @doc """
  The origin (`scheme://host[:port]`) the external front end is served from —
  the value the console's `postMessage` handler validates `event.origin` against.
  Derived from the configured template; `nil` when unset/unparseable.
  """
  @spec frontend_origin() :: String.t() | nil
  def frontend_origin do
    with tmpl when is_binary(tmpl) <- template(),
         # Strip placeholders so the URL parses, then read its origin.
         cleaned = Regex.replace(@placeholder_re, tmpl, ""),
         %URI{scheme: scheme, host: host} = uri when not is_nil(scheme) and not is_nil(host) <-
           URI.parse(cleaned) do
      port = uri.port

      if port in [nil, 80, 443],
        do: "#{scheme}://#{host}",
        else: "#{scheme}://#{host}:#{port}"
    else
      _ -> nil
    end
  end

  # The locale-prefixed public path Kiln's own delivery uses, mirrored by the
  # external front end (`InContextEditLive.published_path/2` uses the same shape).
  defp public_path(ct, record) do
    prefix = if record.locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{record.locale}"
    "#{prefix}#{ContentTypes.public_prefix(ct)}/#{record.slug}"
  end
end
