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
  alias KilnCMSWeb.Embed
  alias KilnCMSWeb.Tenant

  # The embed page is public and changes only when an admin edits the form, so a
  # short shared-cache window is safe; a deactivated form disappears within it.
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
    conn = put_embed_csp(conn)

    case Forms.get_active(slug, Tenant.current_org_id(conn)) do
      nil ->
        conn |> put_status(404) |> html(page(gettext_msg("Form not found."), nil, embed: true))

      form ->
        conn
        |> put_resp_header("cache-control", "public, max-age=#{@embed_max_age_seconds}")
        |> put_view(KilnCMSWeb.FormHTML)
        |> render(:embed, form: form)
    end
  end

  # Replace the site-wide CSP (frame-ancestors 'self') with the embed policy.
  # `put_resp_header/3` overwrites, so this wins over `put_secure_browser_headers`.
  defp put_embed_csp(conn) do
    put_resp_header(conn, "content-security-policy", Embed.content_security_policy())
  end

  # An embedded form marks its submission so the thank-you page keeps a framing-
  # friendly CSP — otherwise it would render blank inside the iframe.
  defp embedded?(params), do: params["_kiln_embed"] == "1"

  def schema(conn, %{"slug" => slug}) do
    case Forms.get_active(slug, Tenant.current_org_id(conn)) do
      nil ->
        error(conn, 404, "not_found", "Form not found.")

      form ->
        json(conn, %{
          slug: form.slug,
          name: form.name,
          description: form.description,
          success_message: form.success_message,
          submit_label: form.submit_label,
          progress_indicator: form.progress_indicator,
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
                width: field.width,
                validation: field.validation,
                conditions: field.conditions
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
    conn = if embedded?, do: put_embed_csp(conn), else: conn
    # Inside an iframe the referer is the embed page itself, so a "Back" link
    # would just reload the empty form — omit it there.
    back_href = if embedded?, do: nil, else: back(conn)

    case run(conn, slug, params) do
      :not_found ->
        conn
        |> put_status(404)
        |> html(page(gettext_msg("Form not found."), nil, embed: embedded?))

      {:ok, form} ->
        html(
          conn,
          page(
            form.success_message || gettext_msg("Thanks — we got your message."),
            back_href,
            embed: embedded?
          )
        )

      {:error, form, errors} ->
        conn
        |> put_status(422)
        |> html(page(error_text(form, errors), back_href, embed: embedded?))
    end
  end

  # Headless (JSON) submission.
  def submit_json(conn, %{"slug" => slug} = params) do
    case run(conn, slug, params) do
      :not_found ->
        error(conn, 404, "not_found", "Form not found.")

      {:ok, form} ->
        json(conn, %{ok: true, message: form.success_message})

      {:error, _form, errors} ->
        conn |> put_status(422) |> json(%{ok: false, errors: errors})
    end
  end

  defp run(conn, slug, params) do
    case Forms.get_active(slug, Tenant.current_org_id(conn)) do
      nil ->
        :not_found

      form ->
        case Forms.submit(form, params, locale: params["locale"]) do
          # A tripped honeypot reports success too — bots learn nothing.
          {:ok, _submission_or_discarded} -> {:ok, form}
          {:error, errors} -> {:error, form, errors}
        end
    end
  end

  # A dependency-free thank-you/error page (public pages may be fired
  # artifacts, so there's no LiveView context to return into).
  #
  # `embed: true` loads the height reporter and drops the wide margins, so the
  # iframe shrinks to the (much shorter) message instead of keeping the form's
  # height. Both are safe under the embed CSP: an external script from 'self'.
  defp page(message, back_href, opts) do
    embed? = Keyword.get(opts, :embed, false)

    back =
      if back_href,
        do:
          ~s(<p><a href="#{Phoenix.HTML.html_escape(back_href) |> Phoenix.HTML.safe_to_string()}">&larr; Back</a></p>),
        else: ""

    resizer = if embed?, do: ~s(<script defer src="/embed-frame.js"></script>), else: ""

    body_style =
      if embed?,
        do: "font-family: system-ui, sans-serif; margin: 0; padding: 1rem",
        else:
          "font-family: system-ui, sans-serif; max-width: 36rem; margin: 4rem auto; padding: 0 1rem"

    """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>#{h(message)}</title>#{resizer}</head>
    <body style="#{body_style}">
    <p>#{h(message)}</p>
    #{back}
    </body></html>
    """
  end

  defp error_text(_form, errors) do
    detail = Enum.map_join(errors, "; ", fn {field, message} -> "#{field} #{message}" end)
    gettext_msg("Your submission couldn't be saved: ") <> detail
  end

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

  defp error(conn, status, code, detail) do
    conn
    |> put_status(status)
    |> json(%{errors: [%{status: to_string(status), code: code, detail: detail}]})
  end

  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  # Static user-facing strings; gettext needs a compile-time binding here so
  # keep the indirection minimal.
  defp gettext_msg(msg), do: Gettext.gettext(KilnCMSWeb.Gettext, msg)
end
