defmodule KilnCMSWeb.SecurityTxtLive do
  @moduledoc """
  The site's `/.well-known/security.txt` (RFC 9116, #1873): where a security
  researcher reports a vulnerability in this site.

  Scoped to the request's org like `/editor/branding` — each site answers for
  its own security. Writes are policy-gated to org admins by
  `KilnCMS.CMS.SiteSecurityTxt`, and this LiveView sits in the `:admin_routes`
  live session whose tier gate agrees.

  The page shows the file exactly as it is served (`KilnCMS.SecurityTxt.render/2`)
  and warns when `Expires` has passed, is within 30 days, or is further out
  than the year RFC 9116 recommends. An expired file is still served — a stale
  contact is more use to a researcher than none — but the RFC tells them to
  treat it as stale, so the warning is the prompt to renew it.

  Contacts and languages are lists; the form takes contacts one per line and
  languages comma-separated, and splitting on line breaks there is what keeps a
  line break from ever reaching a single value. The single-line URL fields are
  held to one line by the resource's validation.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.SecurityTxt

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Security contact"))
     |> assign(:canonical_url, SecurityTxt.canonical_url(socket.assigns.current_org))
     |> load_settings()}
  end

  @impl true
  def handle_event("save", %{"security_txt" => params}, socket) when is_map(params) do
    case CMS.save_site_security_txt(attrs(params),
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("security.txt saved."))
         |> load_settings()}

      {:error, error} ->
        # Keep what the admin typed: the refusal names the one value to fix.
        {:noreply,
         socket
         |> put_flash(:error, error_message(error))
         |> assign(:form, to_form(params, as: :security_txt))}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket) do
    # Re-read rather than destroying the struct assigned at mount: a second tab
    # may already have dropped it (the `FeedSettingsLive` reasoning).
    case current_row(socket) do
      nil ->
        {:noreply, load_settings(socket)}

      row ->
        case CMS.reset_site_security_txt(row,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_org
             ) do
          {:error, error} ->
            {:noreply, socket |> put_flash(:error, error_message(error)) |> load_settings()}

          _destroyed ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("security.txt removed. The site no longer serves one."))
             |> load_settings()}
        end
    end
  end

  # Form params (client-controlled; any value may be a bare binary or absent)
  # to the resource's attributes. Blank single-line fields become nil; the
  # lists are split here and judged entry by entry by the validation.
  defp attrs(params) do
    %{
      contacts: params |> text("contacts") |> String.split(~r/\R/u) |> clean_list(),
      expires_on: date(text(params, "expires_on")),
      policy_url: blank_to_nil(text(params, "policy_url")),
      preferred_languages:
        params |> text("preferred_languages") |> String.split([",", " "]) |> clean_list(),
      encryption_url: blank_to_nil(text(params, "encryption_url")),
      acknowledgments_url: blank_to_nil(text(params, "acknowledgments_url"))
    }
  end

  defp text(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp clean_list(values), do: values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  # Only surrounding spaces are trimmed — a line break inside the value is left
  # for the validation to refuse, never silently repaired into something else.
  defp blank_to_nil(value) do
    case String.trim(value, " ") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp date(""), do: nil

  defp date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      # Handed through as written so the attribute's own cast refuses it,
      # rather than being dropped into "no expiry".
      {:error, _reason} -> value
    end
  end

  defp load_settings(socket) do
    row = current_row(socket)

    socket
    |> assign(:row, row)
    |> assign(:form, to_form(form_params(row), as: :security_txt))
    |> assign(:preview, preview(row, socket.assigns.canonical_url))
    |> assign(
      :expiry,
      SecurityTxt.expiry_status(row && row.expires_on, Date.utc_today())
    )
  end

  defp current_row(socket) do
    case CMS.list_site_security_txt(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  defp form_params(nil), do: %{}

  defp form_params(row) do
    %{
      "contacts" => Enum.join(row.contacts || [], "\n"),
      "expires_on" => row.expires_on && Date.to_iso8601(row.expires_on),
      "policy_url" => row.policy_url,
      "preferred_languages" => Enum.join(row.preferred_languages || [], ", "),
      "encryption_url" => row.encryption_url,
      "acknowledgments_url" => row.acknowledgments_url
    }
  end

  # The file as `/.well-known/security.txt` serves it, or nil when it 404s.
  defp preview(row, canonical_url) do
    case SecurityTxt.build(row) do
      {:ok, settings} -> SecurityTxt.render(settings, canonical_url)
      :unconfigured -> nil
    end
  end

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's security.txt."),
      fallback: gettext("security.txt could not be saved.")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:security_txt}
    >
      <.header>
        {gettext("Security contact")}
        <:subtitle>
          {gettext(
            "Where a security researcher reports a vulnerability in this site, published as /.well-known/security.txt (RFC 9116)."
          )}
        </:subtitle>
      </.header>

      <div
        :if={is_nil(@preview)}
        id="security-txt-unpublished"
        class="mt-6 rounded-lg border border-base-300 bg-base-200 p-4 text-sm"
      >
        <p class="font-medium">{gettext("This site does not publish a security.txt.")}</p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "It answers 404 until a contact is set below. Add at least one contact and an expiry date to publish it."
          )}
        </p>
      </div>

      <div
        :if={@preview && @expiry in [:expired, :expiring, :too_far]}
        id="security-txt-expiry"
        role="status"
        class={[
          "mt-6 flex gap-3 rounded-lg border p-4 text-sm",
          @expiry == :expired && "border-error/40 bg-error/10",
          @expiry != :expired && "border-warning/40 bg-warning/10"
        ]}
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
        <div>
          <p class="font-medium">{expiry_title(@expiry)}</p>
          <p class="mt-1 text-base-content/70">{expiry_detail(@expiry)}</p>
        </div>
      </div>

      <.form for={@form} id="security-txt-form" phx-submit="save" class="mt-8 max-w-2xl space-y-6">
        <.input
          field={@form[:contacts]}
          type="textarea"
          rows="3"
          label={gettext("Contacts (one per line, preferred first)")}
          placeholder="mailto:security@example.com"
        />
        <p class="-mt-4 text-xs text-base-content/60">
          {gettext("A mailto:, https:// or tel: address. Required to publish the file.")}
        </p>

        <.input
          field={@form[:expires_on]}
          type="date"
          label={gettext("Expires")}
        />
        <p class="-mt-4 text-xs text-base-content/60">
          {gettext(
            "Required with a contact. Researchers treat the file as stale after this date; the RFC recommends less than a year ahead."
          )}
        </p>

        <.input
          field={@form[:policy_url]}
          type="url"
          label={gettext("Disclosure policy URL")}
          placeholder="https://example.com/security"
        />

        <.input
          field={@form[:preferred_languages]}
          type="text"
          label={gettext("Preferred languages")}
          placeholder="en, fr"
        />

        <.input
          field={@form[:encryption_url]}
          type="text"
          label={gettext("Encryption key")}
          placeholder="https://example.com/pgp-key.txt"
        />
        <p class="-mt-4 text-xs text-base-content/60">
          {gettext("An https:// URL to a public key, or an openpgp4fpr: fingerprint.")}
        </p>

        <.input
          field={@form[:acknowledgments_url]}
          type="url"
          label={gettext("Acknowledgments URL")}
          placeholder="https://example.com/hall-of-fame"
        />

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <button
            :if={@row}
            type="button"
            phx-click="reset"
            data-confirm={gettext("Remove this site's security.txt? It will answer 404.")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Remove security.txt")}
          </button>
        </div>
      </.form>

      <section :if={@preview} class="mt-10 max-w-2xl">
        <h2 class="text-sm font-medium">{gettext("As served")}</h2>
        <p class="mt-1 text-xs text-base-content/60">
          <a href={@canonical_url} target="_blank" rel="noopener" class="link">{@canonical_url}</a>
        </p>
        <pre
          id="security-txt-preview"
          class="mt-3 overflow-x-auto rounded-lg bg-base-200 p-4 font-mono text-xs"
        >{@preview}</pre>
      </section>
    </Layouts.console>
    """
  end

  defp expiry_title(:expired), do: gettext("This security.txt has expired.")
  defp expiry_title(:expiring), do: gettext("This security.txt expires within 30 days.")
  defp expiry_title(:too_far), do: gettext("This expiry date is more than a year away.")

  defp expiry_detail(:expired),
    do:
      gettext(
        "It is still served, but researchers are told to treat an expired file as stale. Set a new date and save."
      )

  defp expiry_detail(:expiring),
    do: gettext("Check the contacts are still read, then move the date forward and save.")

  defp expiry_detail(:too_far),
    do:
      gettext(
        "RFC 9116 recommends an expiry less than a year ahead, so a forgotten file goes stale."
      )
end
