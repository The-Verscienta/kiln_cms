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

  def schema(conn, %{"slug" => slug}) do
    case Forms.get_active(slug) do
      nil ->
        error(conn, 404, "not_found", "Form not found.")

      form ->
        json(conn, %{
          slug: form.slug,
          name: form.name,
          description: form.description,
          success_message: form.success_message,
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
                help_text: field.help_text
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
    case run(slug, params) do
      :not_found ->
        conn |> put_status(404) |> html(page(gettext_msg("Form not found."), nil))

      {:ok, form} ->
        html(
          conn,
          page(form.success_message || gettext_msg("Thanks — we got your message."), back(conn))
        )

      {:error, form, errors} ->
        conn
        |> put_status(422)
        |> html(page(error_text(form, errors), back(conn)))
    end
  end

  # Headless (JSON) submission.
  def submit_json(conn, %{"slug" => slug} = params) do
    case run(slug, params) do
      :not_found ->
        error(conn, 404, "not_found", "Form not found.")

      {:ok, form} ->
        json(conn, %{ok: true, message: form.success_message})

      {:error, _form, errors} ->
        conn |> put_status(422) |> json(%{ok: false, errors: errors})
    end
  end

  defp run(slug, params) do
    case Forms.get_active(slug) do
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
  defp page(message, back_href) do
    back =
      if back_href,
        do:
          ~s(<p><a href="#{Phoenix.HTML.html_escape(back_href) |> Phoenix.HTML.safe_to_string()}">&larr; Back</a></p>),
        else: ""

    """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>#{h(message)}</title></head>
    <body style="font-family: system-ui, sans-serif; max-width: 36rem; margin: 4rem auto; padding: 0 1rem">
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
