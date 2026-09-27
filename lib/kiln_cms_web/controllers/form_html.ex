defmodule KilnCMSWeb.FormHTML do
  @moduledoc """
  The standalone iframe document for an embeddable form
  (`GET /forms/:slug/embed`), and the re-render of a public form after a
  refused submission (`POST /forms/:slug`, #1683).

  The embed is a full HTML page rather than a layout-wrapped view: it's framed
  on a third-party site, so it carries no site chrome. It reuses
  `KilnCMSWeb.BlockComponents.public_form/1`, so a form embedded elsewhere
  renders exactly like one placed on-site (and picks up new field types for
  free). Sizing is reported to the parent by `/embed-frame.js` — an external
  script, so the embed CSP stays at `script-src 'self'` with no nonce.
  """
  use KilnCMSWeb, :html

  alias KilnCMSWeb.BlockComponents

  attr :form, :map, required: true
  attr :values, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :rendered_at, :string, default: nil
  attr :variant, :string, default: nil

  def embed(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={Gettext.get_locale(KilnCMSWeb.Gettext)}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{@form.name}</title>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <%!-- Transparent background so the form sits on the host page's colour. --%>
      <body class="kiln-embed-body bg-transparent p-1">
        <BlockComponents.public_form
          form={@form}
          embed
          values={@values}
          errors={@errors}
          rendered_at={@rendered_at}
          variant={@variant}
        />
        <script defer src={~p"/embed-frame.js"}>
        </script>
      </body>
    </html>
    """
  end

  @doc """
  The on-site form again after a refused submission (#1683): the visitor's
  values filled back in and each error shown against its field, inside the
  site's own public chrome. The controller supplies the root layout; the
  embedded equivalent is `embed/1` with the same `values`/`errors`, which keeps
  the iframe free of site chrome.
  """
  attr :form, :map, required: true
  attr :values, :map, required: true
  attr :errors, :map, required: true
  attr :rendered_at, :string, default: nil
  attr :variant, :string, default: nil
  attr :current_org, :any, default: nil
  attr :locale, :string, default: nil

  def invalid(assigns) do
    ~H"""
    <Layouts.public current_org={@current_org} locale={@locale}>
      <h1 class="mb-6 text-2xl font-semibold tracking-tight">{@form.name}</h1>
      <BlockComponents.public_form
        form={@form}
        values={@values}
        errors={@errors}
        rendered_at={@rendered_at}
        variant={@variant}
      />
    </Layouts.public>
    """
  end
end
