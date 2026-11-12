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
  alias KilnCMS.Forms.Autoresponder

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
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # A full copy — settings and fields — created inactive so the duplicate
  # doesn't instantly render publicly under its new slug.
  #
  # The copy's autoresponder is created off and turned on (when the original's
  # is) only once the fields exist: its token check reads the copy's own
  # fields, so an enabled template using `[field:…]` would otherwise refuse
  # the copy outright. A field named like the honeypot (#2267) can't be
  # created any more, so the copy takes the next free name and its tokens
  # follow; a field that still fails is reported rather than dropped silently.
  def handle_event("duplicate_form", %{"id" => id}, socket) when is_binary(id) do
    opts = actor_opts(socket)

    with {:ok, form} <- CMS.get_form(id, opts),
         {:ok, copy} <-
           CMS.create_form(
             Map.merge(copied_settings(form), %{
               name: gettext("%{name} (copy)", name: form.name),
               slug: unique_slug(form.slug, socket.assigns.forms),
               active: false,
               autoresponder_enabled: false
             }),
             opts
           ) do
      {renames, failed} = copy_fields(form, copy, opts)
      autoresponder = finish_autoresponder(form, copy, renames, opts)

      {:noreply,
       socket
       |> load_forms()
       |> put_flash(:info, duplicated_message(renames))
       |> put_duplicate_errors(failed, autoresponder)}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
      _other -> {:noreply, put_flash(socket, :error, gettext("Couldn't duplicate that form."))}
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

  # Copies `form`'s fields onto `copy`, renaming a reserved name to the first
  # free `website_2`, `website_3`, … Returns the renames made (`[{old, new}]`)
  # and the source names of the fields that couldn't be created.
  defp copy_fields(form, copy, opts) do
    fields = CMS.form_fields_for!(form.id, opts)

    {renames, failed} =
      Enum.reduce(fields, {[], []}, fn field, {renames, failed} ->
        name =
          if KilnCMS.Forms.reserved_field_name?(field.name),
            do: KilnCMS.Forms.unique_field_name(field.name, fields),
            else: field.name

        attrs =
          field
          |> KilnCMS.Forms.copyable_field_attrs()
          |> Map.merge(%{form_id: copy.id, name: name, position: field.position})

        case CMS.create_form_field(attrs, opts) do
          {:ok, _field} when name != field.name -> {[{field.name, name} | renames], failed}
          {:ok, _field} -> {renames, failed}
          {:error, _error} -> {renames, [field.name | failed]}
        end
      end)

    {Enum.reverse(renames), Enum.reverse(failed)}
  end

  # Once the fields exist: first the renamed tokens (the copy's autoresponder
  # is still off, so its templates aren't checked yet), then the original's
  # switch, checked against the copy's fields. Two writes, so a switch the
  # check refuses doesn't take the token renames down with it.
  defp finish_autoresponder(form, copy, renames, opts) do
    with {:ok, copy} <-
           write_if_changed(copy, Autoresponder.rename_field_tokens(form, Map.new(renames)), opts),
         {:ok, _copy} <-
           write_if_changed(
             copy,
             if(form.autoresponder_enabled, do: %{autoresponder_enabled: true}, else: %{}),
             opts
           ) do
      :ok
    end
  end

  defp write_if_changed(copy, changes, _opts) when changes == %{}, do: {:ok, copy}
  defp write_if_changed(copy, changes, opts), do: CMS.update_form(copy, changes, opts)

  defp duplicated_message([]), do: gettext("Form duplicated (inactive until you activate it).")

  defp duplicated_message(renames) do
    gettext(
      "Form duplicated (inactive until you activate it). The field “%{old}” was renamed “%{new}” in the copy: that name is reserved for spam protection.",
      old: Enum.map_join(renames, ", ", &elem(&1, 0)),
      new: Enum.map_join(renames, ", ", &elem(&1, 1))
    )
  end

  defp put_duplicate_errors(socket, failed, autoresponder) do
    messages =
      Enum.reject(
        [failed_fields_message(failed), autoresponder_message(autoresponder)],
        &is_nil/1
      )

    if messages == [], do: socket, else: put_flash(socket, :error, Enum.join(messages, " "))
  end

  defp failed_fields_message([]), do: nil

  defp failed_fields_message(names) do
    ngettext(
      "Form duplicated, but a field couldn't be copied: %{names}.",
      "Form duplicated, but %{count} fields couldn't be copied: %{names}.",
      length(names),
      names: Enum.join(names, ", ")
    )
  end

  defp autoresponder_message(:ok), do: nil

  defp autoresponder_message({:error, error}),
    do: gettext("The copy's autoresponder stays off: %{reason}", reason: error_message(error))

  # A slug not yet taken by any listed form: `contact-copy`, `contact-copy-2`, …
  # Every attribute the create action accepts, read off the resource rather than
  # listed here. The hand-written list this replaces had already drifted — the
  # three autoresponder fields were never copied — and since #648 a missed
  # attribute is a security default rather than a cosmetic one: a copy that
  # lost `embed_origins` silently falls back to the deployment-wide allowlist,
  # which on a multi-org instance is every other org's embedders.
  defp copied_settings(form) do
    KilnCMS.CMS.Form
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> Map.new(&{&1, Map.get(form, &1)})
  end

  defp unique_slug(slug, forms) do
    taken = MapSet.new(forms, & &1.slug)
    base = "#{slug}-copy"

    [base | Enum.map(2..1000, &"#{base}-#{&1}")]
    |> Enum.find(&(!MapSet.member?(taken, &1)))
  end

  defp error_message(%{errors: errors}) when is_list(errors) and errors != [] do
    errors
    |> Enum.map_join("; ", fn
      %{field: field, message: message} when not is_nil(field) -> "#{field} #{message}"
      %{message: message} when is_binary(message) -> message
      other -> inspect(other)
    end)
  end

  defp error_message(_error), do: gettext("Something went wrong.")

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
                  title={gettext("Duplicate %{name}", name: form.name)}
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
