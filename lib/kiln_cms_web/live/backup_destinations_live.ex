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
  (decision E2). Its **Test** (#2952) runs the same check as a stored Rclone
  destination's (`Backups.test_env_destination/1`); the result, scrubbed of
  the remote's credentials, is shown on the row for this page only, since
  the env destination has no row to record it on. The row says whether the
  app prunes it (`BACKUP_RCLONE_REMOTE_PRUNE`, #2950), and when that is on
  but a stored destination keeps it from running, why.

  ## The "Prunes" badge

  An enabled destination whose retention is on shows "Prunes its old
  backups" only when a pass would prune it; otherwise it shows why not. A
  disabled one shows neither: retention never runs there, and its Disabled
  badge says so. Both come from
  `KilnCMS.Backups.Retention.prune_blocker/3`, worked out once per `load/1`
  over every row, the rule retention applies before each pass (#2950).

  ## The form

  Generated from the adapter's `fields/0`. Kiln's own adapters' fields
  (Local, Rclone, S3) have translated labels (#2952, #3087); a plugin's are
  its field names, humanized. A `:secret` field is a password input that is
  never filled in: the stored value never leaves the vault column, so on
  edit a blank one keeps it. Its input is `phx-update="ignore"`, so what the admin typed
  survives a re-render without the server ever sending it back, a failed
  save included. Where a destination writes (`Destination.location_fields/1`)
  is fixed once it is stored, so those fields are read-only on edit and the
  stored values are what is saved. A Local destination is offered only when
  `BACKUP_LOCAL_DESTINATION_ROOTS` lists somewhere it may write
  (`Destination.Local.available?/0`).

  Validation runs on Save, not on every keystroke: it calls the adapter's
  `validate/1` (an `rclone listremotes` for a stored Rclone remote), which is
  no work to do per key press.

  An edit form keeps the destination as it was when it opened (`:opened`).
  A Save whose destination was changed since (renamed, enabled, disabled,
  retention, by another admin or another tab) saves nothing and says so
  (#2952); the `:update` action refuses a stale record as well, which covers
  a change landing between this page's read and its write.

  ## Other backup directories

  Retention on a destination deletes only backups that in-app backups of
  this server's backup directory sent there
  (`KilnCMS.Backups.Retention.run_on_destination/3`). Each row lists, in a
  disclosure, the other backup directories whose in-app backups reached it
  and that no running server reports (`Backups.other_backup_directories/2`,
  read in a `start_async/3` task, so a long history doesn't hold up the
  page), with the ones it adopted. Ticking one adopts it
  (`Backups.adopt_backup_directories/3`, its `:adopt_directories` action):
  this server's retention may then delete those backups too. The event
  takes the destination's id and the directory's id from the client, and
  the action checks both.

  ## An SFTP server's host key (#2222, ADR 0079)

  An SFTP destination is saved disabled and can't be enabled until a
  platform admin confirms the server's host key. Its row says whether one is
  trusted. **Check host key** reads the key the server offers
  (`Backups.scan_destination_host_key/2`, in a `start_async/3` task, one at
  a time per destination) and shows its fingerprint to compare with the
  server's own (`ssh-keygen -lf …`); or the admin pastes the fingerprint
  they expect, and the server is asked for a key with that fingerprint.
  What a check found stays **on the server**, in this page's assigns by
  destination id: **Trust this key** sends only the id, so no client can
  name a key of its choosing. Trusting writes through
  `Backups.trust_backup_destination_host_key/6`, refused as stale when
  another admin trusted a key since the check began.

  ## Test

  The **Test** button runs `Backups.test_destination/2` in a `start_async/3`
  task, one at a time per destination: a click while that destination's test
  runs does nothing. The result (redacted of the destination's secrets, and
  the node it ran on) is recorded on the row and shown there and in a flash.
  """
  use KilnCMSWeb, :live_view

  import KilnCMSWeb.BackupComponents, only: [tabs: 1]

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, DestinationConfig, Retention}
  alias KilnCMS.Backups.Destination.{Local, Rclone, S3, Sftp}
  alias KilnCMS.Backups.DestinationConfig.Fields

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backup destinations"))
       |> assign(:testing, MapSet.new())
       |> assign(:host_keys, %{})
       |> assign(:env_test, nil)
       |> assign(:other_dirs, %{})
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

  @events ~w(new pick edit cancel validate save toggle delete move test test_env adopt
              scan_host_key match_host_key trust_host_key dismiss_host_key)

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
  def handle_async({:test, :env}, result, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:noreply,
       socket
       |> update(:testing, &MapSet.delete(&1, :env))
       |> put_env_test(result)
       |> load()}
    else
      deny(socket)
    end
  end

  # The other backup directories of every row, by id: `{:ok, dirs}` or
  # `:error` for each.
  def handle_async(:other_dirs, result, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      case result do
        {:ok, by_id} when is_map(by_id) -> {:noreply, assign(socket, :other_dirs, by_id)}
        {:exit, _reason} -> {:noreply, assign(socket, :other_dirs, :error)}
      end
    else
      deny(socket)
    end
  end

  def handle_async({:host_key, id}, result, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: {:noreply, put_scan(socket, id, result)},
      else: deny(socket)
  end

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
        # An SFTP destination starts disabled: its host key is confirmed
        # after it is saved (#2222).
        enabled = if adapter.kind == Sftp.kind(), do: "false", else: "true"
        params = %{"name" => "", "enabled" => enabled, "prune" => "true", "settings" => %{}}
        {:noreply, open_form(socket, :new, adapter.kind, adapter.fields, params)}
    end
  end

  defp event("edit", %{"id" => id}, socket) when is_binary(id) do
    with_destination(socket, id, fn row ->
      {:noreply,
       socket
       |> open_form(row.id, row.kind, fields_of(row.kind), edit_params(row))
       |> assign(:opened, row)}
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
      if changed_since_opened?(socket, row),
        do: {:noreply, socket |> assign_params(params) |> assign_stale()},
        else: save_edit(socket, row, params)
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

  # The env destination's Test (#2952): single-flight, as a stored one's.
  defp event("test_env", _params, socket) do
    user = socket.assigns.current_user

    cond do
      MapSet.member?(socket.assigns.testing, :env) ->
        {:noreply, socket}

      is_nil(Destination.env_destination()) ->
        {:noreply, socket |> put_flash(:error, env_gone_flash()) |> load()}

      true ->
        {:noreply,
         socket
         |> update(:testing, &MapSet.put(&1, :env))
         |> start_async({:test, :env}, fn -> Backups.test_env_destination(actor: user) end)}
    end
  end

  # Let this server's retention delete another backup directory's backups
  # on a destination, or stop it. The directory's id is the action's to
  # check.
  defp event("adopt", %{"destination" => id, "dir" => dir, "adopt" => adopt}, socket)
       when is_binary(id) and is_binary(dir) and adopt in ["true", "false"] do
    with_destination(socket, id, fn row ->
      args = if adopt == "true", do: %{adopt: [dir]}, else: %{release: [dir]}

      case Backups.adopt_backup_directories(row, args, write_opts(socket)) do
        {:ok, _row} ->
          {:noreply, socket |> put_flash(:info, adopted_flash(adopt)) |> load()}

        {:error, error} ->
          {:noreply, socket |> put_flash(:error, adopt_error(error)) |> load()}
      end
    end)
  end

  # Single-flight per destination, as a Test (#2222).
  defp event("scan_host_key", %{"id" => id}, socket) when is_binary(id),
    do: scan_host_key(socket, id, nil)

  defp event("match_host_key", %{"destination_id" => id, "fingerprint" => fingerprint}, socket)
       when is_binary(id) and is_binary(fingerprint) do
    if String.trim(fingerprint) == "",
      do: {:noreply, socket},
      else: scan_host_key(socket, id, String.slice(fingerprint, 0, 200))
  end

  # Only the id comes from the client: the key trusted is the one this
  # page's own check found, kept here (see the moduledoc).
  defp event("trust_host_key", %{"id" => id}, socket) when is_binary(id) do
    case Map.get(socket.assigns.host_keys, id) do
      {:scanned, scanned} -> with_destination(socket, id, &trust(socket, &1, scanned))
      _nothing_checked -> {:noreply, socket}
    end
  end

  defp event("dismiss_host_key", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, update(socket, :host_keys, &Map.delete(&1, id))}

  # A mangled payload is a no-op (#764).
  defp event(_event, _params, socket), do: {:noreply, socket}

  defp adopted_flash("true"),
    do: gettext("This server now prunes that backup directory's backups there.")

  defp adopted_flash(_released),
    do: gettext("This server no longer prunes that backup directory's backups there.")

  defp scan_host_key(socket, id, fingerprint) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        if match?(:scanning, Map.get(socket.assigns.host_keys, id)),
          do: {:noreply, socket},
          else: with_destination(socket, id, &start_scan(socket, &1, fingerprint))

      :error ->
        {:noreply, put_flash(socket, :error, gone_flash())}
    end
  end

  # `scan_destination_host_key/2` reads the row again as this admin, in the
  # task, so a refusal there happens before any network I/O.
  defp start_scan(socket, row, fingerprint) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> update(:host_keys, &Map.put(&1, row.id, :scanning))
     |> start_async({:host_key, row.id}, fn ->
       {fingerprint,
        Backups.scan_destination_host_key(row.id, actor: user, fingerprint: fingerprint)}
     end)}
  end

  defp put_scan(socket, id, {:ok, {expected, {:ok, scanned}}}) do
    how = if expected, do: :entered, else: :scanned
    update(socket, :host_keys, &Map.put(&1, id, {:scanned, Map.put(scanned, :how, how)}))
  end

  defp put_scan(socket, id, {:ok, {_expected, {:error, reason}}}) do
    update(socket, :host_keys, &Map.put(&1, id, {:failed, scan_error(reason)}))
  end

  defp put_scan(socket, id, {:exit, _reason}) do
    update(
      socket,
      :host_keys,
      &Map.put(&1, id, {:failed, gettext("The check didn't finish. Try again.")})
    )
  end

  defp scan_error(:no_match),
    do: gettext("The server presented no key with that fingerprint. Nothing was trusted.")

  defp scan_error(:not_found), do: gone_flash()
  defp scan_error(%Ash.Error.Forbidden{} = error), do: write_error(error)
  defp scan_error(reason), do: Destination.format_reason(reason)

  defp trust(socket, row, scanned) do
    result =
      Backups.trust_backup_destination_host_key(
        row,
        scanned.algorithm,
        scanned.fingerprint,
        scanned.how,
        %{previous_fingerprint: scanned.previous_fingerprint, scanned_for: scanned.scanned_for},
        write_opts(socket)
      )

    case result do
      {:ok, _row} ->
        {:noreply,
         socket
         |> update(:host_keys, &Map.delete(&1, row.id))
         |> put_flash(:info, gettext("Host key trusted. The destination can be enabled now."))
         |> load()}

      {:error, error} ->
        {:noreply,
         socket
         |> update(:host_keys, &Map.delete(&1, row.id))
         |> put_flash(:error, trust_error(error))
         |> load()}
    end
  end

  defp trust_error(%Ash.Error.Invalid{} = error) do
    if stale?(error),
      do:
        gettext(
          "Another admin trusted a host key for this destination meanwhile. Nothing was saved; check it again."
        ),
      else: write_error(error)
  end

  defp trust_error(error), do: write_error(error)

  # The edit form's Save, of `row` as it is stored now. The form's own
  # `locked` fields are never read: where a destination writes is the
  # stored value.
  defp save_edit(socket, row, params) do
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
  end

  # Whether the destination was saved since the edit form opened (#2952):
  # its `updated_at` is the version, which a Test doesn't move.
  defp changed_since_opened?(%{assigns: %{opened: %DestinationConfig{} = opened}}, row),
    do: DateTime.compare(opened.updated_at, row.updated_at) != :eq

  defp changed_since_opened?(_socket, _row), do: false

  defp assign_stale(socket) do
    socket
    |> assign(:field_errors, %{})
    |> assign(:form_errors, [stale_message()])
  end

  defp stale_message,
    do:
      gettext(
        "This destination was changed since you opened it, so nothing was saved. Cancel, then edit it again to see the change."
      )

  defp stale?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

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

  # The env destination's Test result: on its row for this page, and in a
  # flash. Never the remote's credentials: the label is redacted, and the
  # error was scrubbed of them (`Backups.test_env_destination/1`).
  defp put_env_test(socket, {:ok, {:ok, %{ok: true} = result}}) do
    socket
    |> assign(:env_test, result)
    |> put_flash(
      :info,
      gettext("%{name}: the test passed (on %{node}).", name: result.label, node: result.node)
    )
  end

  defp put_env_test(socket, {:ok, {:ok, %{} = result}}) do
    socket
    |> assign(:env_test, result)
    |> put_flash(
      :error,
      gettext("%{name}: the test failed (on %{node}): %{error}",
        name: result.label,
        node: result.node,
        error: result.error || "—"
      )
    )
  end

  defp put_env_test(socket, {:ok, {:error, :not_set}}),
    do: socket |> assign(:env_test, nil) |> put_flash(:error, env_gone_flash())

  defp put_env_test(socket, {:ok, {:error, error}}),
    do: put_flash(socket, :error, write_error(error))

  defp put_env_test(socket, {:exit, _reason}),
    do: put_flash(socket, :error, gettext("The test didn't finish. Try again."))

  defp env_gone_flash,
    do: gettext("BACKUP_RCLONE_REMOTE is no longer set on this server.")

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

  defp saved(socket, {:error, %Ash.Error.Invalid{} = error}, _message) do
    if stale?(error),
      do: {:noreply, assign_stale(socket)},
      else: {:noreply, assign_errors(socket, error)}
  end

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
        case Backups.reorder_backup_destination(row, %{position: index}, write_opts(socket)) do
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
    |> assign(:opened, nil)
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

    env = Destination.env_destination()
    env_location = Destination.env_location()

    socket
    |> assign(:destinations, rows)
    |> assign(:env, env)
    |> assign(:blockers, prune_blockers(rows, env_location))
    |> assign(:env_prune, env_prune(env, rows, env_location))
    |> assign(
      :can_test_env?,
      Backups.can_create_backup_destination?(socket.assigns.current_user, %{})
    )
    |> assign(:adapters, offered_adapters())
    |> assign(:local_available?, Local.available?())
    |> load_other_dirs(rows)
  end

  # Read in a task (see the moduledoc), on the connected page only.
  defp load_other_dirs(socket, rows) when is_list(rows) do
    if connected?(socket) do
      user = socket.assigns.current_user

      start_async(socket, :other_dirs, fn ->
        Map.new(rows, &{&1.id, Backups.other_backup_directories(&1, actor: user)})
      end)
    else
      socket
    end
  end

  defp load_other_dirs(socket, :unreadable), do: socket

  # Why each stored destination whose `prune` is on would not be pruned, by
  # id (#2950): the rule retention applies before every pass
  # (`Retention.prune_blocker/3`), so the "Prunes" badge shows only where a
  # pass would prune.
  defp prune_blockers(rows, env_location) when is_list(rows) do
    Map.new(rows, fn row ->
      config = %Config{id: row.id, key: "dest:" <> row.id, kind: row.kind, settings: row.settings}
      {row.id, Retention.prune_blocker(config, rows, env_location)}
    end)
  end

  defp prune_blockers(:unreadable, _env_location), do: %{}

  # The env destination's pruning (#2950): `:off` unless
  # BACKUP_RCLONE_REMOTE_PRUNE is on, then `:on`, or `{:blocked, reason}` by
  # the same rule retention applies. Rows that can't be read block it, as
  # they do the pass.
  defp env_prune(nil, _rows, _env_location), do: :off

  defp env_prune(_env, rows, env_location) do
    cond do
      not Backups.rclone_remote_prune?() -> :off
      rows == :unreadable -> {:blocked, :unreadable}
      reason = Retention.prune_blocker(:env, rows, env_location) -> {:blocked, reason}
      true -> :on
    end
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

  defp write_error(%Ash.Error.Invalid{errors: errors} = error) do
    if stale?(error), do: stale_write_error(), else: invalid_write_error(errors)
  end

  defp write_error(_error), do: gettext("Couldn't change the backup destination.")

  defp adopt_error(%Ash.Error.Invalid{errors: errors}) do
    case Enum.flat_map(errors, &form_errors/1) do
      [{_field, message, vars} | _] ->
        gettext("Nothing was changed: %{reason}.", reason: translate_error({message, vars}))

      [] ->
        gettext("Couldn't change the backup destination.")
    end
  end

  defp adopt_error(error), do: write_error(error)

  defp stale_write_error,
    do: gettext("That destination was changed meanwhile. Nothing was saved; try again.")

  defp invalid_write_error(errors) do
    case Enum.flat_map(errors, &form_errors/1) do
      [{_field, message, vars} | _] -> translate_error({message, vars})
      [] -> gettext("Couldn't change the backup destination.")
    end
  end

  ## Display helpers

  # Kiln's own adapters' fields by a translated label (#2952), "Access key
  # ID" included, which humanizing would cut to "Access key" (#3087). A
  # plugin's field is its name, humanized, as the plugin declares it.
  defp field_label(kind, name) do
    case builtin_label(builtin_kind(kind), name) do
      nil -> Phoenix.Naming.humanize(name)
      label -> label
    end
  end

  # `kind` when Kiln's own adapter answers it, else nil.
  defp builtin_kind(kind) do
    case Destination.adapter(kind) do
      {:ok, module} when module in [Local, Rclone, S3, Sftp] -> kind
      _other -> nil
    end
  end

  defp builtin_label("local", "path"), do: gettext("Path")
  defp builtin_label("rclone", "remote_name"), do: gettext("Remote name")
  defp builtin_label("rclone", "path"), do: gettext("Path")
  defp builtin_label("s3", "endpoint"), do: gettext("Endpoint")
  defp builtin_label("s3", "region"), do: gettext("Region")
  defp builtin_label("s3", "bucket"), do: gettext("Bucket")
  defp builtin_label("s3", "prefix"), do: gettext("Prefix")
  defp builtin_label("s3", "path_style"), do: gettext("Path style")
  defp builtin_label("s3", "access_key_id"), do: gettext("Access key ID")
  defp builtin_label("s3", "secret_access_key"), do: gettext("Secret access key")
  defp builtin_label("sftp", "host"), do: gettext("Host")
  defp builtin_label("sftp", "port"), do: gettext("Port")
  defp builtin_label("sftp", "username"), do: gettext("Username")
  defp builtin_label("sftp", "path"), do: gettext("Path")
  defp builtin_label("sftp", "password"), do: gettext("Password")
  defp builtin_label("sftp", "private_key"), do: gettext("Private key")
  defp builtin_label(_kind, _name), do: nil

  # The help under a checkbox: the field's own, and for S3's Path style when
  # a private host needs it (#3087).
  defp checkbox_hint(kind, field), do: path_style_hint(builtin_kind(kind), field)

  defp path_style_hint("s3", %{name: "path_style"} = field) do
    private =
      gettext(
        "Required for a private host unless <bucket>.<host> is listed in BACKUP_S3_PRIVATE_HOSTS."
      )

    if field.help, do: field.help <> " " <> private, else: private
  end

  defp path_style_hint(_kind, field), do: field.help

  # Whether the kind's uploads resume where they stopped (#3084).
  defp resumable?(kind) when is_binary(kind),
    do: Destination.resumable?(%Kiln.BackupDestination.Config{kind: kind})

  defp resumable?(_kind), do: false

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

  defp location_text(%DestinationConfig{kind: "sftp"} = row),
    do: Sftp.describe(%Kiln.BackupDestination.Config{kind: "sftp", settings: row.settings || %{}})

  defp location_text(_row), do: nil

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  # Short: why pruning, where it is on, doesn't run (`Retention.prune_blocker/3`).
  defp blocker_text(:unsupported), do: gettext("its adapter can't list and delete")
  defp blocker_text(:env_overlap), do: gettext("it overlaps BACKUP_RCLONE_REMOTE")

  defp blocker_text(:env_overlap_unknown),
    do: gettext("it can't be compared with BACKUP_RCLONE_REMOTE")

  defp blocker_text(:destination_overlap), do: gettext("it overlaps another destination")

  defp blocker_text(:destination_overlap_possible),
    do:
      gettext(
        "another S3 destination uses a bucket of the same name; the app can't tell whether it is the same store"
      )

  defp blocker_text(:destination_unknown),
    do: gettext("a destination's location can't be told")

  defp blocker_text(:destination_s3),
    do: gettext("an S3 destination can't be compared with it")

  defp blocker_text(:destination_sftp),
    do: gettext("an SFTP destination can't be compared with it")

  defp blocker_text(:destination_overlap_possible_sftp),
    do:
      gettext(
        "another SFTP destination uses a folder inside or around this one's; the app can't tell whether it is the same server"
      )

  defp blocker_text(:unreadable), do: gettext("the destinations couldn't be read")
  defp blocker_text(_other), do: gettext("it can't be pruned")

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
                <.badge :if={@env_prune == :on} variant="outline">
                  <span data-role="prunes">{gettext("Prunes its old backups")}</span>
                </.badge>
              </div>
              <p class="text-xs text-base-content/70">
                {gettext("Every backup is sent here first, by in-app backups and cron alike.")}
              </p>
              <p data-role="env-prune" class="text-xs text-base-content/70">
                <%= case @env_prune do %>
                  <% :off -> %>
                    {gettext(
                      "The app doesn't prune it: BACKUP_RCLONE_REMOTE_PRUNE is off. Cron never prunes it."
                    )}
                  <% :on -> %>
                    {gettext(
                      "In-app backups delete the old backups they sent here, by the same rules as on this server (BACKUP_RCLONE_REMOTE_PRUNE). Cron never prunes it."
                    )}
                  <% {:blocked, reason} -> %>
                    <span data-role="prune-blocked" class="text-warning-ink">
                      {gettext(
                        "BACKUP_RCLONE_REMOTE_PRUNE is on, but nothing is pruned here: %{reason}",
                        reason: blocker_text(reason)
                      )}
                    </span>
                <% end %>
              </p>
              <p :if={@env_test} data-role="last-test" class="text-xs">
                <span :if={@env_test.ok} class="text-success-ink">
                  {gettext("Last test passed %{at} on %{node}",
                    at: stamp(@env_test.at),
                    node: @env_test.node
                  )}
                </span>
                <span :if={not @env_test.ok} class="text-error-ink">
                  {gettext("Last test failed %{at} on %{node}: %{error}",
                    at: stamp(@env_test.at),
                    node: @env_test.node,
                    error: @env_test.error || "—"
                  )}
                </span>
              </p>
              <div :if={@can_test_env?} class="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  phx-click="test_env"
                  data-role="test"
                  disabled={MapSet.member?(@testing, :env)}
                  aria-busy={MapSet.member?(@testing, :env) && "true"}
                  class="btn btn-sm btn-default"
                >
                  <.icon
                    name="hero-arrow-path"
                    class={[
                      "mr-1 size-4",
                      MapSet.member?(@testing, :env) && "animate-spin motion-reduce:animate-none"
                    ]}
                  />
                  {if MapSet.member?(@testing, :env),
                    do: gettext("Testing…"),
                    else: gettext("Test")}
                </button>
              </div>
            </li>

            <.destination_row
              :for={{row, index} <- Enum.with_index(@rows)}
              row={row}
              other_dirs={other_dirs_of(@other_dirs, row.id)}
              first?={index == 0}
              last?={index == length(@rows) - 1}
              testing?={MapSet.member?(@testing, row.id)}
              host_key_state={Map.get(@host_keys, row.id)}
              blocker={Map.get(@blockers, row.id)}
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

  attr :blocker, :atom,
    default: nil,
    doc: "why its pruning can't run (`Retention.prune_blocker/3`)"

  attr :form_open?, :boolean, required: true
  attr :user, :any, required: true

  attr :other_dirs, :any,
    default: nil,
    doc:
      "`{:ok, dirs}`, `:error`, or nil while they are read (`Backups.other_backup_directories/2`)"

  attr :host_key_state, :any,
    default: nil,
    doc: "an SFTP row's host key check: `:scanning`, `{:scanned, key}` or `{:failed, message}`"

  defp destination_row(assigns) do
    assigns =
      assigns
      |> assign(:location, location_text(assigns.row))
      |> assign(:directories, directories(assigns.other_dirs, assigns.row))
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
        <.badge :if={@row.enabled and @row.prune and is_nil(@blocker)} variant="outline">
          <span data-role="prunes">{gettext("Prunes its old backups")}</span>
        </.badge>
        <.badge
          :if={@row.enabled and @row.prune and @blocker}
          variant="warning"
          class="whitespace-normal"
        >
          <span data-role="prune-blocked">
            {gettext("Not pruned: %{reason}", reason: blocker_text(@blocker))}
          </span>
        </.badge>
      </div>

      <p :if={@location} data-role="location" class="font-mono text-xs text-base-content/70">
        {@location}
      </p>

      <.host_key_panel
        :if={@row.kind == "sftp"}
        row={@row}
        state={@host_key_state}
        can_trust?={@can_update?}
      />

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

      <p
        :if={@can_update? and @other_dirs == :error}
        data-role="other-dirs-error"
        class="text-xs text-warning-ink"
      >
        {gettext("Couldn't read which other backup directories sent backups here.")}
      </p>

      <details
        :if={@can_update? and @directories != []}
        id={"other-dirs-#{@row.id}"}
        data-role="other-dirs"
        phx-mounted={JS.ignore_attributes(["open"])}
        class="group rounded-md border border-base-content/10"
      >
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2 text-xs font-medium">
          <span>
            {gettext("Backups from other backup directories (%{count})",
              count: length(@directories)
            )}
          </span>
          <.icon
            name="hero-chevron-down-mini"
            class="size-4 text-base-content/70 transition-transform group-open:rotate-180"
          />
        </summary>
        <div class="space-y-3 border-t border-base-content/10 p-3 text-xs">
          <p class="text-base-content/70">
            {gettext(
              "Retention here deletes only the backups this server's backup directory sent. These came from another backup directory: another server, or this installation before it moved here."
            )}
          </p>
          <.form
            :for={dir <- @directories}
            for={%{}}
            id={"adopt-#{@row.id}-#{dir.dir_id}"}
            phx-change="adopt"
            phx-auto-recover="ignore"
            data-dir={dir.dir_id}
            class="space-y-1"
          >
            <input type="hidden" name="destination" value={@row.id} />
            <input type="hidden" name="dir" value={dir.dir_id} />
            <p class="text-base-content/70">
              <span class="font-mono" title={dir.dir_id}>{String.slice(dir.dir_id, 0, 8)}</span>
              <span :if={dir.count}>
                {ngettext(
                  "%{count} backup, the last on %{at}",
                  "%{count} backups, the last on %{at}",
                  dir.count,
                  at: stamp(dir.last_at)
                )}
              </span>
            </p>
            <.input
              type="checkbox"
              name="adopt"
              id={"adopt-#{@row.id}-#{dir.dir_id}-box"}
              value={dir.adopted?}
              label={
                gettext(
                  "Let this server prune these backups — only if that server is retired or this installation moved here."
                )
              }
            />
          </.form>
        </div>
      </details>
    </li>
    """
  end

  defp other_dirs_of(:error, _id), do: :error

  defp other_dirs_of(by_id, id) do
    case Map.get(by_id, id) do
      {:error, _error} -> :error
      ok_or_loading -> ok_or_loading
    end
  end

  # The directories a row lists: those whose backups reached it, then the
  # ones it adopted that aren't among them (a server that came back, or whose
  # runs are past the read's cap), each marked adopted or not.
  defp directories({:ok, dirs}, row), do: with_adopted(dirs, row)
  defp directories(_loading_or_error, row), do: with_adopted([], row)

  defp with_adopted(dirs, row) do
    adopted = for %{"dir_id" => id} <- row.adoptions || [], is_binary(id), do: id
    listed = Enum.map(dirs, & &1.dir_id)

    Enum.map(dirs, &Map.put(&1, :adopted?, &1.dir_id in adopted)) ++
      for id <- adopted,
          id not in listed,
          do: %{dir_id: id, count: nil, last_at: nil, adopted?: true}
  end

  attr :row, DestinationConfig, required: true
  attr :state, :any, required: true
  attr :can_trust?, :boolean, required: true

  # An SFTP row's host key (#2222): trusted or not, and the check's state.
  # The fingerprint shown is what the server offered; trusting it sends only
  # the row's id.
  defp host_key_panel(assigns) do
    ~H"""
    <div
      id={"host-key-#{@row.id}"}
      data-role="host-key"
      class="space-y-2 rounded-md border border-base-content/10 bg-base-200/40 p-3 text-xs"
    >
      <p :if={is_nil(@row.host_key)} data-role="host-key-unconfirmed" class="text-warning-ink">
        <.icon name="hero-shield-exclamation" class="mr-1 size-4 align-text-bottom" />
        {gettext("Host key not confirmed: nothing is sent to this server until it is.")}
      </p>
      <p :if={@row.host_key} data-role="host-key-trusted" class="text-base-content/80">
        <.icon name="hero-shield-check" class="mr-1 size-4 align-text-bottom text-success-ink" />
        {gettext("Trusted %{algorithm} key %{fingerprint}, since %{at}",
          algorithm: @row.host_key["algorithm"],
          fingerprint: @row.host_key["fingerprint"],
          at: trusted_at(@row.host_key["trusted_at"])
        )}
      </p>

      <%= case @state do %>
        <% {:scanned, key} -> %>
          <div data-role="host-key-scanned" class="space-y-1.5">
            <p>
              {gettext("The server offers this %{algorithm} key:", algorithm: key.algorithm)}
            </p>
            <p class="break-all font-mono text-sm" data-role="host-key-fingerprint">
              {key.fingerprint}
            </p>
            <p class="text-base-content/70">
              {gettext(
                "Compare it with the server's own, e.g. ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub run on the server. Trust it only if they match."
              )}
            </p>
            <div :if={@can_trust?} class="flex flex-wrap gap-2">
              <button
                type="button"
                phx-click="trust_host_key"
                phx-value-id={@row.id}
                phx-disable-with={gettext("Saving…")}
                data-role="trust-host-key"
                class="btn btn-sm btn-primary"
              >
                {gettext("Trust this key")}
              </button>
              <button
                type="button"
                phx-click="dismiss_host_key"
                phx-value-id={@row.id}
                class="btn btn-sm btn-ghost"
              >
                {gettext("Cancel")}
              </button>
            </div>
          </div>
        <% {:failed, message} -> %>
          <p data-role="host-key-failed" class="text-error-ink">{message}</p>
        <% _idle_or_scanning -> %>
      <% end %>

      <div :if={@can_trust? and not match?({:scanned, _}, @state)} class="space-y-2">
        <button
          type="button"
          phx-click="scan_host_key"
          phx-value-id={@row.id}
          data-role="scan-host-key"
          disabled={@state == :scanning}
          aria-busy={@state == :scanning && "true"}
          class="btn btn-sm btn-default"
        >
          <.icon
            name="hero-finger-print"
            class={["mr-1 size-4", @state == :scanning && "animate-pulse motion-reduce:animate-none"]}
          />
          {cond do
            @state == :scanning -> gettext("Checking…")
            @row.host_key -> gettext("Check again")
            true -> gettext("Check host key")
          end}
        </button>
        <form
          id={"host-key-match-#{@row.id}"}
          phx-submit="match_host_key"
          class="flex flex-wrap items-end gap-2"
        >
          <input type="hidden" name="destination_id" value={@row.id} />
          <div class="min-w-64 flex-1">
            <.input
              type="text"
              name="fingerprint"
              id={"host-key-expected-#{@row.id}"}
              value=""
              label={gettext("Or the fingerprint you expect")}
              placeholder="SHA256:…"
              autocomplete="off"
              spellcheck="false"
            />
          </div>
          <button type="submit" class="btn btn-sm btn-ghost" disabled={@state == :scanning}>
            {gettext("Look for it")}
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp trusted_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> stamp(at)
      _invalid -> iso
    end
  end

  defp trusted_at(_other), do: "—"

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
            <div
              :if={multiline_secret?(@kind, field.name)}
              id={"#{field_id(@editing, field.name)}-wrap"}
              phx-update="ignore"
            >
              <.input
                type="textarea"
                name={"destination[secrets][#{field.name}]"}
                id={field_id(@editing, field.name)}
                value=""
                rows="6"
                autocomplete="off"
                spellcheck="false"
                class="w-full rounded-md border border-base-content/20 bg-base-100 px-3 py-2 font-mono text-xs"
                label={field_label(@kind, field.name)}
                required={field.required? and @editing == :new}
                hint={secret_hint(field, @editing)}
              />
            </div>
            <div
              :if={not multiline_secret?(@kind, field.name)}
              id={"#{field_id(@editing, field.name)}-wrap"}
              phx-update="ignore"
            >
              <.input
                type="password"
                name={"destination[secrets][#{field.name}]"}
                id={field_id(@editing, field.name)}
                value=""
                autocomplete="new-password"
                label={field_label(@kind, field.name)}
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
              label={field_label(@kind, field.name)}
              errors={Map.get(@field_errors, field.name, [])}
            />
            <%!-- A checkbox shows no `hint`: its help is a line of its own. --%>
            <p
              :if={field.type == :boolean and checkbox_hint(@kind, field) != nil}
              id={"#{field_id(@editing, field.name)}-hint"}
              class="-mt-1 text-xs text-base-content/70"
            >
              {checkbox_hint(@kind, field)}
            </p>
            <.input
              :if={field.type in [:string, :integer]}
              type={if field.type == :integer, do: "number", else: "text"}
              name={"destination[settings][#{field.name}]"}
              id={field_id(@editing, field.name)}
              value={setting_value(@params, field.name)}
              label={field_label(@kind, field.name)}
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
            "Retention here deletes only backups that in-app backups of this server's backup directory sent to this destination, by the same rules as on this server, and only on destinations that can list and delete."
          )}
        </p>
        <p :if={resumable?(@kind)} id="destination-resume-hint" class="text-xs text-base-content/70">
          {gettext("Uploads resume after an interruption.")}
        </p>
        <p :if={@kind == "sftp"} id="destination-sftp-hint" class="text-xs text-base-content/70">
          {gettext(
            "An SFTP destination stays disabled until you confirm its host key, from its row once it is saved."
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

  # A pasted private key spans lines (#2222): Kiln's own SFTP field only,
  # so no plugin's form changes.
  defp multiline_secret?(kind, name), do: builtin_kind(kind) == "sftp" and name == "private_key"

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
