defmodule KilnCMSWeb.FormHTML do
  @moduledoc """
  The standalone iframe document for an embeddable form
  (`GET /forms/:slug/embed`).

  A full HTML page rather than a layout-wrapped view: it's framed on a
  third-party site, so it carries no site chrome. It reuses
  `KilnCMSWeb.BlockComponents.public_form/1`, so a form embedded elsewhere
  renders exactly like one placed on-site (and picks up new field types for
  free). Sizing is reported to the parent by `/embed-frame.js` — an external
  script, so the embed CSP stays at `script-src 'self'` with no nonce.
  """
  use KilnCMSWeb, :html

  alias KilnCMSWeb.BlockComponents

  attr :form, :map, required: true

  def embed(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{@form.name}</title>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <%!-- Transparent background so the form sits on the host page's colour. --%>
      <body class="kiln-embed-body bg-transparent p-1">
        <BlockComponents.public_form form={@form} embed />
        <script defer src={~p"/embed-frame.js"}>
        </script>
        <script defer src={~p"/form-conditions.js"}>
        </script>
      </body>
    </html>
    """
  end
end
