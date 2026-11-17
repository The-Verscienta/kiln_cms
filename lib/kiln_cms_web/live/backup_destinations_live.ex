defmodule KilnCMSWeb.BackupDestinationsLive do
  @moduledoc """
  The Destinations tab of the Backups pages (`/editor/backups/destinations`,
  #2220): where in-app backups copy their finished files besides
  `BACKUP_DIR`, and the forms to add, edit, test, reorder, enable, disable
  and delete those destinations (`KilnCMS.Backups.DestinationConfig`).

  ## Platform admins only

  A destination receives a dump of the whole instance, so, as on
  `KilnCMSWeb.BackupLive`, the route's per-org admin gate is not the
  question: `mount/3`, `handle_params/3`, every `handle_event/3` and every
  `handle_async/3` ask `KilnCMSWeb.LiveUserAuth.platform_admin?/1` again (a
  user demoted, or whose grant expired, since the mount is sent to the
  access-denied page, #1160, #2875), and every read and write goes through
  the `KilnCMS.Backups` code interfaces as the admin, so the destination's
  policies decide as well.

  Every handler that names a destination takes only its **id** from the
  client and reads the destination again as the admin
  (`Backups.get_backup_destination/2`): one deleted in another tab, or an id
  that was never one, is a flash, not a crash. The kind of a new destination
  is the one picked from the adapters this page offers, kept on the server;
  a submitted `kind` is never read.

  ## The env destination

  `BACKUP_RCLONE_REMOTE`, when it is set, is listed first and read-only,
  with where it comes from: it is changed in the server's environment, never
  here, and the stored destinations add to it rather than replace it
  (decision E2).

  ## The form

  Generated from the adapter's `fields/0`, labelled by each field's name,
  humanized. A `:secret` field is a password input that is never filled in:
  the stored value never leaves the vault column, so on edit a blank one
  keeps it. Its input is `phx-update="ignore"`, so what the admin typed
  survives a re-render without the server ever sending it back, a failed
  save included. Where a destination writes (`Destination.location_fields/1`)
  is fixed once it is stored, so those fields are read-only on edit and the
  stored values are what is saved. A Local destination is offered only when
  `BACKUP_LOCAL_DESTINATION_ROOTS` lists somewhere it may write
  (`Destination.Local.available?/0`).

  Validation runs on Save, not on every keystroke: it calls the adapter's
  `validate/1` (an `rclone listremotes` for a stored Rclone remote), which is
  no work to do per key press.

  ## Test

  The **Test** button runs `Backups.test_destination/2` in a `start_async/3`
  task, one at a time per destination: a click while that destination's test
  runs does nothing. The result (redacted of the destination's secrets, and
  the node it ran on) is recorded on the row and shown there and in a flash.
  """
  use KilnCMSWeb, :live_view

  import KilnCMSWeb.BackupComponents, only: [tabs: 1]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, DestinationConfig}
  alias KilnCMS.Backups.Destination.{Local, S3}
  alias KilnCMS.Backups.DestinationConfig.Fields

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backup destinations"))
       |> assign(:testing, MapSet.new())
       |> close_form()
       |> load()}
    else
      # As `BackupLive`: the route's gate is any site admin, a destination is
      # instance-wide.
      {:ok, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: {:noreply, socket},
      else: deny(socket)
  end

  @events ~w(new pick edit cancel validate save toggle delete move test)

  # Every event asks again, whatever it is: see the moduledoc. An event this
  # page doesn't have falls to the catch-all every Kiln LiveView gets
  # (`KilnCMSWeb.MalformedEvent`).
  @impl true
  def handle_event(event, params, socket) when event in @events do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: event(event, params, socket),
      else: deny(socket)
  end

  # A Test's result, applied only for someone who is still a platform admin:
  # a demoted admin's page is sent away, not told how the test went.
  @impl true
  def handle_async({:test, id}, result, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:noreply,
       socket
       |> update(:testing, &MapSet.delete(&1, id))
       |> put_test_flash(result)
       |> load()}
    else
      deny(socket)
    end
  end

  # A user who stopped being a platform admin mid-session (demoted, or their
  # grant expired) is sent where the mount would have sent them (#2875).
  # Nothing is read, tested or written first.
  defp deny(socket),
    do: {:noreply, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}

  # Add and Edit are hidden while a form is open; a click already on its way
  # doesn't discard the open one.
  defp event(event, _params, %{assigns: %{editing: editing}} = socket)
       when event in ["new", "edit"] and editing != nil,
       do: {:noreply, socket}

  defp event("new", _params, socket), do: {:noreply, assign(socket, :picking?, true)}

  # Only a kind this page offers: installed, and Local only where it may
  # write somewhere.
  defp event("pick", %{"kind" => kind}, %{assigns: %{picking?: true}} = socket)
       when is_binary(kind) do
    case Enum.find(offered_adapters(), &(&1.kind == kind)) do
      nil ->
        {:noreply, socket}

      adapter ->
        params = %{"name" => "", "enabled" => "true", "prune" => "true", "settings" => %{}}
        {:noreply, open_form(socket, :new, adapter.kind, adapter.fields, params)}
    end
  end

  defp event("edit", %{"id" => id}, socket) when is_binary(id) do
    with_destination(socket, id, fn row ->
      {:noreply, open_form(socket, row.id, row.kind, fields_of(row.kind), edit_params(row))}
    end)
  end

  defp event("cancel", _params, socket), do: {:noreply, close_form(socket)}

  # Only remembered, so a re-render shows what was typed: never validated
  # here (see the moduledoc), and never the secrets, which the server keeps
  # out of the page.
  defp event("validate", %{"destination" => params}, %{assigns: %{editing: e}} = socket)
       when is_map(params) and e != nil do
    {:noreply, assign_params(socket, params)}
  end

  defp event("save", %{"destination" => params}, %{assigns: %{editing: :new}} = socket)
       when is_map(params) do
    %{kind: kind, fields: fields} = socket.assigns

    attrs = %{
      name: text(params["name"]),
      kind: kind,
      enabled: params["enabled"] == "true",
      prune: params["prune"] == "true",
      position: next_position(socket.assigns.destinations),
      settings: settings_params(params, fields, []),
      secrets: secret_params(params, fields)
    }

    socket
    |> assign_params(params)
    |> saved(
      Backups.create_backup_destination(attrs, write_opts(socket)),
      gettext("Destination added.")
    )
  end

  defp event("save", %{"destination" => params}, %{assigns: %{editing: id}} = socket)
       when is_map(params) and is_binary(id) do
    with_destination(socket, id, fn row ->
      %{fields: fields} = socket.assigns
      locked = Destination.location_fields(row.kind)

      attrs =
        %{
          name: text(params["name"]),
          enabled: params["enabled"] == "true",
          prune: params["prune"] == "true",
          secrets: secret_params(params, fields)
        }
        |> put_settings(row, fields, settings_params(params, fields, locked))

      socket
      |> assign_params(params)
      |> saved(
        Backups.update_backup_destination(row, attrs, write_opts(socket)),
        gettext("Destination saved.")
      )
    end)
  end

  defp event("toggle", %{"id" => id}, socket) when is_binary(id) do
    with_destination(socket, id, fn row ->
      case Backups.update_backup_destination(row, %{enabled: not row.enabled}, write_opts(socket)) do
        {:ok, %{enabled: true}} ->
          {:noreply, socket |> put_flash(:info, gettext("Destination enabled.")) |> load()}

        {:ok, %{enabled: false}} ->
          {:noreply, socket |> put_flash(:info, gettext("Destination disabled.")) |> load()}

        {:error, error} ->
          {:noreply, socket |> put_flash(:error, write_error(error)) |> load()}
      end
    end)
  end

  defp event("delete", %{"id" => id}, socket) when is_binary(id) do
    with_destination(socket, id, fn row ->
      case Backups.destroy_backup_destination(row, write_opts(socket)) do
        :ok ->
          {:noreply,
           socket
           |> close_form_of(row.id)
           |> put_flash(:info, gettext("Destination deleted."))
           |> load()}

        {:error, error} ->
          {:noreply, socket |> put_flash(:error, write_error(error)) |> load()}
      end
    end)
  end

  defp event("move", %{"id" => id, "dir" => dir}, socket)
       when is_binary(id) and dir in ["up", "down"] do
    with_destination(socket, id, fn row -> move(socket, row, dir) end)
  end

  # Single-flight per destination: a click while its test runs does nothing.
  defp event("test", %{"id" => id}, socket) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        if MapSet.member?(socket.assigns.testing, id),
          do: {:noreply, socket},
          else: with_destination(socket, id, &start_test(socket, &1))

      :error ->
        {:noreply, put_flash(socket, :error, gone_flash())}
    end
  end

  # A mangled payload is a no-op (#764).
  defp event(_event, _params, socket), do: {:noreply, socket}

  # `test_destination/2` reads the row again as this admin, in the task, so a
  # refusal there happens before any file or network I/O.
  defp start_test(socket, row) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> update(:testing, &MapSet.put(&1, row.id))
     |> start_async({:test, row.id}, fn -> Backups.test_destination(row.id, actor: user) end)}
  end

  defp put_test_flash(socket, {:ok, {:ok, %DestinationConfig{last_test_ok: true} = row}}),
    do:
      put_flash(
        socket,
        :info,
        gettext("%{name}: the test passed (on %{node}).",
          name: row.name,
          node: row.last_test_node || "—"
        )
      )

  defp put_test_flash(socket, {:ok, {:ok, %DestinationConfig{} = row}}),
    do:
      put_flash(
        socket,
        :error,
        gettext("%{name}: the test failed (on %{node}): %{error}",
          name: row.name,
          node: row.last_test_node || "—",
          error: row.last_test_error || "—"
        )
      )

  defp put_test_flash(socket, {:ok, {:error, :not_found}}),
    do: put_flash(socket, :error, gone_flash())

  defp put_test_flash(socket, {:ok, {:error, error}}),
    do: put_flash(socket, :error, write_error(error))

  defp put_test_flash(socket, {:exit, _reason}),
    do: put_flash(socket, :error, gettext("The test didn't finish. Try again."))

  # The destination `id` as it is stored now, read as this admin: `fun` gets
  # it, and one that is gone (deleted meanwhile, or never was) is a flash.
  defp with_destination(socket, id, fun) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %DestinationConfig{} = row} <-
           Backups.get_backup_destination(id, actor: socket.assigns.current_user) do
      fun.(row)
    else
      {:error, %Ash.Error.Forbidden{} = error} ->
        {:noreply, put_flash(socket, :error, write_error(error))}

      _gone ->
        {:noreply, socket |> close_form_of(id) |> put_flash(:error, gone_flash()) |> load()}
    end
  end

  defp saved(socket, {:ok, _row}, message),
    do: {:noreply, socket |> close_form() |> put_flash(:info, message) |> load()}

  defp saved(socket, {:error, %Ash.Error.Invalid{} = error}, _message),
    do: {:noreply, assign_errors(socket, error)}

  defp saved(socket, {:error, error}, _message),
    do: {:noreply, put_flash(socket, :error, write_error(error))}

  # The new order: `row` swapped with its neighbour, then every destination
  # whose position isn't its index written, each audited. Positions start
  # equal (0), so a swap of two values alone would change nothing.
  defp move(socket, row, dir) do
    case socket.assigns.current_user |> read_destinations() do
      {:ok, rows} ->
        case neighbour(rows, row, dir) do
          {index, other} -> rows |> swap(index, other) |> renumber(socket)
          nil -> {:noreply, socket}
        end

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, write_error(error)) |> load()}
    end
  end

  # `{index, other}` of `row` and the row it swaps with, or nil: a row
  # deleted meanwhile has no index, and the ends don't move further.
  defp neighbour(rows, row, dir) do
    with index when is_integer(index) <- Enum.find_index(rows, &(&1.id == row.id)),
         other = if(dir == "up", do: index - 1, else: index + 1),
         true <- other >= 0 and other < length(rows) do
      {index, other}
    else
      _no_move -> nil
    end
  end

  defp swap(rows, i, j) do
    a = Enum.at(rows, i)
    b = Enum.at(rows, j)
    rows |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  defp renumber(rows, socket) do
    result =
      rows
      |> Enum.with_index()
      |> Enum.reject(fn {row, index} -> row.position == index end)
      |> Enum.reduce_while(:ok, fn {row, index}, :ok ->
        case Backups.update_backup_destination(row, %{position: index}, write_opts(socket)) do
          {:ok, _row} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    case result do
      :ok -> {:noreply, load(socket)}
      {:error, error} -> {:noreply, socket |> put_flash(:error, write_error(error)) |> load()}
    end
  end

  defp write_opts(socket),
    do: [actor: socket.assigns.current_user, context: socket.assigns[:security_context] || %{}]

  defp next_position(rows) when is_list(rows) and rows != [],
    do: rows |> Enum.map(& &1.position) |> Enum.max() |> Kernel.+(1) |> min(10_000)

  defp next_position(_rows), do: 0

  ## The form

  defp open_form(socket, editing, kind, fields, params) do
    socket
    |> assign(:picking?, false)
    |> assign(:editing, editing)
    |> assign(:kind, kind)
    |> assign(:fields, fields)
    |> assign(:locked, if(editing == :new, do: [], else: Destination.location_fields(kind)))
    |> assign(:field_errors, %{})
    |> assign(:form_errors, [])
    |> assign_params(params)
  end

  defp close_form(socket) do
    socket
    |> assign(:picking?, false)
    |> assign(:editing, nil)
    |> assign(:kind, nil)
    |> assign(:fields, [])
    |> assign(:locked, [])
    |> assign(:field_errors, %{})
    |> assign(:form_errors, [])
    |> assign(:params, %{})
    |> assign(:form, nil)
  end

  defp close_form_of(%{assigns: %{editing: id}} = socket, id), do: close_form(socket)
  defp close_form_of(socket, _id), do: socket

  # What the page keeps of the form's params: never the secrets.
  defp assign_params(socket, params) do
    params = Map.delete(params, "secrets")

    socket
    |> assign(:params, params)
    |> assign(:form, to_form(params, as: "destination"))
  end

  # A refused save: each error under its field (a setting's or secret's by
  # the name the validation gives), the rest above the form.
  defp assign_errors(socket, %Ash.Error.Invalid{errors: errors}) do
    names = Enum.map(socket.assigns.fields, & &1.name)

    {by_field, general} =
      errors
      |> Enum.flat_map(&form_errors/1)
      |> Enum.reduce({%{}, []}, fn {field, message, vars}, {by_field, general} ->
        text = translate_error({message, vars})
        name = vars[:name] && to_string(vars[:name])

        cond do
          field in [:settings, :secrets] and name in names ->
            {Map.update(by_field, name, [text], &(&1 ++ [text])), general}

          field in [:name, :enabled, :prune] ->
            key = Atom.to_string(field)
            {Map.update(by_field, key, [text], &(&1 ++ [text])), general}

          true ->
            {by_field, general ++ [text]}
        end
      end)

    socket
    |> assign(:field_errors, by_field)
    |> assign(:form_errors, Enum.uniq(general))
  end

  defp form_errors(error) do
    if AshPhoenix.FormData.Error.impl_for(error) do
      error
      |> AshPhoenix.FormData.Error.to_form_error()
      |> List.wrap()
      |> Enum.map(fn {field, message, vars} -> {field, message, vars || []} end)
    else
      [{nil, Exception.message(error), []}]
    end
  end

  defp edit_params(%DestinationConfig{} = row) do
    %{
      "name" => row.name,
      "enabled" => to_string(row.enabled),
      "prune" => to_string(row.prune),
      "settings" => Map.new(row.settings || %{}, fn {k, v} -> {to_string(k), v} end)
    }
  end

  # The adapter's non-secret fields from the form, as text (the resource
  # casts them to their types). `locked` fields are left out: on edit, where
  # a destination writes is the stored value, never the client's.
  defp settings_params(params, fields, locked) do
    given = if is_map(params["settings"]), do: params["settings"], else: %{}

    for %{name: name} <- Fields.settings(fields),
        name not in locked,
        Map.has_key?(given, name),
        into: %{},
        do: {name, text(given[name])}
  end

  defp secret_params(params, fields) do
    given = if is_map(params["secrets"]), do: params["secrets"], else: %{}

    for name <- Fields.secret_names(fields),
        value = given[name],
        is_binary(value),
        into: %{},
        do: {name, value}
  end

  # The stored settings with the form's editable ones over them. An adapter
  # that isn't installed has no fields to edit: its settings stay as stored.
  defp put_settings(attrs, _row, [], _given), do: attrs

  defp put_settings(attrs, row, _fields, given) do
    settings = Map.merge(Map.new(row.settings || %{}, fn {k, v} -> {to_string(k), v} end), given)
    Map.put(attrs, :settings, settings)
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  ## Reading

  defp load(socket) do
    rows =
      case read_destinations(socket.assigns.current_user) do
        {:ok, rows} -> rows
        {:error, _error} -> :unreadable
      end

    socket
    |> assign(:destinations, rows)
    |> assign(:env, Destination.env_destination())
    |> assign(:adapters, offered_adapters())
    |> assign(:local_available?, Local.available?())
  end

  defp read_destinations(user) do
    query = Ash.Query.sort(DestinationConfig, position: :asc, inserted_at: :asc, id: :asc)
    Backups.list_backup_destinations(query: query, actor: user)
  end

  # The adapters a new destination may use: every installed one, Local only
  # where `BACKUP_LOCAL_DESTINATION_ROOTS` names somewhere it may write, and
  # none whose `fields/0` is broken.
  defp offered_adapters do
    for module <- Destination.registry(),
        {:ok, kind} <- [Destination.kind_of(module)],
        kind != Local.kind() or Local.available?(),
        {:ok, fields} <- [Fields.of(module)] do
      %{kind: kind, label: adapter_label(module, kind), fields: fields}
    end
  end

  defp fields_of(kind) do
    with {:ok, module} <- Destination.adapter(kind),
         {:ok, fields} <- Fields.of(module) do
      fields
    else
      _ -> []
    end
  end

  # `label/0` is plugin code: one that raises or answers no text is its kind.
  defp adapter_label(module, kind) do
    case module.label() do
      label when is_binary(label) and label != "" -> label
      _ -> kind
    end
  rescue
    _error -> kind
  end

  defp kind_label(kind) do
    case Destination.adapter(kind) do
      {:ok, module} -> adapter_label(module, kind)
      {:error, :not_installed} -> gettext("%{kind} (not installed)", kind: kind)
    end
  end

  defp gone_flash, do: gettext("That destination no longer exists.")

  defp write_error(%Ash.Error.Forbidden{}),
    do: gettext("Only a platform admin can change backup destinations.")

  defp write_error(%Ash.Error.Invalid{errors: errors}) do
    case Enum.flat_map(errors, &form_errors/1) do
      [{_field, message, vars} | _] -> translate_error({message, vars})
      [] -> gettext("Couldn't change the backup destination.")
    end
  end

  defp write_error(_error), do: gettext("Couldn't change the backup destination.")

  ## Display helpers

  defp field_label(name), do: Phoenix.Naming.humanize(name)

  defp field_id(editing, name), do: "destination-#{form_key(editing)}-#{name}"

  defp form_key(:new), do: "new"
  defp form_key(id), do: id

  defp setting_value(params, name) do
    case params["settings"] do
      %{} = settings -> Map.get(settings, name)
      _ -> nil
    end
  end

  # Where a stored destination of one of Kiln's own kinds writes, from its
  # settings (never a secret); nothing for a plugin's, whose settings mean
  # nothing here.
  defp location_text(%DestinationConfig{kind: "rclone", settings: settings}),
    do: "#{settings["remote_name"]}:#{settings["path"]}"

  defp location_text(%DestinationConfig{kind: "local", settings: settings}),
    do: settings["path"]

  defp location_text(%DestinationConfig{kind: "s3"} = row),
    do: S3.describe(%Kiln.BackupDestination.Config{kind: "s3", settings: row.settings || %{}})

  defp location_text(_row), do: nil

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp delete_confirm(%DestinationConfig{name: name}),
    do:
      gettext(
        "Delete the destination %{name}? Backups stop being sent to it; the files already there stay, and are no longer pruned.",
        name: name
      )

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        if(is_list(assigns.destinations), do: assigns.destinations, else: [])
      )

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:backups}
    >
      <div class="mx-auto max-w-3xl space-y-6 p-4 sm:p-6">
        <.tabs active={:destinations} />

        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold">{gettext("Backup destinations")}</h1>
            <p class="mt-1 text-sm text-base-content/70">
              {gettext(
                "Where in-app backups are copied after they finish, one destination after another. Cron backups (scripts/backup.sh) copy only to BACKUP_RCLONE_REMOTE."
              )}
            </p>
          </div>
          <button
            :if={is_nil(@editing) and not @picking?}
            id="destination-new"
            type="button"
            phx-click="new"
            class="btn btn-primary"
          >
            <.icon name="hero-plus" class="mr-1 size-4" />
            {gettext("Add a destination")}
          </button>
        </div>

        <section
          :if={@picking?}
          id="destination-picker"
          class="rounded-lg border border-base-content/10 p-4 text-sm"
        >
          <h2 class="text-base font-semibold">{gettext("What kind of destination?")}</h2>
          <div class="mt-3 flex flex-wrap gap-2">
            <button
              :for={adapter <- @adapters}
              id={"destination-kind-#{adapter.kind}"}
              type="button"
              phx-click="pick"
              phx-value-kind={adapter.kind}
              class="btn btn-default transition-colors hover:border-primary/40"
            >
              {adapter.label}
            </button>
            <button type="button" phx-click="cancel" class="btn btn-ghost">
              {gettext("Cancel")}
            </button>
          </div>
          <p
            :if={not @local_available?}
            id="destination-local-hint"
            class="mt-3 text-xs text-base-content/70"
          >
            {gettext(
              "A directory on this server can be added once BACKUP_LOCAL_DESTINATION_ROOTS lists where it may write."
            )}
          </p>
        </section>

        <.destination_form
          :if={@form}
          form={@form}
          editing={@editing}
          kind={@kind}
          fields={@fields}
          locked={@locked}
          params={@params}
          field_errors={@field_errors}
          form_errors={@form_errors}
        />

        <section id="backup-destinations" class="rounded-lg border border-base-content/10 p-4 text-sm">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
            {gettext("Destinations")}
          </h2>

          <p :if={@destinations == :unreadable} class="mt-2 text-warning-ink">
            {gettext("Couldn't load the backup destinations.")}
          </p>

          <p
            :if={is_nil(@env) and @destinations == []}
            id="backup-destinations-empty"
            class="mt-2 text-warning-ink"
          >
            {gettext(
              "No off-site destination: backups stay on this server only. A copy somewhere else is what lets you recover when this server is lost."
            )}
          </p>

          <ul class="mt-3 divide-y divide-base-content/10">
            <li :if={@env} id="backup-destination-env" class="space-y-1.5 py-3">
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <span class="font-mono text-xs">{@env["label"]}</span>
                <.badge variant="info">{kind_label(@env["kind"])}</.badge>
                <.badge variant="outline" class="whitespace-normal">
                  <span data-role="source">
                    {gettext("From BACKUP_RCLONE_REMOTE — change it in the server's environment")}
                  </span>
                </.badge>
              </div>
              <p class="text-xs text-base-content/70">
                {gettext(
                  "Every backup is sent here first, by in-app backups and cron alike. The app never prunes it."
                )}
              </p>
            </li>

            <.destination_row
              :for={{row, index} <- Enum.with_index(@rows)}
              row={row}
              first?={index == 0}
              last?={index == length(@rows) - 1}
              testing?={MapSet.member?(@testing, row.id)}
              form_open?={@editing != nil}
              user={@current_user}
            />
          </ul>

          <p class="mt-3 text-xs text-base-content/70">
            {gettext(
              "At most %{max} destinations can be enabled. Each backup goes to every enabled one, in this order; one that fails doesn't stop the others, and the backup then reads as partly off-site.",
              max: DestinationConfig.max_enabled()
            )}
          </p>
        </section>
      </div>
    </Layouts.console>
    """
  end

  attr :row, DestinationConfig, required: true
  attr :first?, :boolean, required: true
  attr :last?, :boolean, required: true
  attr :testing?, :boolean, required: true
  attr :form_open?, :boolean, required: true
  attr :user, :any, required: true

  defp destination_row(assigns) do
    assigns =
      assigns
      |> assign(:location, location_text(assigns.row))
      |> assign(
        :prunes?,
        assigns.row.prune and Destination.supports?(assigns.row.kind, [:list, :delete])
      )
      |> assign(:can_update?, Backups.can_update_backup_destination?(assigns.user, assigns.row))
      |> assign(:can_destroy?, Backups.can_destroy_backup_destination?(assigns.user, assigns.row))

    ~H"""
    <li id={"backup-destination-#{@row.id}"} class="space-y-1.5 py-3">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span class="font-medium" data-role="name">{@row.name}</span>
        <.badge variant="info">{kind_label(@row.kind)}</.badge>
        <.badge :if={not @row.enabled} variant="neutral">
          <span data-role="disabled">{gettext("Disabled")}</span>
        </.badge>
        <.badge :if={@prunes?} variant="outline">{gettext("Prunes its old backups")}</.badge>
      </div>

      <p :if={@location} data-role="location" class="font-mono text-xs text-base-content/70">
        {@location}
      </p>

      <p data-role="last-test" class="text-xs">
        <span :if={is_nil(@row.last_tested_at)} class="text-base-content/70">
          {gettext("Not tested yet")}
        </span>
        <span :if={@row.last_tested_at && @row.last_test_ok} class="text-success-ink">
          {gettext("Last test passed %{at} on %{node}",
            at: stamp(@row.last_tested_at),
            node: @row.last_test_node || "—"
          )}
        </span>
        <span :if={@row.last_tested_at && not @row.last_test_ok} class="text-error-ink">
          {gettext("Last test failed %{at} on %{node}: %{error}",
            at: stamp(@row.last_tested_at),
            node: @row.last_test_node || "—",
            error: @row.last_test_error || "—"
          )}
        </span>
      </p>

      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click="test"
          phx-value-id={@row.id}
          data-role="test"
          disabled={@testing?}
          aria-busy={@testing? && "true"}
          class="btn btn-sm btn-default"
        >
          <.icon
            name="hero-arrow-path"
            class={["mr-1 size-4", @testing? && "animate-spin motion-reduce:animate-none"]}
          />
          {if @testing?, do: gettext("Testing…"), else: gettext("Test")}
        </button>
        <button
          :if={@can_update? and not @form_open?}
          type="button"
          phx-click="edit"
          phx-value-id={@row.id}
          data-role="edit"
          class="btn btn-sm btn-ghost"
        >
          <.icon name="hero-pencil-square" class="mr-1 size-4" />
          {gettext("Edit")}
        </button>
        <button
          :if={@can_update?}
          type="button"
          phx-click="toggle"
          phx-value-id={@row.id}
          phx-disable-with={gettext("Saving…")}
          data-role="toggle"
          class="btn btn-sm btn-ghost"
        >
          {if @row.enabled, do: gettext("Disable"), else: gettext("Enable")}
        </button>
        <button
          :if={@can_update? and not @first?}
          type="button"
          phx-click="move"
          phx-value-id={@row.id}
          phx-value-dir="up"
          data-role="up"
          aria-label={gettext("Move %{name} up", name: @row.name)}
          class="btn btn-sm btn-ghost"
        >
          <.icon name="hero-arrow-up" class="size-4" />
        </button>
        <button
          :if={@can_update? and not @last?}
          type="button"
          phx-click="move"
          phx-value-id={@row.id}
          phx-value-dir="down"
          data-role="down"
          aria-label={gettext("Move %{name} down", name: @row.name)}
          class="btn btn-sm btn-ghost"
        >
          <.icon name="hero-arrow-down" class="size-4" />
        </button>
        <button
          :if={@can_destroy?}
          type="button"
          phx-click="delete"
          phx-value-id={@row.id}
          data-role="delete"
          data-confirm={delete_confirm(@row)}
          class="btn btn-sm btn-danger ml-auto"
        >
          <.icon name="hero-trash" class="mr-1 size-4" />
          {gettext("Delete")}
        </button>
      </div>
    </li>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :editing, :any, required: true
  attr :kind, :string, required: true
  attr :fields, :list, required: true
  attr :locked, :list, required: true
  attr :params, :map, required: true
  attr :field_errors, :map, required: true
  attr :form_errors, :list, required: true

  defp destination_form(assigns) do
    ~H"""
    <section id="destination-form-panel" class="rounded-lg border border-base-content/10 p-4 text-sm">
      <h2 class="text-base font-semibold">
        {if @editing == :new,
          do: gettext("Add a destination: %{kind}", kind: kind_label(@kind)),
          else: gettext("Edit destination: %{kind}", kind: kind_label(@kind))}
      </h2>

      <div
        :if={@form_errors != []}
        id="destination-form-errors"
        role="alert"
        class="mt-3 rounded border border-error/30 bg-error/5 p-3 text-xs text-error-ink"
      >
        <p :for={message <- @form_errors}>{message}</p>
      </div>

      <.form
        for={@form}
        id="destination-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-3 space-y-3"
      >
        <.input
          name="destination[name]"
          id={field_id(@editing, "name")}
          value={@params["name"]}
          type="text"
          label={gettext("Name")}
          required
          maxlength="80"
          errors={Map.get(@field_errors, "name", [])}
        />

        <%= for field <- @fields do %>
          <%= if field.type == :secret do %>
            <%!-- Never filled in by the server; `phx-update="ignore"` keeps
                  what the admin typed through a re-render (see moduledoc). --%>
            <div id={"#{field_id(@editing, field.name)}-wrap"} phx-update="ignore">
              <.input
                type="password"
                name={"destination[secrets][#{field.name}]"}
                id={field_id(@editing, field.name)}
                value=""
                autocomplete="new-password"
                label={field_label(field.name)}
                required={field.required? and @editing == :new}
                hint={secret_hint(field, @editing)}
              />
            </div>
            <.field_error_list
              id={"#{field_id(@editing, field.name)}-errors"}
              errors={Map.get(@field_errors, field.name, [])}
            />
          <% else %>
            <.input
              :if={field.type == :boolean}
              type="checkbox"
              name={"destination[settings][#{field.name}]"}
              id={field_id(@editing, field.name)}
              value={setting_value(@params, field.name)}
              label={field_label(field.name)}
              errors={Map.get(@field_errors, field.name, [])}
            />
            <.input
              :if={field.type in [:string, :integer]}
              type={if field.type == :integer, do: "number", else: "text"}
              name={"destination[settings][#{field.name}]"}
              id={field_id(@editing, field.name)}
              value={setting_value(@params, field.name)}
              label={field_label(field.name)}
              required={field.required?}
              readonly={field.name in @locked}
              data-locked={field.name in @locked && "true"}
              hint={setting_hint(field, @locked)}
              errors={Map.get(@field_errors, field.name, [])}
            />
          <% end %>
        <% end %>

        <.input
          type="checkbox"
          name="destination[enabled]"
          id={field_id(@editing, "enabled")}
          value={@params["enabled"]}
          label={gettext("Enabled")}
          errors={Map.get(@field_errors, "enabled", [])}
        />
        <.input
          type="checkbox"
          name="destination[prune]"
          id={field_id(@editing, "prune")}
          value={@params["prune"]}
          label={gettext("Delete its old backups (retention)")}
          errors={Map.get(@field_errors, "prune", [])}
        />
        <p class="-mt-1 text-xs text-base-content/70">
          {gettext(
            "Retention here deletes only backups this installation sent to this destination, by the same rules as on this server, and only on destinations that can list and delete."
          )}
        </p>
        <p :if={@kind == "s3"} id="destination-s3-hint" class="text-xs text-base-content/70">
          {gettext(
            "Add a lifecycle rule to the bucket that aborts incomplete multipart uploads after a few days: Kiln aborts the uploads it recorded, but not one a crash left before it could record it."
          )}
        </p>

        <div class="flex flex-wrap gap-2">
          <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Checking…")}>
            {gettext("Save destination")}
          </button>
          <button type="button" phx-click="cancel" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :errors, :list, required: true

  # A secret's errors, outside its ignored wrapper so they update.
  defp field_error_list(assigns) do
    ~H"""
    <div :if={@errors != []} id={@id} class="-mt-1">
      <p :for={message <- @errors} class="mt-1.5 flex items-center gap-2 text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-5" />
        {message}
      </p>
    </div>
    """
  end

  defp secret_hint(field, :new), do: field.help

  defp secret_hint(field, _editing) do
    keep = gettext("Leave blank to keep the stored value.")
    if field.help, do: field.help <> " " <> keep, else: keep
  end

  defp setting_hint(field, locked) do
    if field.name in locked,
      do:
        gettext(
          "Where a destination writes can't be changed. To move it, add a new destination and delete this one."
        ),
      else: field.help
  end
end
