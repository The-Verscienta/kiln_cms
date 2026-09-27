defmodule KilnCMSWeb.FormController do
  @moduledoc """
  Public endpoints for admin-defined forms (`KilnCMS.CMS.Form`):

    * `GET /api/forms/:slug` — the form's schema as JSON (fields, labels,
      types, options), so headless frontends can render `data-kiln-form`
      placeholders themselves;
    * `POST /forms/:slug` — the on-site browser submission (form-encoded),
      rendering a thank-you page;
    * `POST /api/forms/:slug` — the same pipeline for JSON submissions.

  No CSRF (the endpoints are anonymous and fired artifacts couldn't carry a
  token); abuse is bounded by the honeypot (`KilnCMS.Forms`) and the tight
  per-IP `:form` rate bucket in the router pipeline. Submitted IPs feed the
  limiter transiently and are never stored.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Forms
  alias KilnCMS.Forms.EmbedPolicy
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Embed
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.Tenant

  # The embed page is public and changes only when an admin edits the form, so a
  # short shared-cache window is safe; a deactivated form disappears within it.
  #
  # Since #648 the response also carries a `frame-ancestors` the admin can edit
  # at runtime, and a `Cache-Control` window is a window on the *revocation*
  # too: for up to this long after an org narrows its allowlist, a shared cache
  # can still hand the removed parent the permissive policy. Kept at 60s rather
  # than dropped, because that is the same exposure a deactivated form already
  # had and shortening it would not remove the class — a purge would, and there
  # is no CDN API here to purge with. Stated in docs/forms.md so an operator
  # revoking a partner knows to wait a minute rather than assume instant.
  @embed_max_age_seconds 60

  @doc """
  The standalone iframe document a third-party site frames via `/embed.js`.

  Serves the framing-friendly CSP (`KilnCMSWeb.Embed`) in place of the site-wide
  one, whose `frame-ancestors 'self'` would otherwise block cross-origin embeds.
  """
  # Same false positive as `submit/2`: the only `page/2` call here passes a
  # literal, translated string and a nil back-href, and `page/2` HTML-escapes
  # every interpolation anyway. No request data reaches the markup raw.
  # sobelow_skip ["XSS.HTML"]
  def embed(conn, %{"slug" => slug}) do
    # The deployment-wide policy goes on FIRST, then the form's replaces it once
    # the form is known. Two headers where one would do, but the first one is
    # what a 500 carries: `Tenant.current_org_id/1` raises by design when the
    # tenant is unresolved (#563), and `RenderErrors` re-uses this conn — so
    # without it a crash renders the error page under the site-wide
    # `frame-ancestors 'self'`, i.e. blank inside the iframe, which is exactly
    # the invisible failure #650 exists to stop.
    conn = put_embed_csp(conn, nil)

    # Since #648 it is the form that says who may frame it. A 404 keeps the
    # deployment-wide policy already on the conn: naming a form's own allowlist
    # for a slug that does not exist would answer whether it exists.
    form = Forms.get_active(slug, Tenant.current_org_id(conn))
    conn = put_embed_csp(conn, form)

    # The response is about to be 200 and then discarded by the browser if this
    # is a cross-origin frame and the policy is closed. Say so once, server-side,
    # so an operator whose embeds broke on upgrade finds out from their own logs
    # rather than from someone else's console (#650).
    Embed.warn_if_framing_blocked(conn, EmbedPolicy.effective(form))

    case form do
      nil ->
        conn
        |> put_status(404)
        |> html(page(gettext("Form not found."), nil, embed: true, kind: :error))

      form ->
        conn
        |> put_resp_header("cache-control", "public, max-age=#{@embed_max_age_seconds}")
        # The page is rendered through gettext, and the locale can come from
        # `Accept-Language` rather than the path — without this a shared cache
        # serves the first visitor's language to everyone for the window. Same
        # rule published HTML already follows (docs/performance.md).
        |> put_resp_header("vary", "accept-language")
        |> put_view(KilnCMSWeb.FormHTML)
        |> render(:embed, form: form)
    end
  end

  # Replace the site-wide CSP (frame-ancestors 'self') with the embed policy.
  # `put_resp_header/3` overwrites, so this wins over `put_secure_browser_headers`.
  #
  # `EmbedPolicy.effective/1` resolves the org rung (#1131) before `Embed` ever
  # sees the form — a form with no list of its own is handed to `Embed` already
  # carrying its org's configured default, so `Embed` itself needs no change.
  defp put_embed_csp(conn, form) do
    put_resp_header(
      conn,
      "content-security-policy",
      Embed.content_security_policy(EmbedPolicy.effective(form))
    )
  end

  # An embedded form marks its submission so the thank-you page keeps a framing-
  # friendly CSP — otherwise it would render blank inside the iframe.
  defp embedded?(params), do: params["_kiln_embed"] == "1"

  def schema(conn, %{"slug" => slug}) do
    case Forms.get_active(slug, Tenant.current_org_id(conn)) do
      nil ->
        ApiError.send(conn, :not_found, "not_found", "Form not found.")

      form ->
        json(conn, %{
          slug: form.slug,
          name: form.name,
          description: form.description,
          success_message: form.success_message,
          submit_label: form.submit_label,
          honeypot_field: Forms.honeypot_field(),
          submit_url: "/forms/#{form.slug}",
          fields:
            Enum.map(form.fields, fn field ->
              %{
                name: field.name,
                label: field.label,
                type: field.field_type,
                required: field.required,
                options: field.options,
                help_text: field.help_text,
                placeholder: field.placeholder,
                default_value: field.default_value,
                width: field.width
              }
            end)
        })
    end
  end

  # On-site (form-encoded) submission → a small thank-you page.
  #
  # The XSS.HTML warning is a false positive: `page/2` HTML-escapes every
  # interpolated value (the message via `h/1`, the back href via
  # `Phoenix.HTML.html_escape/1`) — no request data lands in the markup raw.
  # sobelow_skip ["XSS.HTML"]
  def submit(conn, %{"slug" => slug} = params) do
    embedded? = embedded?(params)
    # Inside an iframe the referer is the embed page itself, so a "Back" link
    # would just reload the empty form — omit it there.
    back_href = if embedded?, do: nil, else: back(conn)

    # Deployment-wide policy up front, the form's over the top of it once known.
    # The first one is what a raise inside `run/3` — a DB error, a failed notify
    # enqueue — carries into the 500, so the error page still renders inside the
    # iframe instead of being discarded as a framing violation.
    conn = if embedded?, do: put_embed_csp(conn, nil), else: conn

    # The thank-you page has to stay framable by the same parents as the form it
    # was posted from, and since #648 that is the *form's* policy — which needs
    # the form. `run/3` reads `conn` and returns a result; it does not build one,
    # so nothing is lost by resolving the header after it.
    result = run(conn, slug, params)
    conn = if embedded?, do: put_embed_csp(conn, submitted_form(result)), else: conn

    case result do
      :not_found ->
        conn
        |> put_status(404)
        |> html(page(gettext("Form not found."), nil, embed: embedded?, kind: :error))

      {:ok, form} ->
        html(
          conn,
          page(
            form.success_message || gettext("Thanks — we got your message."),
            back_href,
            embed: embedded?,
            kind: :ok
          )
        )

      {:error, form, errors} ->
        render_invalid(conn, form, errors, params, embedded?)
    end
  end

  # A refused submission gets the SAME form back (#1683), not a page in its
  # place: the visitor's values filled in, each error against its field's label,
  # and a focused summary on top. It used to be a one-line message page whose
  # Back link was a fresh GET — everything typed was gone, and inside an iframe
  # there was no way back at all. Still a 422, so nothing reading the status
  # (the tests, a monitoring probe, a headless caller that posted form-encoded)
  # sees a change there.
  #
  # Embedded, it is the iframe document again, under the framing policy `submit/2`
  # already put on the conn; on-site, it is the form inside the site's public
  # chrome, under the strict CSP the pipeline set.
  defp render_invalid(conn, form, errors, params, embedded?) do
    assigns = [
      form: form,
      errors: errors,
      values: submitted_values(form, params),
      rendered_at: submitted_rendered_at(params),
      variant: Params.string(params, Forms.variant_field())
    ]

    conn = conn |> put_status(422) |> put_view(KilnCMSWeb.FormHTML)

    if embedded? do
      render(conn, :embed, assigns)
    else
      conn
      |> put_root_layout(html: {KilnCMSWeb.Layouts, :root})
      |> put_layout(false)
      |> render(
        :invalid,
        assigns ++
          [
            current_org: conn.assigns[:current_org],
            locale: Gettext.get_locale(KilnCMSWeb.Gettext),
            page_title: form.name
          ]
      )
    end
  end

  # What goes back into the re-rendered inputs: the form's OWN fields only, and
  # only as plain strings. That leaves out, by construction, every machinery
  # field (`_kiln_*`), anything a bot added, a `%Plug.Upload{}` or a nested
  # map/list, and — named explicitly, since an admin's field could in principle
  # share its name — the honeypot: echoing a honeypot value back would hand the
  # bot the one thing it must never learn it tripped.
  defp submitted_values(form, params) do
    honeypot = Forms.honeypot_field()

    for %{name: name} <- form.fields,
        name != honeypot,
        value = Map.get(params, name),
        is_binary(value),
        into: %{},
        do: {name, value}
  end

  # The visitor's original fill-time token (#477), when it still verifies, so a
  # corrected re-submit is timed from when they first opened the form. Anything
  # else — missing, forged, expired — gets a fresh one from the component, the
  # same as a first render; the spam check itself is untouched.
  defp submitted_rendered_at(params) do
    token = Params.string(params, Forms.rendered_at_field())
    if Forms.fill_time_ms(token), do: token
  end

  # Headless (JSON) submission.
  def submit_json(conn, %{"slug" => slug} = params) do
    case run(conn, slug, params) do
      :not_found ->
        ApiError.send(conn, :not_found, "not_found", "Form not found.")

      {:ok, form} ->
        json(conn, %{ok: true, message: form.success_message})

      {:error, _form, errors} ->
        conn |> put_status(422) |> json(%{ok: false, errors: errors})
    end
  end

  # The form a `run/3` result was about, if it found one — the thank-you page's
  # framing policy comes from it (#648).
  #
  # No catch-all: `run/3` is twenty lines below and returns exactly these three,
  # and a fourth one added later should fail loudly in the suite rather than
  # quietly fall back to the deployment policy on a public route.
  defp submitted_form({:ok, form}), do: form
  defp submitted_form({:error, form, _errors}), do: form
  defp submitted_form(:not_found), do: nil

  defp run(conn, slug, params) do
    case Forms.get_active(slug, Tenant.current_org_id(conn)) do
      nil ->
        :not_found

      form ->
        case Forms.submit(form, params, locale: Params.string(params, "locale")) do
          # A tripped honeypot reports success too — bots learn nothing.
          {:ok, _submission_or_discarded} -> {:ok, form}
          {:error, errors} -> {:error, form, errors}
        end
    end
  end

  # Thank-you / error page. Loads `app.css` so success/error share the site kit
  # (ember tokens, `.btn`) with the embed form — previously a bare system-font
  # `<p>` that abandoned brand after submit. `embed: true` keeps the height
  # reporter and tight padding so the iframe shrinks to the message.
  defp page(message, back_href, opts) do
    embed? = Keyword.get(opts, :embed, false)
    kind = Keyword.get(opts, :kind, :ok)
    {tone_class, heading} = page_tone(kind)
    back = page_nav_html(back_href)
    resizer = if embed?, do: ~s(<script defer src="/embed-frame.js"></script>), else: ""

    body_class =
      if embed?,
        do: "kiln-embed-body bg-transparent p-4",
        else: "mx-auto max-w-xl px-4 py-16"

    """
    <!DOCTYPE html>
    <html lang="#{h(Gettext.get_locale(KilnCMSWeb.Gettext))}">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{h(message)}</title>
      <link rel="stylesheet" href="/assets/css/app.css">
      #{resizer}
    </head>
    <body class="#{body_class}">
      <div class="card card-pad">
        <h1 class="text-lg font-semibold tracking-tight #{tone_class}">#{h(heading)}</h1>
        <p class="mt-2 text-sm text-base-content/80">#{h(message)}</p>
        #{back}
      </div>
    </body>
    </html>
    """
  end

  defp page_tone(:error), do: {"text-error", gettext("Something needs fixing")}
  defp page_tone(_), do: {"text-base-content", gettext("Thank you")}

  defp page_nav_html(back_href) when is_binary(back_href) do
    href = Phoenix.HTML.html_escape(back_href) |> Phoenix.HTML.safe_to_string()

    ~s(<p class="mt-4"><a href="#{href}" class="btn btn-default btn-sm">&larr; #{h(gettext("Back"))}</a></p>)
  end

  defp page_nav_html(_), do: ""

  # Only same-origin referers are offered as a back link (an open redirect
  # otherwise). Anything else falls back to no link.
  defp back(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{host: host, path: path} when is_binary(path) <- URI.parse(referer),
         true <- host in [nil, conn.host] do
      path
    else
      _ -> nil
    end
  end

  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
