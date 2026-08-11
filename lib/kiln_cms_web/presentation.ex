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

  When the template origin matches the console host, the preview iframe is
  sandboxed without `allow-same-origin` so framed scripts cannot reach the
  console DOM (#1059). See `docs/visual-editing-bridge.md`.
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
    case template() do
      tmpl when is_binary(tmpl) ->
        tmpl
        |> then(&Regex.replace(@placeholder_re, &1, ""))
        |> URI.parse()
        |> origin_from_uri()

      _ ->
        nil
    end
  end

  @doc """
  Whether the preview template's origin matches the Presentation console's
  host (#1059).

  Same-origin is the configuration that lets framed delivery scripts reach the
  console DOM without a sandbox. Cross-origin is already blocked by the browser.
  """
  @spec same_origin_preview?(URI.t() | term()) :: boolean()
  def same_origin_preview?(console_uri) do
    with front when is_binary(front) <- frontend_origin(),
         console when is_binary(console) <- origin_from_uri(console_uri) do
      front == console
    else
      _ -> false
    end
  end

  @doc """
  `sandbox` attribute for the preview iframe (#1059).

  Same-origin → `allow-scripts` only (opaque origin; no console DOM access, no
  cookies in the frame). Cross-origin → also `allow-same-origin` so the front
  end keeps its cookies; SOP already blocks the console.
  """
  @spec iframe_sandbox(boolean()) :: String.t()
  def iframe_sandbox(true = _same_origin?), do: "allow-scripts"
  def iframe_sandbox(false = _same_origin?), do: "allow-scripts allow-same-origin"

  @doc """
  Normalize a URI to `scheme://host[:port]`, omitting default ports.
  """
  @spec origin_from_uri(URI.t() | term()) :: String.t() | nil
  def origin_from_uri(%URI{scheme: scheme, host: host} = uri)
      when is_binary(scheme) and is_binary(host) and host != "" do
    port = uri.port

    if default_port?(scheme, port),
      do: "#{scheme}://#{host}",
      else: "#{scheme}://#{host}:#{port}"
  end

  def origin_from_uri(_), do: nil

  defp default_port?("http", port) when port in [nil, 80], do: true
  defp default_port?("https", port) when port in [nil, 443], do: true
  defp default_port?(_scheme, _port), do: false

  # The locale-prefixed public path Kiln's own delivery uses, mirrored by the
  # external front end (`InContextEditLive.published_path/2` uses the same shape).
  defp public_path(ct, record) do
    prefix = if record.locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{record.locale}"
    "#{prefix}#{ContentTypes.public_prefix(ct)}/#{record.slug}"
  end
end
