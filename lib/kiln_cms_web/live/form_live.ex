defmodule KilnCMSWeb.FormLive do
  @moduledoc """
  The forms index (`/editor/forms`, admin-only like webhooks): create, list,
  duplicate, and delete public forms. Building a form — its fields, settings,
  embed code, and entries — happens in the visual builder
  (`KilnCMSWeb.FormBuilderLive`, `/editor/forms/:id`). Public rendering
  happens through the `:form` content block, the form's own public page
  (`GET /forms/:slug`, #2138, which each active form's row links to alongside
  its embed snippet and `GET /api/forms/:slug`) or the iframe embed
  (`GET /forms/:slug/embed`); submissions arrive via `POST /forms/:slug` (see
  `KilnCMS.Forms`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Forms.Duplicate

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:page_title, gettext("Forms"))
     |> load_forms()}
  end

  @impl true
  def handle_event("create_form", %{"form" => params}, socket) when is_map(params) do
    case CMS.create_form(params, actor_opts(socket)) do
      {:ok, form} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Form created — add its fields."))
         |> push_navigate(to: ~p"/editor/forms/#{form.id}")}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           ash_error_message(error,
             forbidden: gettext("You don't have permission to create forms.")
           )
         )}
    end
  end

  # A full copy — settings and fields — in one transaction
  # (`KilnCMS.Forms.Duplicate`, #2717): a field that can't be copied leaves no
  # partial copy behind, and the flash names it.
  def handle_event("duplicate_form", %{"id" => id}, socket) when is_binary(id) do
    opts = actor_opts(socket)

    with {:ok, form} <- CMS.get_form(id, opts),
         {:ok, result} <-
           Duplicate.run(form, [name: gettext("%{name} (copy)", name: form.name)] ++ opts) do
      {:noreply,
       socket
       |> load_forms()
       |> put_flash(:info, duplicated_message(result.renames))
       |> put_autoresponder_note(result.autoresponder)}
    else
      {:error, {:field, name, error}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Couldn't duplicate “%{form}”, so nothing was created. Fix the field “%{field}” in this form and try again: %{reason}",
             form: form_name(socket, id),
             field: name,
             reason: ash_error_message(error)
           )
         )}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           ash_error_message(error,
             forbidden: gettext("You don't have permission to duplicate forms."),
             fallback: gettext("Couldn't duplicate that form.")
           )
         )}
    end
  end

  # Pushed by the `Clipboard` hook once the embed snippet is on the clipboard.
  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Embed code copied to clipboard."))}

  def handle_event("delete_form", %{"id" => id}, socket) when is_binary(id) do
    opts = actor_opts(socket)

    with {:ok, form} <- CMS.get_form(id, opts),
         :ok <- CMS.destroy_form(form, opts) do
      {:noreply,
       socket
       |> load_forms()
       |> put_flash(:info, gettext("Form deleted."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't delete that form."))}
    end
  end

  # --- data --------------------------------------------------------------------

  defp actor_opts(socket),
    do: [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

  defp load_forms(socket) do
    assign(
      socket,
      :forms,
      CMS.list_forms!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        load: [:submission_count],
        query: [sort: [inserted_at: :asc]]
      )
    )
  end

  # The addresses that actually answer for an active form (#1783): the form's
  # public page (`GET /forms/:slug`, #2138 — #1783 linked the iframe document at
  # `/forms/:slug/embed` instead, because there was no page then) and the
  # headless schema (`GET /api/forms/:slug`). On the org's own host, like the
  # embed snippet (#557).
  defp hosted_url(form, org), do: KilnCMSWeb.Tenant.base_url(org) <> "/forms/#{form.slug}"
  defp api_url(form, org), do: KilnCMSWeb.Tenant.base_url(org) <> "/api/forms/#{form.slug}"

  defp duplicated_message([]), do: gettext("Form duplicated (inactive until you activate it).")

  defp duplicated_message(renames) do
    Enum.join(
      [duplicated_message([]) | Enum.map(renames, &renamed_message/1)],
      " "
    )
  end

  # One sentence per renamed field, saying why its name is reserved.
  defp renamed_message({old, new}) do
    case KilnCMS.Forms.reserved_field_reason(old) do
      :honeypot ->
        gettext(
          "The field “%{old}” was renamed “%{new}” in the copy: that name is reserved for spam protection.",
          old: old,
          new: new
        )

      :locale ->
        gettext(
          "The field “%{old}” was renamed “%{new}” in the copy: that name is reserved for the submission's language.",
          old: old,
          new: new
        )
    end
  end

  defp form_name(socket, id),
    do: Enum.find_value(socket.assigns.forms, "", &(&1.id == id && &1.name))

  # The copy commits either way; its autoresponder only stays off when the
  # original's template names a field the copy doesn't have (or is blank).
  defp put_autoresponder_note(socket, {:off, []}) do
    put_flash(
      socket,
      :error,
      gettext(
        "The copy's autoresponder stays off: its subject or body is blank. Fill both in the copy's settings to turn it on."
      )
    )
  end

  defp put_autoresponder_note(socket, {:off, tokens}) do
    put_flash(
      socket,
      :error,
      gettext(
        "The copy's autoresponder stays off: its template names a field the copy doesn't have (%{tokens}).",
        tokens: Enum.map_join(tokens, ", ", &"[#{&1}]")
      )
    )
  end

  defp put_autoresponder_note(socket, _copied_or_off), do: socket

  # --- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:forms}
    >
      <div class="space-y-8">
        <div>
          <Layouts.console_crumb
            current_user={@current_user}
            current_org={@current_org}
            active={:forms}
          />
          <div class="mt-1 flex flex-wrap items-center justify-between gap-3">
            <h1 class="text-2xl font-semibold">{gettext("Forms")}</h1>
            <.link navigate={~p"/editor/forms/settings"} class="btn btn-ghost btn-sm">
              {gettext("Form settings")}
            </.link>
          </div>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Build public forms, place them on content with the form block, and review submissions here."
            )}
          </p>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Add a form")}</h2>
          <form phx-submit="create_form" class="card card-pad grid gap-3 sm:grid-cols-2">
            <div>
              <label for="form-name" class="text-sm font-medium">{gettext("Name")}</label>
              <input id="form-name" name="form[name]" required class="field-input mt-1" />
            </div>
            <div>
              <label for="form-slug" class="text-sm font-medium">{gettext("Slug")}</label>
              <input
                id="form-slug"
                name="form[slug]"
                required
                placeholder="contact"
                class="field-input mt-1"
              />
            </div>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Create form")}</.button>
            </div>
          </form>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Your forms")} ({length(@forms)})</h2>
          <.empty_state
            :if={@forms == []}
            icon="hero-clipboard-document-list"
            title={gettext("No forms yet")}
          >
            {gettext("Create a form above to start collecting submissions.")}
          </.empty_state>
          <ul :if={@forms != []} class="card divide-y divide-base-content/10 overflow-hidden">
            <li :for={form <- @forms} id={"form-row-#{form.id}"} class="space-y-2 p-3">
              <div class="flex items-center justify-between gap-3">
                <.link
                  navigate={~p"/editor/forms/#{form.id}"}
                  class="min-w-0 flex-1 truncate text-left font-medium hover:underline"
                >
                  {form.name}
                </.link>
                <span :if={!form.active} class="rounded bg-base-200 px-1.5 py-0.5 text-xs">
                  {gettext("Inactive")}
                </span>
                <span class="text-xs text-base-content/70">
                  {gettext("%{count} submissions", count: form.submission_count)}
                </span>
                <button
                  type="button"
                  phx-click="duplicate_form"
                  phx-value-id={form.id}
                  aria-label={gettext("Duplicate %{name}", name: form.name)}
                  title={
                    gettext(
                      "Duplicate %{name}: copies its settings and fields; its entries stay with the original.",
                      name: form.name
                    )
                  }
                  class="btn btn-sm btn-ghost"
                >
                  <.icon name="hero-square-2-stack" class="size-4" />
                </button>
                <button
                  type="button"
                  phx-click="delete_form"
                  phx-value-id={form.id}
                  data-confirm={gettext("Delete %{name} and all its submissions?", name: form.name)}
                  aria-label={gettext("Delete %{name}", name: form.name)}
                  title={gettext("Delete %{name}", name: form.name)}
                  class="btn btn-sm btn-ghost hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
              <%!-- #1783: only addresses that answer — the form's public page
                    (`/forms/:slug`, served since #2138), the embed snippet, and
                    the JSON API, each labelled for what it is. An inactive form
                    answers 404 on all three, so it advertises none of them. --%>
              <div
                :if={form.active}
                id={"form-links-#{form.id}"}
                class="space-y-2 text-xs text-base-content/70"
              >
                <dl class="grid gap-x-3 gap-y-1 sm:grid-cols-[auto_1fr]">
                  <dt class="font-medium">{gettext("Hosted form")}</dt>
                  <dd class="min-w-0">
                    <a
                      href={hosted_url(form, @current_org)}
                      target="_blank"
                      rel="noopener"
                      data-role="hosted-form"
                      class="break-all font-mono hover:underline"
                    >
                      {hosted_url(form, @current_org)}
                      <span class="sr-only">{gettext("(opens in a new tab)")}</span>
                    </a>
                  </dd>
                  <dt class="font-medium">{gettext("JSON API")}</dt>
                  <dd class="min-w-0">
                    <code data-role="json-api" class="break-all">
                      {api_url(form, @current_org)}
                    </code>
                  </dd>
                </dl>
                <div class="flex items-center gap-2">
                  <input
                    type="text"
                    readonly
                    value={KilnCMSWeb.Embed.form_snippet(form.slug, @current_org)}
                    aria-label={gettext("Embed code for %{name}", name: form.name)}
                    class="field-input min-w-0 flex-1 font-mono text-xs"
                  />
                  <button
                    type="button"
                    id={"copy-embed-#{form.id}"}
                    phx-hook="Clipboard"
                    data-clipboard-text={KilnCMSWeb.Embed.form_snippet(form.slug, @current_org)}
                    aria-label={gettext("Copy embed code for %{name}", name: form.name)}
                    class="btn btn-sm btn-default shrink-0"
                  >
                    <.icon name="hero-clipboard-document" class="size-4" />
                    {gettext("Copy")}
                  </button>
                </div>
              </div>
              <p
                :if={!form.active}
                id={"form-links-#{form.id}"}
                class="text-xs text-base-content/70"
              >
                {gettext(
                  "Not public yet: activate it in the form builder to get its hosted page, embed code and API address."
                )}
              </p>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
