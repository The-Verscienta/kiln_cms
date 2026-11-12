defmodule KilnCMSWeb.FormController do
  @moduledoc """
  Public endpoints for admin-defined forms (`KilnCMS.CMS.Form`):

    * `GET /api/forms/:slug` — the form's schema as JSON (fields, labels,
      types, options), so headless frontends can render `data-kiln-form`
      placeholders themselves;
    * `GET /forms/:slug/embed` — the iframe document `/embed.js` frames;
    * `POST /forms/:slug` — the on-site browser submission (form-encoded),
      rendering a thank-you page inside the site's public chrome
      (`KilnCMSWeb.FormHTML.message/1`, #2338), or the iframe's own when the
      submission came from an embed;
    * `POST /api/forms/:slug` — the same pipeline for JSON submissions.

  The form's own public page, `GET /forms/:slug` (#2138), is not served here:
  it is the last fallback of `KilnCMSWeb.ContentController`'s miss funnel, so
  a content type that owns the `forms` segment, a path alias or a redirect at
  the same URL keeps precedence. It renders `KilnCMSWeb.FormHTML.show/1`.

  No CSRF (the endpoints are anonymous and fired artifacts couldn't carry a
  token); abuse is bounded by the honeypot (`KilnCMS.Forms`) and the tight
  per-IP `:form` rate bucket in the router pipeline. Submitted IPs feed the
  limiter transiently and are never stored.

  ## Human verification (#2249)

  A form set to `challenge: :always` (and a deployment where forms may ask —
  `KilnCMS.Challenge.form_required?/2`) draws the provider's widget, and every
  submission carries its token as `_kiln_challenge` (or the field the
  provider's own markup posts, such as `g-recaptcha-response`). `KilnCMS.Forms.submit/3` decides; here that
  becomes:

    * the schema's `challenge` — `null`, or what a headless front end needs to
      draw the widget itself;
    * a JSON submission's `challenge` — `"verified"`, or `"held"` when the
      submission was kept for review (no token, solved on a host this
      deployment does not serve, or the provider could not answer). Present
      only when the form asks for a check. A refused token is a 422 with
      `errors._kiln_challenge` and `challenge: "failed"`;
    * the Content-Security-Policy, widened with the provider's origins only on
      a response that draws the widget (`Plugs.ChallengeCsp.widen_for_forms/2`,
      `Embed.content_security_policy/2`).

  A tripped honeypot is never verified, and answers in the same shape as a
  real submission would — bots learn nothing from it either.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Challenge
  alias KilnCMS.Forms
  alias KilnCMS.Forms.EmbedPolicy
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Embed
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.Plugs.ChallengeCsp
  alias KilnCMSWeb.Plugs.UrlLocale
  alias KilnCMSWeb.Tenant

  # The embed document is `public` and shared-cacheable under its URL, so its
  # language is the URL's, never the session's (#2595). Not the submissions:
  # a POST is never cached, and its locale already comes from the pinned path.
  plug UrlLocale when action in [:embed]

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
  # Same false positive as `submit/2`: the only `embed_page/2` call here passes
  # a literal, translated string, and `embed_page/2` HTML-escapes every
  # interpolation anyway. No request data reaches the markup raw.
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
        |> html(embed_page(gettext("Form not found."), :error))

      form ->
        conn
        |> KilnCMSWeb.SharedCache.put_public("public, max-age=#{@embed_max_age_seconds}")
        # The page is rendered through gettext in the URL's locale
        # (`Plugs.UrlLocale`, #2595). It used to fall back to the session's on
        # an unprefixed URL, which no `Vary` could key a shared cache on.
        # `Vary` is kept as the rule published HTML follows
        # (docs/performance.md).
        |> put_resp_header("vary", "accept-language")
        |> put_view(KilnCMSWeb.FormHTML)
        |> render(:embed, form: form, action: pinned_action(UrlLocale.locale(conn), form))
    end
  end

  # Replace the site-wide CSP (frame-ancestors 'self') with the embed policy.
  # `put_resp_header/3` overwrites, so this wins over `put_secure_browser_headers`.
  #
  # `EmbedPolicy.effective/1` resolves the org rung (#1131) before `Embed` ever
  # sees the form — a form with no list of its own is handed to `Embed` already
  # carrying its org's configured default, so `Embed` itself needs no change.
  #
  # A form that draws the human-verification widget (#2249) gets the provider's
  # origins on every one of its embed responses — the form, its thank-you page
  # and a refused re-render — and no other form does.
  defp put_embed_csp(conn, form) do
    put_resp_header(
      conn,
      "content-security-policy",
      Embed.content_security_policy(EmbedPolicy.effective(form), challenge_sources(form))
    )
  end

  defp challenge_sources(nil), do: %{}

  defp challenge_sources(form) do
    config = Challenge.config()

    if Challenge.form_required?(config, form),
      do: Challenge.csp_sources(config, :forms),
      else: %{}
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
          challenge: schema_challenge(form),
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
                width: field.width,
                min: schema_min(field),
                max: schema_max(field),
                step: schema_step(field)
              }
            end)
        })
    end
  end

  # `min`/`max`/`step` are additive (#2261): null for every type that has no
  # such notion. A rating's `max` is its effective star count (5 when unset)
  # and its `min` is always 1.
  defp schema_min(%{field_type: :rating}), do: 1
  defp schema_min(%{field_type: :number, min_value: min}), do: whole_or_float(min)
  defp schema_min(_field), do: nil

  defp schema_max(%{field_type: :rating, max_value: nil}), do: 5
  defp schema_max(%{field_type: :rating, max_value: max}), do: trunc(max)
  defp schema_max(%{field_type: :number, max_value: max}), do: whole_or_float(max)
  defp schema_max(_field), do: nil

  defp schema_step(%{field_type: :number, step: step}), do: whole_or_float(step)
  defp schema_step(_field), do: nil

  # A stored float `5.0` reads as `5` on the wire; `0.5` stays `0.5`.
  defp whole_or_float(value) when is_float(value) and value == trunc(value), do: trunc(value)
  defp whole_or_float(value), do: value

  # What a headless front end needs to draw the widget itself (#2249), or nil
  # when the form asks for no check.
  defp schema_challenge(form) do
    config = Challenge.config()

    with true <- Challenge.form_required?(config, form),
         %{} = widget <- Challenge.widget(config, :form) do
      Map.merge(Challenge.headless_widget(widget), %{
        required: true,
        field: Forms.challenge_field(),
        without_token: "held"
      })
    else
      _not_required -> nil
    end
  end

  # Form-encoded submission → a thank-you page: on-site inside the site's
  # chrome (`FormHTML.message/1`), embedded as the iframe's own document.
  #
  # The XSS.HTML warning is about the embedded branches' `html/2` and is a
  # false positive: `embed_page/2` HTML-escapes every interpolated value (the
  # admin's success message and the translated heading, via `h/1`) — no
  # request data lands in the markup raw. The on-site pages are HEEx.
  # sobelow_skip ["XSS.HTML"]
  def submit(conn, %{"slug" => slug} = params) do
    embedded? = embedded?(params)

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
      :not_found when embedded? ->
        conn
        |> put_status(404)
        |> html(embed_page(gettext("Form not found."), :error))

      :not_found ->
        render_message(
          conn,
          404,
          :not_found,
          gettext("This form doesn't exist or no longer takes submissions."),
          nil
        )

      # A tripped honeypot lands here too, and must read exactly like the real
      # thing.
      {:ok, form, _submission} ->
        message = form.success_message || gettext("Thanks — we got your message.")

        # Inside an iframe the referer is the embed page itself, so a "Back"
        # link would just reload the empty form — omit it there.
        if embedded?,
          do: html(conn, embed_page(message, :ok)),
          else: render_message(conn, 200, :ok, message, back(conn))

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
      variant: Params.string(params, Forms.variant_field()),
      action: pinned_action(conn.assigns[:path_locale], form)
    ]

    conn = conn |> put_status(422) |> put_view(KilnCMSWeb.FormHTML)

    if embedded? do
      render(conn, :embed, assigns)
    else
      conn
      |> widen_for_challenge(form)
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

  # The on-site thank-you and not-found pages (#2338): the same root layout and
  # `Layouts.public` chrome, org and locale as the 422 re-render, under the
  # strict CSP the `:public_form` pipeline set. They used to be a bare string
  # page with no site header, footer or branding. No challenge widening: these
  # pages draw no widget.
  defp render_message(conn, status, kind, message, back_href) do
    conn
    |> put_status(status)
    |> put_view(KilnCMSWeb.FormHTML)
    |> put_root_layout(html: {KilnCMSWeb.Layouts, :root})
    |> put_layout(false)
    |> render(:message,
      kind: kind,
      message: message,
      back_href: back_href,
      current_org: conn.assigns[:current_org],
      locale: Gettext.get_locale(KilnCMSWeb.Gettext),
      page_title: KilnCMSWeb.FormHTML.message_heading(kind)
    )
  end

  # Where a served form posts back to. Posted from `/fr/forms/<slug>` (#2138),
  # or from a content page whose form is pinned to its language (#2465), the
  # corrected re-submit keeps the prefix and so the visitor's language — the
  # default locale's too, since an unprefixed path would take the session's.
  #
  # The embed passes the URL's locale, default included (#2595), so even an
  # unprefixed embed posts under a prefix. A submission's re-render passes the
  # prefix it was posted under, as before.
  defp pinned_action(locale, form),
    do: KilnCMS.I18n.pinned_path(locale, "/forms/" <> form.slug)

  # The re-render draws a fresh widget when the form asks for one (#2249), so
  # its policy must allow the provider; any other refusal keeps the strict one.
  defp widen_for_challenge(conn, form) do
    config = Challenge.config()

    if Challenge.form_required?(config, form),
      do: ChallengeCsp.widen_for_forms(conn, config),
      else: conn
  end

  # What goes back into the re-rendered inputs: the form's OWN fields only, and
  # only as plain strings. That leaves out, by construction, every machinery
  # field (`_kiln_*`), anything a bot added, a `%Plug.Upload{}` or a nested
  # map/list, and — named explicitly, since an admin's field could in principle
  # share its name — the honeypot: echoing a honeypot value back would hand the
  # bot the one thing it must never learn it tripped.
  defp submitted_values(form, params) do
    honeypot = Forms.honeypot_field()

    for %{name: name} = field <- form.fields,
        name != honeypot,
        value = submitted_value(field, Map.get(params, name)),
        into: %{},
        do: {name, value}
  end

  # A checkboxes group posts `name[]=a&name[]=b`: a list of strings is kept for
  # it alone. Everything else must be a plain string.
  defp submitted_value(%{field_type: :checkboxes}, list) when is_list(list),
    do: if(Enum.all?(list, &is_binary/1), do: list)

  defp submitted_value(_field, value) when is_binary(value), do: value
  defp submitted_value(_field, _value), do: nil

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

      {:ok, form, submission} ->
        json(
          conn,
          put_challenge(
            %{ok: true, message: form.success_message},
            json_challenge(form, submission, params)
          )
        )

      {:error, _form, %{} = errors} when is_map_key(errors, "_kiln_challenge") ->
        conn
        |> put_status(422)
        |> json(%{ok: false, errors: errors, challenge: "failed"})

      {:error, _form, errors} ->
        conn |> put_status(422) |> json(%{ok: false, errors: errors})
    end
  end

  # `challenge` in a JSON submission's answer (#2249): only when the form asks
  # for a check. A tripped honeypot was never verified, and answers as the real
  # thing would have — "verified" with a token, "held" without one.
  defp json_challenge(_form, %{challenge: :passed}, _params), do: "verified"
  defp json_challenge(_form, %{challenge: held}, _params) when not is_nil(held), do: "held"

  defp json_challenge(form, :discarded, params) do
    if Challenge.form_required?(Challenge.config(), form) do
      if Forms.challenge_token(params) in [nil, ""], do: "held", else: "verified"
    end
  end

  defp json_challenge(_form, _submission, _params), do: nil

  defp put_challenge(body, nil), do: body
  defp put_challenge(body, value), do: Map.put(body, :challenge, value)

  # The form a `run/3` result was about, if it found one — the thank-you page's
  # framing policy comes from it (#648).
  #
  # No catch-all: `run/3` is twenty lines below and returns exactly these three,
  # and a fourth one added later should fail loudly in the suite rather than
  # quietly fall back to the deployment policy on a public route.
  defp submitted_form({:ok, form, _submission}), do: form
  defp submitted_form({:error, form, _errors}), do: form
  defp submitted_form(:not_found), do: nil

  defp run(conn, slug, params) do
    case Forms.get_active(slug, Tenant.current_org_id(conn)) do
      nil ->
        :not_found

      form ->
        opts = [locale: Params.string(params, "locale"), remote_ip: client_ip(conn)]

        case Forms.submit(form, params, opts) do
          # A tripped honeypot reports success too — bots learn nothing.
          {:ok, submission_or_discarded} -> {:ok, form, submission_or_discarded}
          {:error, errors} -> {:error, form, errors}
        end
    end
  end

  # The client's address (behind trusted proxies, `Plugs.ClientIp`), for the
  # verification provider only when the operator turned `send_remote_ip` on.
  defp client_ip(%Plug.Conn{remote_ip: ip}) when is_tuple(ip),
    do: ip |> :inet.ntoa() |> to_string()

  defp client_ip(_conn), do: nil

  # The embedded thank-you / not-found page: a chrome-free iframe document. It
  # loads `app.css` so the message shares the site kit (ember tokens, `.card`)
  # with the embed form, and `/embed-frame.js` so the iframe shrinks to the
  # message. External script only, so the embed CSP stays `script-src 'self'`.
  # The on-site equivalents are `FormHTML.message/1` (#2338).
  defp embed_page(message, kind) do
    {tone_class, heading} = embed_tone(kind)

    """
    <!DOCTYPE html>
    <html lang="#{h(Gettext.get_locale(KilnCMSWeb.Gettext))}">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{h(message)}</title>
      <link rel="stylesheet" href="/assets/css/app.css">
      <script defer src="/embed-frame.js"></script>
    </head>
    <body class="kiln-embed-body bg-transparent p-4">
      <div class="card card-pad">
        <h1 class="text-lg font-semibold tracking-tight #{tone_class}">#{h(heading)}</h1>
        <p class="mt-2 text-sm text-base-content/80">#{h(message)}</p>
      </div>
    </body>
    </html>
    """
  end

  defp embed_tone(:error), do: {"text-error", gettext("Something needs fixing")}
  defp embed_tone(:ok), do: {"text-base-content", gettext("Thank you")}

  # Only same-origin referers are offered as a back link (an open redirect
  # otherwise). Anything else falls back to no link.
  defp back(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{host: host, path: path} when is_binary(path) <- URI.parse(referer),
         true <- host in [nil, conn.host],
         true <- local_path?(path) do
      path
    else
      _ -> nil
    end
  end

  # A same-host referer can still carry a path a browser reads as another
  # host: `//evil.example/x` is protocol-relative, and browsers treat `\`
  # like `/`, so `/\evil.example` is one too.
  defp local_path?("/" <> rest), do: not String.starts_with?(rest, ["/", "\\"])
  defp local_path?(_path), do: false

  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
