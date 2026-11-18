defmodule KilnCMSWeb.BackupLive do
  @moduledoc """
  The backup panel (`/editor/backups`, #484): when the last backup ran, what
  it produced, whether it verified — and a button to take one now.

  **Platform**-admin only, and the distinction is the point (#1160). The route
  carries `:live_admin_required`, which is an *effective per-org* admin tier
  (#419) — but a backup is a `pg_dump` of the whole instance plus a media
  archive, covering every tenant. A per-org admin is the wrong question to ask
  about an instance-wide action, so `mount/3` asks the global one instead, the
  same gate `KilnCMSWeb.SystemLive` uses for a cache flush and for the same
  stated reason.

  `handle_event/3` asks again rather than trusting the mount: a mount guard is
  evaluated once, so an admin whose role is revoked mid-session would otherwise
  keep triggering full-instance backups for as long as the socket lived. Since
  #2218 the requests also carry the admin as the actor (`Backups.request/2`,
  `Backups.cancel_run/2`), so the policies decide as well.

  The artifact list names the database dump; an editor has no reason to see it
  and no action to take on it.

  ## It reports on backups it did not run

  The status comes from `<BACKUP_DIR>/manifest.json`, which cron's
  `scripts/backup.sh` writes too. That is the whole point: the canonical
  backup path is still cron, and a panel that only knew about app-triggered
  runs would show "never" on precisely the deployments that are backing up
  correctly — the most dangerous wrong answer this screen could give.

  ## One line per component (#2219)

  A backup may cover only the database or only the media, so the headline has
  a line for each component this deployment backs up (`Backups.status/0`'s
  `components`), and the tone is alarming when any of them failed or went
  stale. The artifacts and the "Last run failed" box below still show the
  manifest: the last backup, whatever it covered.

  ## History

  Below the panels, `Backups.Run` rows (#2217) list every attempt: the app's own
  and, via `Backups.Importer`, cron's. The importer (and the stale-run sweep it
  starts with) runs once per CONNECTED mount, for a platform admin only, in
  `start_async` - never on the disconnected render, where it would run twice and
  for whoever the request was. The page param is parsed as `AccountsLive` does;
  the rows themselves page with the `:history` read's own offset pagination.
  `?run=<id>` (the Schedule tab's "Last scheduled run" link, #2875) opens the
  page that holds that run (`Backups.history_page_of/3`) and marks its row.
  Whether each run's files are still on disk is computed for the visible page
  only, artifact by artifact (`Backups.Presence`, #2416).

  ## What is on disk is read off the LiveView process (#2417)

  The markers, each row's presence and which rows can be resumed come from
  this server's backup directory, which may be a network mount that hangs.
  `Backups.DiskView` reads all of it in one `start_async/3`, **one at a time**:
  a refresh while a read is running marks the page dirty, and the read that
  finishes starts one more. A result is applied only to the rows on the page
  when it lands, so a read started for another page never shows on this one.
  Until the first read lands the rows say "checking…"; one that doesn't land
  within `disk_timeout_ms` (default 5 s) turns the page to "couldn't check in
  time" and keeps what it knew. That fixes what the page shows, not the stuck
  read: a blocked `lstat` keeps a dirty I/O scheduler thread until the kernel
  answers, and no new read starts while it does, so each open tab adds at most
  one. `Backups.status/0` reads `manifest.json`, so it runs the same way, on
  mount and on every poll tick, one at a time.

  A directory that can't be listed is said to be unreadable (#2799), never
  read as "none yet". Every disk and status `handle_async/3` and timeout
  clause re-checks `platform_admin?` first, as the event handlers do; the
  import's result reaches the page only through `load_history/1`, which
  checks too.

  ## In flight, Cancel and Resume (#2218)

  A backup is a chain of step jobs behind a cluster-wide lock. While one holds
  it, a strip says which step it is on (and which media part of how many), and
  whether another backup is queued behind it; the page polls while that is so.
  "Back up now" stays enabled: a request while one runs queues, and later ones
  fold into the queued one when it is of the same kind (a fresh backup into a
  fresh one, a resume into a resume of the same stamp); a request of another
  kind is refused with a flash to try again once the queue clears (#2540).

  A running in-app backup has a **Cancel** button (on its row and on the strip)
  for a platform admin: `Backups.cancel_run/2`, as that admin, whose policy and
  guard decide (a backup that is finishing can't be canceled). Its files stay.

  A resume that holds the lock but hasn't re-opened its run yet (#2816) says
  on the strip what it waits for (the server that has the run's files, or a
  Cancel to settle) and offers only its own **Cancel**:
  `Backups.cancel_run_resume/2`, which frees the lock and notes the run, which
  keeps its status. The row's Cancel is hidden meanwhile.

  A failed, interrupted or canceled in-app run whose `.work/<stamp>/state.json`
  still exists gets a **Resume** button (platform admin only, computed for the
  visible page and bounded by its 25 rows). For about two and a half minutes
  after a Cancel the click is refused with a flash saying how long to wait
  (`{:canceled_recently, seconds}`, #2538); the button stays, and its tooltip
  says so.

  Both handlers re-check `platform_admin?`, take only the run's **id** from the
  client and look the run up themselves; Resume passes THAT run's stamp to
  `Backups.request(resume: stamp)`, which refuses anything that is not
  resumable (a succeeded or still-running run, a forged id, a run whose files
  are gone). The page never sends or trusts a stamp.

  ## Off-site destinations (#2220)

  A backup that reached only some of its off-site destinations succeeded,
  partly off-site: the headline adds a line naming how many it reached and
  which failed (`Backups.status/0`'s `offsite`), in the alarm tone, and
  "Where backups go" lists how each destination fared in the last in-app
  backup. In History, each destination is a chip under the name the run
  recorded for it (so it outlives the destination; one the run has no
  record of reads "Removed destination"), with its error as the chip's
  tooltip (and, for one failed at once by an error no retry fixes, that it
  was, #3084), and the row is badged "Partly off-site", "Not off-site" when a
  succeeded run reached no destination (#2951), or "Off-site unknown" when a
  succeeded run recorded no outcome for its destinations. The destinations
  themselves are the Destinations tab (`KilnCMSWeb.BackupDestinationsLive`).

  A partly off-site (or not off-site) run whose files are on this server's
  disk, with a destination it missed still configured, gets a **Re-send**
  button (#2949): `Backups.resend_offsite/2` with that run's stamp, read
  from the server's record of the run as Resume does. Its confirmation
  names the destinations, and says when retention there may remove an old
  run again. While it runs the row is badged "Re-sending…" and the strip
  says which destination it is on, with its own **Cancel**
  (`Backups.cancel_run_resend/2`); both handlers re-check `platform_admin?`.

  A failed destination that is no longer configured doesn't hold the alarm
  up (#2951, `Backups.status/0`): once none of the last backup's failed
  destinations remains, the off-site line goes, and with no destination
  configured at all a neutral line says new backups stay in `BACKUP_DIR`.

  ## Retention notices (#2487)

  Retention that was skipped or stopped part-way, locally or on a
  destination, deleted nothing (or not all it should have), so backups pile
  up while every run reads **Succeeded**. Each place with such a notice
  (`Backups.status/0`'s `retention`) adds a dated headline line in the alarm
  tone, with a link to the guide, until a clean pass there clears it.

  ## Held backups deleted outside the app (#2931)

  A backup a schedule keeps that the host's own prune deleted (an older
  `scripts/backup.sh` ignoring its `.hold` marker) is a warning under the
  headline (`Backups.status/0`'s `held_deleted`, shown for 8 days after it
  was found), with what to do and a link to the guide. It doesn't raise the
  alarm: the backups themselves still run.

  ## Tabs (part of #2219)

  This is the Backups tab; the in-app schedules and their forms are the
  Schedule tab (`KilnCMSWeb.BackupScheduleLive`), with the tabs and the words
  both pages use in `KilnCMSWeb.BackupComponents`. This page keeps what the
  schedules mean for it: the next scheduled backup (`Backups.status/0`'s
  `next_at`), the warnings when they can't run, and each component's alarm
  threshold.

  ## Restore is not here

  Deliberately, and the page says so rather than leaving an admin hunting for
  a button that doesn't exist. See `KilnCMS.Backups` and docs/backups.md.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, DiskView, Importer, Manifest, Markers, Resend}
  alias KilnCMS.Backups.Run.Changes.{CancelResend, CancelResume}
  alias KilnCMSWeb.Params

  import KilnCMSWeb.BackupComponents,
    only: [
      tabs: 1,
      component_label: 1,
      held_deleted_warning: 1,
      offsite_headline: 1,
      retention_lines: 1,
      run_destination_label: 2,
      run_status_label: 1,
      threshold_label: 1,
      unavailable_message: 1,
      until: 1
    ]

  # The page polls while the backup lock is held (`Backups.in_flight/0`). A
  # multi-GB backup takes a while: 1 200 polls at 3 s is an hour, and the tab
  # stops polling then rather than for as long as it stays open.
  @poll_interval_ms 3_000
  @max_polls 1_200
  @per_page 25
  @disk_timeout_ms 5_000
  @idle_disk %{state: :idle, running?: false, dirty?: false, ref: nil}

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backups"))
       |> assign(:poll_timer, nil)
       |> assign(:polls_left, @max_polls)
       |> assign(:page, 1)
       |> assign(:focus_run, nil)
       |> assign(:runs, [])
       |> assign(:run_count, 0)
       |> assign(:markers, Markers.empty())
       |> assign(:presence, %{})
       |> assign(:resumable, %{})
       |> assign(:resend_offers, %{})
       |> assign(:disk, @idle_disk)
       |> assign(:status, nil)
       |> assign(:status_loading?, false)
       |> assign(:status_failed?, false)
       |> assign(:status_ref, nil)
       |> assign(:importing?, false)
       |> load_status()
       |> load_in_flight()
       |> poll()
       |> start_import()}
    else
      # Platform-only, which the `:live_admin_required` hook (any site admin)
      # does not enforce. `push_navigate` to the access-denied page (#2143): it
      # ends the LiveView rather than rendering a refusal panel, so nothing below is reachable
      # from this socket. The handler re-checks anyway — see the moduledoc for
      # why that is not redundant.
      {:ok,
       socket
       |> push_navigate(to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  # The route's `?page=`, or `?run=<id>` (#2875): the page that holds that
  # run, which wins over `?page=`, with its row marked and brought into view.
  # Re-checked here because `handle_params/3` runs on every patch, long after
  # the mount guard was evaluated.
  @impl true
  def handle_params(params, _uri, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {page, focus, socket} = history_target(params, socket)
      socket = socket |> assign(:page, page) |> assign(:focus_run, focus) |> load_history()

      # Past the last page: land on the last one rather than an empty table.
      case last_page(socket.assigns.run_count) do
        last when page > last ->
          {:noreply, push_patch(socket, to: history_path(last))}

        _ ->
          {:noreply, reveal_run(socket, focus)}
      end
    else
      deny(socket)
    end
  end

  # The run's id is only looked up, never trusted: an id that isn't a UUID, a
  # run that doesn't exist and a read that fails all land on page 1 with a
  # flash. Paging (`history_path/1`) drops the `?run=`.
  defp history_target(%{"run" => id}, socket) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, page} <- Backups.history_page_of(id, socket.assigns.current_user, @per_page) do
      {page, id, socket}
    else
      _ -> {1, nil, put_flash(socket, :error, gettext("That backup isn't in the history."))}
    end
  end

  defp history_target(params, socket),
    do: {Params.integer(params, "page", 1, 1..100_000), nil, socket}

  # Scrolled to and focused by `revealWhenReady/1` (assets/js/app.js).
  defp reveal_run(socket, nil), do: socket
  defp reveal_run(socket, id), do: push_event(socket, "kiln:reveal", %{id: "backup-run-#{id}"})

  # A user who stopped being a platform admin mid-session (demoted, or their
  # grant expired) is sent where the mount would have sent them, rather than
  # left clicking buttons that silently do nothing (#2875). Nothing is read,
  # requested or written first.
  defp deny(socket),
    do: {:noreply, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}

  @impl true
  def handle_event("backup_now", _params, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      start_backup(socket)
    else
      deny(socket)
    end
  end

  # A pushed payload is client-chosen: a non-admin is sent away, and a mangled
  # one is a no-op (#764).
  def handle_event("page", %{"to" => to}, socket) when is_binary(to) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      page = Params.integer(%{"page" => to}, "page", 1, 1..100_000)
      {:noreply, push_patch(socket, to: history_path(page))}
    else
      deny(socket)
    end
  end

  def handle_event("page", _params, socket), do: {:noreply, socket}

  # Resume: the client names a run by id; the stamp is read from the server's
  # own record of that run, and `Backups.enqueue/1` decides whether it may be
  # resumed. A non-admin is sent away; a mangled payload or an unknown id gets
  # nothing.
  def handle_event("resume_run", %{"id" => id}, socket) when is_binary(id) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      resume_backup(socket, id)
    else
      deny(socket)
    end
  end

  def handle_event("resume_run", _params, socket), do: {:noreply, socket}

  # Cancel: as with Resume, the client names a run by id and the server reads
  # the run itself; `Backups.cancel_run/2`'s policy and guard decide.
  def handle_event("cancel_run", %{"id" => id}, socket) when is_binary(id) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      cancel_backup(socket, id)
    else
      deny(socket)
    end
  end

  def handle_event("cancel_run", _params, socket), do: {:noreply, socket}

  # Cancel a resume that holds the lock but hasn't re-opened its run (#2816):
  # as Cancel, by id, and `Backups.cancel_run_resume/2`'s policy and guard
  # decide.
  def handle_event("cancel_resume", %{"id" => id}, socket) when is_binary(id) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      cancel_resume(socket, id)
    else
      deny(socket)
    end
  end

  def handle_event("cancel_resume", _params, socket), do: {:noreply, socket}

  # Re-send a partly off-site backup to the destinations it missed (#2949):
  # as Resume, by id, and the stamp is the server's own record of that run.
  # `Backups.resend_offsite/2`'s policy and checks decide.
  def handle_event("resend_run", %{"id" => id}, socket) when is_binary(id) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      resend_backup(socket, id)
    else
      deny(socket)
    end
  end

  def handle_event("resend_run", _params, socket), do: {:noreply, socket}

  # Cancel a running re-send (#2949): by id, and `Backups.cancel_run_resend/2`'s
  # policy and guard decide.
  def handle_event("cancel_resend", %{"id" => id}, socket) when is_binary(id) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      cancel_resend(socket, id)
    else
      deny(socket)
    end
  end

  def handle_event("cancel_resend", _params, socket), do: {:noreply, socket}

  # Through the lock (#2218), as the admin, so the policy decides too: a
  # backup while one runs queues behind it, or folds into a queued fresh one;
  # a queued resume refuses it (#2540).
  defp start_backup(socket) do
    case Backups.request([trigger: "manual"], socket.assigns.current_user) do
      {:ok, %{status: :started}} ->
        {:noreply, watch(socket, gettext("Backup started — this page updates when it finishes."))}

      {:ok, %{status: status}} ->
        {:noreply, watch(socket, queued_message(status, :backup))}

      {:error, {:queue_busy, queued}} ->
        {:noreply, socket |> put_flash(:error, queue_busy_message(:backup, queued)) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, unavailable_message(reason))}
    end
  end

  defp cancel_backup(socket, id) do
    user = socket.assigns.current_user

    with {:ok, run} <- Backups.get_run(id, actor: user),
         {:ok, _canceled} <-
           Backups.cancel_run(run,
             actor: user,
             # The client the `backup_canceled` event is logged with (#2241).
             context: socket.assigns[:security_context] || %{}
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Backup canceled. Its files are kept, so it can be resumed."))
       |> refresh()}
    else
      {:error, error} ->
        {:noreply, socket |> put_flash(:error, cancel_message(error)) |> refresh()}
    end
  end

  defp cancel_message(%Ash.Error.Forbidden{}),
    do: gettext("Only a platform admin can cancel a backup.")

  defp cancel_message(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        gettext("That backup already finished.")

      Enum.any?(errors, &(Exception.message(&1) =~ "too late to cancel")) ->
        gettext("Too late to cancel: the backup is finishing.")

      true ->
        gettext("That backup can't be canceled.")
    end
  end

  defp cancel_message(_error), do: gettext("That backup can't be canceled.")

  defp cancel_resume(socket, id) do
    user = socket.assigns.current_user

    with {:ok, run} <- Backups.get_run(id, actor: user),
         {:ok, _noted} <-
           Backups.cancel_run_resume(run,
             actor: user,
             # The client the `backup_canceled` event is logged with (#2241).
             context: socket.assigns[:security_context] || %{}
           ) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("Resume canceled. The backup stays as it was, so it can be resumed later.")
       )
       |> refresh()}
    else
      {:error, error} ->
        {:noreply,
         socket |> put_flash(:error, cancel_resume_message(error, id, user)) |> refresh()}
    end
  end

  @doc false
  # Public for the test of a Cancel that loses the race with the start's
  # re-open, which a LiveView test can't time.
  def cancel_resume_message(%Ash.Error.Forbidden{}, _id, _user),
    do: gettext("Only a platform admin can cancel a backup.")

  # The resume re-opened the run first: it is a running backup now, with its
  # own Cancel. Before this read the run (`CancelResume.started/0`), or while
  # the Cancel ran: a stale record, which anything else that moved the run
  # (another Cancel, a Resume refused) also gives, so the run and the lock as
  # they are now decide.
  def cancel_resume_message(%Ash.Error.Invalid{errors: errors}, id, user) do
    cond do
      Enum.any?(errors, &(Exception.message(&1) =~ CancelResume.started())) ->
        started_message()

      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        if resume_started?(id, user),
          do: started_message(),
          else: gettext("The backup changed meanwhile. Try again.")

      true ->
        gettext("That resume can't be canceled.")
    end
  end

  def cancel_resume_message(_error, _id, _user), do: gettext("That resume can't be canceled.")

  defp started_message,
    do: gettext("The resume started meanwhile. Cancel it again to stop the backup.")

  # The run is running under the chain the lock holds, as a resume of it.
  defp resume_started?(id, user) do
    with {:ok, %{status: :running, stamp: stamp, chain_id: chain}} when is_binary(chain) <-
           Backups.get_run(id, actor: user),
         %{chain: ^chain, resume: ^stamp} <- Backups.in_flight() do
      true
    else
      _ -> false
    end
  end

  defp resend_backup(socket, id) do
    user = socket.assigns.current_user

    with {:ok, %{stamp: stamp}} <- Backups.get_run(id, actor: user),
         {:ok, %{status: :started} = started} <- Backups.resend_offsite(stamp, user) do
      {:noreply, watch(socket, resend_started_message(started))}
    else
      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, resend_message(reason)) |> refresh()}
    end
  end

  @doc false
  # Public for the test of what a started re-send says it skipped.
  def resend_started_message(started) do
    started_line = gettext("Re-send started — this page updates when it finishes.")

    skipped =
      case started[:skipped] do
        [_ | _] = names ->
          [
            gettext("Skipped, because they were removed or disabled since: %{names}.",
              names: Enum.join(names, ", ")
            )
          ]

        _none ->
          []
      end

    unreadable =
      if started[:unreadable_skipped?],
        do: [
          gettext(
            "The destinations this backup couldn't read were skipped: no stored destination it has no entry for is enabled now."
          )
        ],
        else: []

    Enum.join([started_line | skipped ++ unreadable], " ")
  end

  @doc false
  # Public for the tests of refusals a LiveView test can't easily stage.
  def resend_message(:busy),
    do:
      gettext(
        "A backup or another re-send is running. Re-send this backup once it finishes: a re-send is never queued."
      )

  def resend_message(:in_flight), do: gettext("This backup is being re-sent right now.")

  def resend_message(reason) when reason in [:pruned, :unverified, :local_files_missing],
    do:
      gettext(
        "That backup can't be re-sent: its files in the backup directory are gone, pruned or no longer verified."
      )

  def resend_message(:nothing_to_send),
    do:
      gettext(
        "Every destination this backup missed was removed or disabled since, so there is nowhere to re-send it."
      )

  def resend_message({:canceled_recently, seconds}),
    do:
      ngettext(
        "This backup's re-send was canceled moments ago. Re-send it again in %{count} second: a step on a server that lost contact with the database may still be stopping.",
        "This backup's re-send was canceled moments ago. Re-send it again in %{count} seconds: a step on a server that lost contact with the database may still be stopping.",
        seconds
      )

  def resend_message(:forbidden), do: gettext("Only a platform admin can re-send a backup.")

  def resend_message(:destinations_unreadable),
    do: gettext("Couldn't read the backup destinations. Try again in a moment.")

  def resend_message(:disabled), do: unavailable_message(:disabled)

  def resend_message(_reason), do: gettext("That backup can't be re-sent.")

  defp cancel_resend(socket, id) do
    user = socket.assigns.current_user

    with {:ok, run} <- Backups.get_run(id, actor: user),
         {:ok, _canceled} <-
           Backups.cancel_run_resend(run,
             actor: user,
             # The client the `backup_canceled` event is logged with (#2241).
             context: socket.assigns[:security_context] || %{}
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Re-send canceled. What it already sent stays recorded."))
       |> refresh()}
    else
      {:error, error} ->
        {:noreply, socket |> put_flash(:error, cancel_resend_message(error)) |> refresh()}
    end
  end

  @doc false
  # Public for the test of a late Cancel, which a LiveView test can't time.
  def cancel_resend_message(%Ash.Error.Forbidden{}),
    do: gettext("Only a platform admin can cancel a backup.")

  def cancel_resend_message(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &(Exception.message(&1) =~ CancelResend.finishing())) ->
        gettext("Too late to cancel: the re-send is finishing.")

      Enum.any?(errors, &(Exception.message(&1) =~ CancelResend.not_resending())) ->
        gettext("That backup isn't being re-sent any more.")

      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        gettext("The re-send changed meanwhile. Try again.")

      true ->
        gettext("That re-send can't be canceled.")
    end
  end

  def cancel_resend_message(_error), do: gettext("That re-send can't be canceled.")

  defp resume_backup(socket, id) do
    with {:ok, %{stamp: stamp}} <- Backups.get_run(id, actor: socket.assigns.current_user),
         {:ok, outcome} <-
           Backups.request([trigger: "manual", resume: stamp], socket.assigns.current_user) do
      case outcome do
        %{status: :started} ->
          {:noreply,
           watch(socket, gettext("Backup resumed — this page updates when it finishes."))}

        %{status: status} ->
          {:noreply, watch(socket, queued_message(status, :resume))}
      end
    else
      {:error, {:queue_busy, queued}} ->
        {:noreply, socket |> put_flash(:error, queue_busy_message(:resume, queued)) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, resume_message(reason))}
    end
  end

  # The lock is the source of truth for "is a backup running": the strip and
  # the poll follow it, on every node.
  defp watch(socket, message) do
    socket
    |> put_flash(:info, message)
    |> refresh()
  end

  # Re-read what the page shows and (re)start the poll with a fresh budget.
  defp refresh(socket) do
    socket
    |> assign(:polls_left, @max_polls)
    |> load_in_flight()
    |> load_history()
    |> poll()
  end

  defp queued_message(:queued, _asked),
    do: gettext("A backup is running; this one starts when it finishes.")

  # A request folds only into a queued one of its own kind (#2540).
  defp queued_message(:folded, :backup),
    do:
      gettext(
        "A backup is running and another is already queued; that queued backup covers this request."
      )

  defp queued_message(:folded, :resume),
    do:
      gettext(
        "A backup is running and a resume of this backup is already queued; that queued resume covers this request."
      )

  # A request of another kind than the queued one is refused, not folded: the
  # queued one would not do its work (#2540). Nothing was queued.
  defp queue_busy_message(:backup, {:resume, stamp}),
    do:
      gettext(
        "A backup is running and a resume of %{stamp} is queued after it, so this backup was not queued. Try again once the queue clears.",
        stamp: stamp
      )

  defp queue_busy_message(:resume, {:resume, stamp}),
    do:
      gettext(
        "A backup is running and a resume of %{stamp} is queued after it, so this resume was not queued. Try again once the queue clears.",
        stamp: stamp
      )

  defp queue_busy_message(:resume, :backup),
    do:
      gettext(
        "A backup is running and a new backup is queued after it, so this resume was not queued. Try again once the queue clears."
      )

  defp resume_message(:in_flight),
    do: gettext("That backup is running right now.")

  defp resume_message({:not_resumable, _status}),
    do:
      gettext("That backup can't be resumed: only a failed, interrupted or canceled backup can.")

  # #2538: the Cancel hasn't settled yet. The button stays; the click says how
  # long to wait.
  defp resume_message({:canceled_recently, seconds}),
    do:
      ngettext(
        "That backup was canceled moments ago. Resume it again in %{count} second: a step on a server that lost contact with the database may still be stopping.",
        "That backup was canceled moments ago. Resume it again in %{count} seconds: a step on a server that lost contact with the database may still be stopping.",
        seconds
      )

  defp resume_message(reason) when reason in [:no_state, :no_such_run],
    do: gettext("That backup can't be resumed: the files it had written are gone.")

  defp resume_message(reason)
       when reason in [:disabled, :no_database_url, :no_pg_dump, :no_pg_restore],
       do: unavailable_message(reason)

  defp resume_message(_reason), do: gettext("That backup can't be resumed.")

  # One tick: the panel, the strip and the history follow the backup (the new
  # run appears as `running`, then settles, without a reload). Polling stops
  # when the lock is free, or after `@max_polls`.
  @impl true
  def handle_info(:refresh, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      socket =
        socket
        |> assign(:poll_timer, nil)
        |> assign(:polls_left, socket.assigns.polls_left - 1)
        |> load_status()
        |> load_in_flight()
        |> load_history()
        |> poll()

      {:noreply, socket}
    else
      {:noreply, assign(socket, :poll_timer, nil)}
    end
  end

  # A disk read that hasn't answered in time (#2417): the page says so and
  # keeps what it knew. The read itself is left to finish; no other starts
  # while it runs. A timer of an earlier read is ignored.
  def handle_info({:disk_timeout, ref}, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      case socket.assigns.disk do
        %{ref: ^ref, running?: true} = disk ->
          {:noreply,
           socket
           |> assign(:disk, %{disk | state: :timed_out})
           |> assign(:markers, unreadable_markers())}

        _settled ->
          {:noreply, socket}
      end
    else
      deny(socket)
    end
  end

  # A status read that hasn't answered in time: like the disk read, the page
  # says so (when it has no earlier status to show) and the read is left to
  # finish; no other starts while it runs. A timer of an earlier read is
  # ignored.
  def handle_info({:status_timeout, ref}, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      case socket.assigns do
        %{status_ref: ^ref, status_loading?: true, status: status} ->
          {:noreply, assign(socket, :status_failed?, is_nil(status))}

        _settled ->
          {:noreply, socket}
      end
    else
      deny(socket)
    end
  end

  # The import (and the stale sweep inside it) finished: show what it found.
  @impl true
  def handle_async(:import, {:ok, _result}, socket),
    do: {:noreply, socket |> assign(:importing?, false) |> load_history()}

  def handle_async(:import, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :importing?, false)}

  # What the backup directory holds (#2416, #2417), applied to the rows on the
  # page NOW: a read started for another page fills nothing here. A refresh
  # that came in while it ran asks for one more.
  def handle_async(:disk, {:ok, view}, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      %{disk: disk, presence: presence, resumable: resumable} = socket.assigns
      ids = Enum.map(socket.assigns.runs, fn {run, _cancelable?} -> run.id end)
      read = Map.keys(view.presence)
      fresh_resumable = Map.new(read, &{&1, MapSet.member?(view.resumable, &1)})

      socket =
        socket
        |> assign(:disk, %{disk | state: :ready, running?: false, dirty?: false})
        |> assign(:markers, view.markers)
        |> assign(:presence, presence |> Map.merge(view.presence) |> Map.take(ids))
        |> assign(:resumable, resumable |> Map.merge(fresh_resumable) |> Map.take(ids))

      {:noreply, if(disk.dirty?, do: start_disk_read(socket), else: socket)}
    else
      deny(socket)
    end
  end

  # The read crashed. Nothing is retried now, so a read that always crashes
  # can't loop; the next refresh may start one.
  def handle_async(:disk, {:exit, _reason}, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      disk = socket.assigns.disk

      {:noreply,
       socket
       |> assign(:disk, %{disk | state: :failed, running?: false, dirty?: false})
       |> assign(:markers, unreadable_markers())}
    else
      deny(socket)
    end
  end

  def handle_async(:status, {:ok, status}, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:noreply,
       socket
       |> assign(:status, status)
       |> assign(:status_loading?, false)
       |> assign(:status_failed?, false)}
    else
      deny(socket)
    end
  end

  # The last status read, if any, stays; the page says so only when it has none.
  def handle_async(:status, {:exit, _reason}, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:noreply,
       socket
       |> assign(:status_loading?, false)
       |> assign(:status_failed?, is_nil(socket.assigns.status))}
    else
      deny(socket)
    end
  end

  # CONNECTED mounts only: the disconnected render is a throwaway GET that
  # would run the scan a second time. `Importer.run/0` reconciles stale runs
  # itself, never raises, and writes as `Backups.system/0`.
  defp start_import(socket) do
    if connected?(socket),
      do:
        socket
        |> assign(:importing?, true)
        |> start_async(:import, fn -> Importer.run() end),
      else: socket
  end

  # The lock as the strip shows it, and the run to cancel from it: the one the
  # lock is writing, when it is running (a starting chain has none yet).
  #
  # A resume that holds the lock but hasn't re-opened its run (#2816) offers
  # only Cancel resume, whatever the run's status: a stale `running` run it
  # is about to re-open would otherwise get the plain Cancel, which marks the
  # run canceled and leaves the resume's lock and start job alone.
  defp load_in_flight(socket) do
    user = socket.assigns.current_user
    in_flight = Backups.in_flight(details: true)

    run =
      with %{stamp: stamp} when is_binary(stamp) <- in_flight,
           {:ok, %{origin: :app} = run} <- Backups.get_run_by_stamp(stamp, actor: user) do
        run
      else
        _ -> nil
      end

    waiting? = resume_waiting?(in_flight, run)

    socket
    |> assign(:in_flight, in_flight && Map.put(in_flight, :resume_waiting?, waiting?))
    |> assign(:in_flight_run_id, if(not waiting? and running?(run), do: run.id))
    |> assign(:in_flight_resend_run_id, resend_cancel_id(in_flight, run, user))
    |> assign(
      :in_flight_resume_run_id,
      if(waiting? and Backups.can_cancel_run_resume?(user, run), do: run.id)
    )
  end

  defp running?(%{status: :running}), do: true
  defp running?(_run), do: false

  # A re-send of `run` holds the lock (#2949): its own Cancel, until it is
  # finishing, when the policy agrees.
  defp resend_cancel_id(%{step: :resend, stamp: stamp, phase: phase}, %{stamp: stamp} = run, user)
       when phase != :finishing do
    if Backups.can_cancel_run_resend?(user, run), do: run.id
  end

  defp resend_cancel_id(_in_flight, _run, _user), do: nil

  defp resending?(%{step: :resend, stamp: stamp}, %{stamp: stamp}), do: true
  defp resending?(_in_flight, _run), do: false

  # The lock holds a resume of `run` at its start step, under a chain the run
  # hasn't moved to yet: it hasn't re-opened the run (#2816).
  defp resume_waiting?(%{step: :start, resume: stamp, chain: chain}, %{stamp: stamp} = run)
       when is_binary(stamp),
       do: run.chain_id != chain

  defp resume_waiting?(_in_flight, _run), do: false

  defp load_history(socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: read_history(socket),
      else: socket
  end

  # The rows from the database, here; what is on disk for them (the `.keep` /
  # `.good` markers of #2542, presence, Resume), in `check_disk/1`. Read with
  # the history so a poll that settles a run moves both.
  defp read_history(socket) do
    %{page: page, current_user: user} = socket.assigns

    case Backups.run_history(
           actor: user,
           page: [limit: @per_page, offset: (page - 1) * @per_page, count: true]
         ) do
      {:ok, result} ->
        socket
        |> assign(:runs, Enum.map(result.results, &{&1, cancelable?(&1, user)}))
        |> assign(:run_count, result.count || 0)
        |> assign(:resend_offers, resend_offers(result.results, user))
        |> check_disk()

      {:error, _error} ->
        socket
        |> assign(:runs, [])
        |> assign(:run_count, 0)
        |> put_flash(:error, gettext("Couldn't load the backup history."))
        |> check_disk()
    end
  end

  # Single-flight (#2417): one disk read per page at a time, so a directory
  # that hangs costs one stuck read, not one per tick. A read asked for while
  # one runs is owed, and started when that one answers.
  defp check_disk(socket) do
    cond do
      not connected?(socket) -> socket
      socket.assigns.disk.running? -> update(socket, :disk, &%{&1 | dirty?: true})
      true -> start_disk_read(socket)
    end
  end

  defp start_disk_read(socket) do
    runs = Enum.map(socket.assigns.runs, fn {run, _cancelable?} -> run end)
    {dir, reader, ref} = {backup_dir(), disk_view(), make_ref()}
    Process.send_after(self(), {:disk_timeout, ref}, disk_timeout_ms())

    socket
    |> update(:disk, &%{&1 | running?: true, dirty?: false, ref: ref})
    |> start_async(:disk, fn -> reader.read(dir, runs, DateTime.utc_now()) end)
  end

  # Neither directory is known: what a read that timed out or crashed leaves.
  defp unreadable_markers, do: %{Markers.empty() | unreadable: MapSet.new([:db, :media])}

  # `config :kiln_cms, KilnCMSWeb.BackupLive, disk_timeout_ms: ..., disk_view: ...,
  # status_reader: ...`; the readers are seams for the tests.
  defp disk_timeout_ms, do: Keyword.get(live_config(), :disk_timeout_ms, @disk_timeout_ms)
  defp disk_view, do: Keyword.get(live_config(), :disk_view, DiskView)
  defp status_reader, do: Keyword.get(live_config(), :status_reader, &Backups.status/0)
  defp live_config, do: Application.get_env(:kiln_cms, __MODULE__, [])

  # Which rows of the page offer Re-send (#2949), and to where: a run
  # `Resend.offered/1` accepts, that the policy lets this admin re-send, with
  # at least one destination it missed still configured. The destinations
  # are read once per page, as the `:backups` system actor as
  # `Backups.status/0` reads them, and only when some row needs them. A
  # read that fails offers none. Whether its files are on this server's disk
  # is the disk read's to say (`resendable?/4`).
  defp resend_offers(runs, user) do
    with [_ | _] = offered <- Enum.filter(runs, &(Resend.offered(&1) == :ok)),
         {:ok, configured} <- Destination.configured() do
      for run <- offered,
          %{targets: [_ | _] = targets} <- [Resend.targets(run, configured)],
          Backups.can_request_backup_resend?(user, run.stamp),
          into: %{},
          do: {run.id, resend_offer(run, targets)}
    else
      _none_or_unreadable -> %{}
    end
  end

  defp resend_offer(run, targets) do
    %{targets: Enum.map(targets, & &1["label"]), pruned_soon: Resend.pruned_soon(run, targets)}
  end

  # A running in-app run, and the policy agrees. Whether it is past the point
  # of no return is the action's to say when clicked.
  defp cancelable?(%{status: :running, origin: :app} = run, user),
    do: Backups.can_cancel_run?(user, run)

  defp cancelable?(_run, _user), do: false

  defp last_page(count), do: max(div(count + @per_page - 1, @per_page), 1)

  defp history_path(1), do: ~p"/editor/backups"
  defp history_path(page), do: ~p"/editor/backups?#{%{page: page}}"

  # `Backups.status/0` reads `manifest.json` (#2417): off the LiveView process,
  # one read at a time, with the disk read's timeout. The page shows a
  # placeholder until the first lands.
  defp load_status(socket) do
    if connected?(socket) and not socket.assigns.status_loading? do
      ref = make_ref()
      Process.send_after(self(), {:status_timeout, ref}, disk_timeout_ms())

      socket
      |> assign(:status_loading?, true)
      |> assign(:status_ref, ref)
      |> start_async(:status, status_reader())
    else
      socket
    end
  end

  # Polling rather than PubSub: a backup runs every few hours at most, so one
  # timer on an open admin page is cheaper than a topic, a broadcast and a
  # subscription that exist for this one screen. One timer at a time, and only
  # while the lock is held.
  defp poll(%{assigns: %{poll_timer: ref}} = socket) when is_reference(ref), do: socket

  defp poll(socket) do
    if connected?(socket) and socket.assigns.in_flight != nil and
         socket.assigns.polls_left > 0 do
      assign(socket, :poll_timer, Process.send_after(self(), :refresh, @poll_interval_ms))
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:manifest, assigns.status && assigns.status.manifest)
      |> assign(:busy?, busy?(assigns))

    ~H"""
    <%!-- `current_org` was the one console call site not passing it (#1320):
          the top bar's bell scopes its rows by tenant, so a page that omitted
          it would read this admin's notifications across every site. --%>
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:backups}
    >
      <%!-- `data-busy` is true while a background read (#2417) is still
            out: what the page shows may be about to change. --%>
      <div
        id="backup-page"
        data-busy={to_string(@busy?)}
        class="mx-auto max-w-3xl space-y-6 p-4 sm:p-6"
      >
        <.tabs active={:history} />

        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold">{gettext("Backups")}</h1>
            <p class="mt-1 text-sm text-base-content/70">
              {gettext("The database and, on local storage, your uploaded media.")}
            </p>
            <p class="mt-1 text-sm text-base-content/70">
              <.link
                id="backups-instance-log-link"
                navigate={~p"/editor/instance-security-log"}
                class="underline hover:no-underline"
              >
                {gettext("Canceled backups are recorded in the instance security log.")}
              </.link>
            </p>
            <%!-- The soonest window of any schedule that can run here
                  (`Backups.status/0`'s `next_at`); the schedules themselves
                  are on the Schedule tab. --%>
            <p
              :if={@status && @status.next_at}
              id="backup-next-scheduled"
              class="mt-1 text-sm text-base-content/70"
            >
              <.link navigate={~p"/editor/backups/schedules"} class="underline hover:no-underline">
                {gettext("Next scheduled backup: %{when}", when: until(@status.next_at))}
              </.link>
            </p>
          </div>

          <div class="flex max-w-xs flex-col items-start gap-2 sm:items-end">
            <%!-- Enabled while a backup runs: a request then queues behind it.
                  `phx-disable-with` stops a double click asking twice. --%>
            <button
              type="button"
              phx-click="backup_now"
              phx-disable-with={gettext("Requesting…")}
              disabled={@status && not @status.available?}
              title={@status && not @status.available? && unavailable_message(@status.reason)}
              aria-describedby="backup-now-help"
              class="btn btn-primary"
            >
              {gettext("Back up now")}
            </button>
            <%!-- The queue rule (#2540), in the words of the flash a refused
                  request gets, so the two never disagree. --%>
            <p id="backup-now-help" class="text-xs text-base-content/70 sm:text-right">
              {gettext(
                "A backup asked for while another runs waits for it; only one waits. A request of a different kind, or a resume of a different backup, is refused until the queue clears."
              )}
            </p>
          </div>
        </div>

        <.in_flight
          :if={@in_flight}
          in_flight={@in_flight}
          run_id={@in_flight_run_id}
          resume_run_id={@in_flight_resume_run_id}
          resend_run_id={@in_flight_resend_run_id}
        />

        <%!-- Until `Backups.status/0` answers (#2417). Neutral: nothing is
              known yet, good or bad. --%>
        <section
          :if={is_nil(@status)}
          id="backup-status-pending"
          class="rounded-lg border border-base-content/10 p-4 text-sm text-base-content/70"
        >
          <p :if={not @status_failed?}>{gettext("Reading this server's backup status…")}</p>
          <p :if={@status_failed?} class="text-warning-ink">
            {gettext("Couldn't read this server's backup status. Reload the page to try again.")}
          </p>
        </section>

        <%!-- The headline. Stale (or never) is an error tone on purpose: a
              deployment that has not been backed up is the state this whole
              page exists to make impossible to miss. --%>
        <section
          :if={@status}
          class={[
            "rounded-lg border p-4",
            if(alarming?(@status),
              do: "border-error/30 bg-error/5",
              else: "border-success/30 bg-success/5"
            )
          ]}
        >
          <div class="flex items-start gap-3">
            <.icon
              name={if alarming?(@status), do: "hero-exclamation-triangle", else: "hero-check-circle"}
              class={[
                "mt-0.5 size-5 shrink-0",
                if(alarming?(@status), do: "text-error", else: "text-success")
              ]}
            />
            <div class="min-w-0 flex-1">
              <p
                :for={component <- @status.expected}
                id={"backup-headline-#{component}"}
                class="font-medium"
              >
                <span class="text-base-content/70">{component_label(component)}:</span>
                {headline(@status.components[component])}
              </p>
              <%!-- Partly off-site (#2220): the backup succeeded, but not
                    every destination has a copy. --%>
              <p
                :if={offsite_headline(@status.offsite)}
                id="backup-headline-offsite"
                class="font-medium"
              >
                {offsite_headline(@status.offsite)}
              </p>
              <%!-- #2951: the last backup's failed destinations are all gone,
                    and nothing is configured in their place. Not an alarm:
                    the admin chose it, but new backups stay on this disk. --%>
              <p
                :if={@status.offsite.configured? == false}
                id="backup-offsite-unconfigured"
                class="mt-1 text-sm text-base-content/70"
              >
                {gettext(
                  "No off-site destination is configured now: new backups stay in BACKUP_DIR only."
                )}
              </p>
              <%!-- Retention skipped or stopped part-way (#2487): the backup
                    succeeded, but old backups are piling up. --%>
              <p
                :for={line <- retention_lines(@status)}
                id={"backup-headline-retention-#{line.id}"}
                data-role="retention-notice"
                class="font-medium"
              >
                {line.text}
              </p>
              <p :if={@status.retention != []} class="mt-1 text-sm">
                <a
                  id="backup-retention-docs"
                  href={docs_url("backups.md#when-retention-is-skipped-or-stops")}
                  target="_blank"
                  rel="noopener"
                  class="link inline-flex items-center gap-1 text-primary-ink"
                >
                  {gettext("Why retention skips")}
                  <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                </a>
              </p>
              <p
                :if={@status.manifest && @status.manifest.artifacts != []}
                class="mt-1 text-sm text-base-content/70"
              >
                {summary(@status.manifest)}
              </p>
              <p :if={is_nil(@status.manifest)} class="mt-1 text-sm text-base-content/70">
                {gettext(
                  "Nothing has written %{path} yet. Either no backup has run, or it writes somewhere else.",
                  path: Manifest.path(backup_dir())
                )}
              </p>
            </div>
          </div>
        </section>

        <%!-- Backups a schedule keeps, deleted by the host's own prune
              (#2931): the backups still run, so it is a warning, not the
              alarm. --%>
        <section
          :if={@status && @status.held_deleted != []}
          class="flex items-start gap-3 rounded-lg border border-warning/30 bg-warning/5 p-4 text-sm text-warning-ink"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
          <.held_deleted_warning id="backup-held-deleted" notices={@status.held_deleted} />
        </section>

        <%!-- A failed run keeps its own error visible. Showing the previous
              SUCCESSFUL backup instead would be true and would answer a
              question nobody asked. --%>
        <section
          :if={@manifest && @manifest.error}
          class="rounded-lg border border-error/30 bg-error/5 p-4"
        >
          <p class="text-sm font-medium text-error">{gettext("Last run failed")}</p>
          <pre class="mt-2 overflow-x-auto whitespace-pre-wrap break-words text-xs text-base-content/80">{@manifest.error}</pre>
        </section>

        <section
          :if={@manifest && @manifest.artifacts != []}
          class="rounded-lg border border-base-content/10 p-4"
        >
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {gettext("Artifacts")}
          </h2>
          <ul class="mt-3 space-y-2">
            <li
              :for={artifact <- @manifest.artifacts}
              class="flex items-center gap-3 text-sm"
            >
              <.icon
                name={if artifact.kind == "db", do: "hero-circle-stack", else: "hero-photo"}
                class="size-4 shrink-0 text-base-content/60"
              />
              <span class="min-w-0 flex-1 truncate font-mono text-xs">{artifact.path}</span>
              <span class="shrink-0 tabular-nums text-base-content/70">
                {humanize_bytes(artifact.bytes)}
              </span>
              <span
                :if={artifact.verified}
                class="shrink-0 rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-success-ink"
                title={gettext("Listed with pg_restore after writing, so it is a real backup")}
              >
                {gettext("Verified")}
              </span>
            </li>
          </ul>
        </section>

        <section class="rounded-lg border border-base-content/10 p-4 text-sm">
          <%!-- Shown whatever the off-site row says: the built-in copy already
                ships the .sha256 files, so the hint is for operators who copy
                backups off the host themselves (#2890). The "?" sits beside the
                heading, not inside it, so it doesn't join the heading's name. --%>
          <div class="flex items-center gap-1">
            <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
              {gettext("Where backups go")}
            </h2>
            <.help_tip
              id="offsite-sidecars-help"
              label={gettext("About copying backups")}
              title={gettext("Copying backups elsewhere")}
              learn_more={docs_url("backups.md#the-app-path-and-the-shell-path-share-one-format")}
            >
              {gettext(
                "If you copy backups off this host yourself, copy each backup's .sha256 files with it: without them a media backup in parts won't restore, and nothing can check the others. The built-in off-site copy already includes them."
              )}
            </.help_tip>
          </div>
          <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
            <dt class="text-base-content/60">{gettext("Directory")}</dt>
            <dd class="font-mono text-xs">{backup_dir()}</dd>
            <dt class="text-base-content/60">{gettext("Media")}</dt>
            <dd class="font-mono text-xs">
              {media_dir() || gettext("not archived — object storage is backed up by the provider")}
            </dd>
            <dt class="text-base-content/60">{gettext("Retention")}</dt>
            <dd>{ngettext("%{count} day", "%{count} days", keep_days(), count: keep_days())}</dd>
            <dt :if={@manifest && @manifest.offsite} class="text-base-content/60">
              {gettext("Off-site")}
            </dt>
            <dd :if={@manifest && @manifest.offsite} class="font-mono text-xs">
              {KilnCMS.Backups.Redact.text(@manifest.offsite)}
            </dd>
            <%!-- Each destination the last in-app backup sent to (#2220),
                  with how it fared; the destinations themselves are on the
                  Destinations tab. --%>
            <dt
              :if={@status && @status.offsite.destinations != []}
              class="text-base-content/70"
            >
              {gettext("Last in-app backup off-site")}
            </dt>
            <dd :if={@status && @status.offsite.destinations != []}>
              <ul id="backup-offsite-destinations" class="space-y-0.5 text-xs">
                <li
                  :for={d <- @status.offsite.destinations}
                  data-role="offsite-destination"
                  data-status={status_key(d.status)}
                >
                  <span class="font-mono">{run_destination_label(d.key, d.label)}</span>
                  ·
                  <span class={destination_status_class(status_key(d.status))}>{destination_status_label(
                    status_key(d.status)
                  )}</span>
                  <span :if={d.error} class="text-base-content/70">— {d.error}</span>
                </li>
              </ul>
            </dd>
            <dt
              :if={@status && @status.rclone_missing? && !(@manifest && @manifest.offsite)}
              class="text-base-content/70"
            >
              {gettext("Off-site")}
            </dt>
            <dd
              :if={@status && @status.rclone_missing?}
              id="backup-rclone-missing"
              class={[
                "text-xs text-warning-ink",
                @manifest && @manifest.offsite && "col-start-2"
              ]}
            >
              <span class="font-mono">{KilnCMS.Backups.Redact.text(rclone_remote())}</span>
              — {gettext(
                "rclone is not installed in this image, so backups taken from this page fail at the off-site copy. Install rclone in the image or unset BACKUP_RCLONE_REMOTE."
              )}
            </dd>
          </dl>

          <p class="mt-4 text-xs text-base-content/60">
            {gettext(
              "Restoring is a documented operations procedure, not a button here — see docs/backups.md. Secrets (SECRET_KEY_BASE above all) are not in these files and must be kept separately."
            )}
          </p>
        </section>

        <.schedule_summary :if={@status} status={@status} />

        <.history
          runs={@runs}
          page={@page}
          focus_run={@focus_run}
          run_count={@run_count}
          in_flight={@in_flight}
          markers={@markers}
          presence={@presence}
          resumable={@resumable}
          resend_offers={@resend_offers}
          disk={@disk}
          expected={if @status, do: @status.expected, else: Backups.expected_components()}
        />
      </div>
    </Layouts.console>
    """
  end

  attr :status, :map, required: true

  # What the schedules (part of #2219) mean for this page: whether they can
  # run here, and the alarm threshold of each component. The schedules
  # themselves are on the Schedule tab (`KilnCMSWeb.BackupScheduleLive`).
  # Everything comes from `Backups.status/0`, so the threshold shown is the one
  # the headline and the home strips judge by.
  defp schedule_summary(assigns) do
    ~H"""
    <section id="backup-schedules" class="rounded-lg border border-base-content/10 p-4 text-sm">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
        {gettext("Alarm thresholds")}
      </h2>

      <p
        :if={is_list(@status.schedules) and @status.scheduler_cron == :off}
        id="backup-schedules-off"
        class="mt-2 text-xs text-warning-ink"
      >
        {gettext("In-app schedules are turned off (KILN_BACKUP_SCHEDULER_CRON).")}
      </p>
      <p
        :if={is_list(@status.schedules) and @status.scheduler_cron == :invalid}
        id="backup-schedules-invalid"
        class="mt-2 text-xs text-warning-ink"
      >
        {gettext(
          "In-app schedules don't run: KILN_BACKUP_SCHEDULER_CRON isn't a valid cron expression."
        )}
      </p>
      <p
        :if={is_list(@status.schedules) and @status.scheduler_cron == :never_matches}
        id="backup-schedules-never"
        class="mt-2 text-xs text-warning-ink"
      >
        {gettext(
          "In-app schedules never run: KILN_BACKUP_SCHEDULER_CRON only matches a date that doesn't exist, such as 31 February."
        )}
      </p>
      <p
        :if={is_list(@status.schedules) and @status.scheduler_enabled? and not @status.available?}
        id="backup-schedules-unavailable"
        class="mt-2 text-xs text-warning-ink"
      >
        {gettext("Scheduled backups can't run here: %{reason}",
          reason: unavailable_message(@status.reason)
        )}
      </p>
      <p :if={@status.schedules == :unreadable} class="mt-2 text-xs text-warning-ink">
        {gettext("Couldn't load the backup schedules.")}
      </p>

      <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-xs">
        <%= for component <- @status.expected do %>
          <dt class="text-base-content/70">{component_label(component)}</dt>
          <dd id={"backup-threshold-#{component}"}>
            {threshold_label(@status.components[component])}
          </dd>
        <% end %>
      </dl>
    </section>
    """
  end

  attr :in_flight, :map, required: true
  attr :run_id, :string, default: nil
  attr :resume_run_id, :string, default: nil, doc: "the run of a resume waiting to start (#2816)"
  attr :resend_run_id, :string, default: nil, doc: "the run being re-sent off-site (#2949)"

  # The running backup: its step, the part of how many, the queued request.
  defp in_flight(assigns) do
    ~H"""
    <section
      id="backup-in-flight"
      class="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-lg border border-info/30 bg-info/5 p-4 text-sm"
    >
      <.icon name="hero-arrow-path" class="size-5 shrink-0 text-info motion-safe:animate-spin" />
      <div class="min-w-0 flex-1 space-y-0.5">
        <p class="font-medium">
          <span data-role="step">{step_label(@in_flight)}</span>
          <%!-- #3030: a resume waiting to start holds the lock; the guide
                says what for, and when to cancel it. --%>
          <a
            :if={@in_flight[:resume_waiting?] == true}
            href={docs_url("backups.md#cancel-a-resume-that-is-waiting-to-start")}
            target="_blank"
            rel="noopener"
            data-role="resume-why"
            class="link ml-1 inline-flex items-center gap-1 text-xs font-normal text-primary-ink"
          >
            {gettext("Why?")}
            <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            <span class="sr-only">{gettext("(opens in a new tab)")}</span>
          </a>
        </p>
        <p :if={@in_flight.stamp} class="font-mono text-xs text-base-content/70">
          {@in_flight.stamp}
        </p>
        <p :if={@in_flight.waiting} data-role="queued" class="text-xs text-base-content/70">
          {queued_label(@in_flight.waiting)}
          <span :if={is_nil(@in_flight.waiting.resume)} data-role="queued-components">
            · {components_label(@in_flight.waiting.components)}
          </span>
        </p>
      </div>
      <button
        :if={@run_id && @in_flight.phase != :finishing}
        type="button"
        phx-click="cancel_run"
        phx-value-id={@run_id}
        phx-disable-with={gettext("Canceling…")}
        data-role="cancel"
        data-confirm={cancel_confirm(@in_flight)}
        class="btn btn-sm btn-danger"
      >
        <.icon name="hero-stop-circle" class="mr-1 size-4" />
        {gettext("Cancel")}
      </button>
      <button
        :if={@resend_run_id}
        type="button"
        phx-click="cancel_resend"
        phx-value-id={@resend_run_id}
        phx-disable-with={gettext("Canceling…")}
        data-role="cancel-resend"
        data-confirm={cancel_resend_confirm(@in_flight)}
        class="btn btn-sm btn-danger"
      >
        <.icon name="hero-stop-circle" class="mr-1 size-4" />
        {gettext("Cancel")}
      </button>
      <button
        :if={@resume_run_id}
        type="button"
        phx-click="cancel_resume"
        phx-value-id={@resume_run_id}
        phx-disable-with={gettext("Canceling…")}
        data-role="cancel-resume"
        data-confirm={cancel_resume_confirm(@in_flight)}
        class="btn btn-sm btn-danger"
      >
        <.icon name="hero-stop-circle" class="mr-1 size-4" />
        {gettext("Cancel")}
      </button>
    </section>
    """
  end

  # A resume waiting to start (#2816): what for.
  defp step_label(%{resume_waiting?: true, waiting_for: :files_server}),
    do: gettext("Waiting for the server that has this backup's files")

  defp step_label(%{resume_waiting?: true, waiting_for: :cancel_settle}),
    do: gettext("Waiting for the canceled backup's step to stop")

  defp step_label(%{resume_waiting?: true}), do: gettext("Starting a resume")

  defp step_label(%{step: :archive, part: part, parts_total: total})
       when is_integer(part) and is_integer(total),
       do: gettext("Archiving media: part %{part} of %{total}", part: part, total: total)

  defp step_label(%{step: :archive, part: part}) when is_integer(part),
    do: gettext("Archiving media: part %{part}", part: part)

  # Which destination, only when there is more than one (#2220).
  defp step_label(%{
         step: :offsite,
         part: part,
         destinations_total: total,
         destination_label: name
       })
       when is_integer(part) and is_integer(total) and total > 1 and is_binary(name),
       do:
         gettext("Copying off-site (%{index} of %{total}: %{name})",
           index: part,
           total: total,
           name: name
         )

  # A re-send of a partly off-site backup (#2949), and to which destination.
  defp step_label(%{
         step: :resend,
         part: part,
         destinations_total: total,
         destination_label: name
       })
       when is_integer(part) and is_integer(total) and is_binary(name),
       do:
         gettext("Re-sending off-site (%{index} of %{total}: %{name})",
           index: part,
           total: total,
           name: name
         )

  defp step_label(%{step: :resend}), do: gettext("Re-sending off-site")

  defp step_label(%{step: step}) do
    case step do
      :dump -> gettext("Dumping the database")
      :plan -> gettext("Planning the media archive")
      :archive -> gettext("Archiving media")
      :checksum -> gettext("Checking the media parts")
      :prune -> gettext("Applying retention")
      :offsite -> gettext("Copying off-site")
      :finish -> gettext("Finishing")
      _start -> gettext("Starting a backup")
    end
  end

  defp queued_label(%{requested_at: at, folds: folds}) do
    queued =
      gettext("1 queued (requested %{at})", at: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC"))

    case folds do
      n when is_integer(n) and n > 0 ->
        queued <>
          " · " <>
          ngettext(
            "%{count} later request folded into it",
            "%{count} later requests folded into it",
            n
          )

      _ ->
        queued
    end
  end

  # A queued fresh backup's components (#2219); nil is everything this
  # deployment backs up.
  defp components_label(components) do
    Enum.map_join(components || Backups.expected_components(), " + ", &component_label/1)
  end

  defp cancel_confirm(%{waiting: nil}),
    do: gettext("Cancel this backup? Its files are kept, so it can be resumed later.")

  defp cancel_confirm(_in_flight),
    do:
      gettext(
        "Cancel this backup? Its files are kept, so it can be resumed later. A queued backup will start next."
      )

  defp cancel_resend_confirm(%{waiting: nil}),
    do: gettext("Stop this re-send? What was already sent stays recorded.")

  defp cancel_resend_confirm(_in_flight),
    do:
      gettext(
        "Stop this re-send? What was already sent stays recorded. A queued backup will start next."
      )

  defp cancel_resume_confirm(%{waiting: nil}),
    do: gettext("Cancel this resume? The backup stays as it was, so it can be resumed later.")

  defp cancel_resume_confirm(_in_flight),
    do:
      gettext(
        "Cancel this resume? The backup stays as it was, so it can be resumed later. A queued backup will start next."
      )

  attr :runs, :list, required: true
  attr :page, :integer, required: true
  attr :focus_run, :string, default: nil, doc: "the id of the run `?run=` linked to"
  attr :run_count, :integer, required: true
  attr :in_flight, :map, default: nil
  attr :markers, :map, required: true
  attr :presence, :map, required: true, doc: "run id => `Backups.Presence.t()`"
  attr :resumable, :map, required: true, doc: "run id => whether Resume is offered"

  attr :resend_offers, :map,
    default: %{},
    doc: "run id => `%{targets, pruned_soon}` where Re-send is offered (#2949)"

  attr :disk, :map, required: true, doc: "the disk read's state (#2417)"
  attr :expected, :list, required: true

  defp history(assigns) do
    assigns = assign(assigns, :last_page, last_page(assigns.run_count))

    ~H"""
    <section id="backup-history" class="rounded-lg border border-base-content/10 p-4">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
        {gettext("History")}
      </h2>

      <%!-- The last-good stamps even when the marked run is off this page of
            the history (#2542). Read from this node's directory, which may be
            one per host (#2218). --%>
      <div id="backup-last-good" class="mt-3 space-y-1 text-sm">
        <p class="font-medium">{gettext("Last-good marker (kept by backup.sh prune)")}</p>
        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
          <%= for component <- @expected do %>
            <dt class="text-base-content/70">{component_label(component)}</dt>
            <dd
              data-role="last-good"
              data-component={component}
              data-state={last_good_state(@disk, @markers, component)}
              class="font-mono text-xs"
            >
              {last_good_label(@disk, @markers, component)}
            </dd>
          <% end %>
        </dl>
        <p id="backup-markers-help" class="text-xs text-base-content/70">
          {gettext(
            "A recovery point (kiln-<stamp>.keep) keeps every file of that backup from retention. Cron keeps the backup marked last good (kiln-<stamp>.good) in each folder; the app moves the marker after every successful backup and, by default, every 15 minutes. Both are read from this server's backup directory."
          )}
        </p>
      </div>

      <%!-- One line for the disk read (#2417): checking, or why the page
            can't say what is on disk. Each replaces the other. --%>
      <p
        :if={@disk.state == :idle and @disk.running?}
        id="backup-disk-checking"
        class="mt-3 text-xs text-base-content/70"
      >
        {gettext("Checking this server's backup directory…")}
      </p>
      <p
        :if={@disk.state == :timed_out}
        id="backup-disk-timeout"
        role="status"
        class="mt-3 text-xs text-warning-ink"
      >
        {ngettext(
          "This server's backup directory didn't answer within %{count} second, so the files on disk, the markers and Resume aren't shown. Reload the page to check again.",
          "This server's backup directory didn't answer within %{count} seconds, so the files on disk, the markers and Resume aren't shown. Reload the page to check again.",
          disk_timeout_s()
        )}
      </p>
      <p
        :if={@disk.state == :failed}
        id="backup-disk-failed"
        role="status"
        class="mt-3 text-xs text-warning-ink"
      >
        {gettext(
          "Couldn't check this server's backup directory, so the files on disk, the markers and Resume aren't shown. Reload the page to check again."
        )}
      </p>

      <div
        :if={@runs == []}
        id="backup-history-empty"
        class="mt-3 space-y-1 text-sm text-base-content/70"
      >
        <p>{gettext("No backups have been recorded yet.")}</p>
        <p class="text-xs">
          {gettext(
            "Backups that cron's scripts/backup.sh makes appear here too, about ten minutes after they finish: the app waits that long so it doesn't record one still being written."
          )}
        </p>
      </div>

      <ul :if={@runs != []} class="mt-3 divide-y divide-base-content/10">
        <li
          :for={{run, cancelable?} <- @runs}
          id={"backup-run-#{run.id}"}
          aria-current={@focus_run == run.id && "true"}
          class={[
            "space-y-1.5 py-3 text-sm",
            @focus_run == run.id && "-mx-2 rounded-md bg-primary/5 px-2"
          ]}
        >
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span class="font-medium tabular-nums">
              {Calendar.strftime(run.started_at, "%Y-%m-%d %H:%M UTC")}
            </span>
            <span data-role="trigger" class="text-xs text-base-content/70">
              {trigger_label(run.trigger)}
            </span>
            <span
              data-role="status"
              class={[
                "rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase",
                status_class(run.status)
              ]}
            >
              {run_status_label(run.status)}
            </span>
            <span
              :for={component <- run.components}
              data-role="component"
              class="rounded bg-base-content/10 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-base-content/70"
            >
              {component_label(component)}
            </span>
            <span
              :if={Markers.recovery_point?(@markers, run.stamp)}
              data-role="recovery-point"
              title={gettext("Kept from retention by a kiln-<stamp>.keep marker")}
              class="rounded bg-info/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-info-ink"
            >
              {gettext("Recovery point")}
            </span>
            <span
              :for={component <- Markers.last_good_components(@markers, run.stamp)}
              data-role="last-good"
              data-component={component}
              title={gettext("Kept by backup.sh prune: the last-good marker names this backup")}
              class="rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-success-ink"
            >
              {gettext("Last good: %{component}", component: component_label(component))}
            </span>
            <%!-- A schedule's keep N or keep days holds this unit (#2219, #2933).
                 `@markers` is empty until the disk read answers and leaves out
                 an unreadable directory, so neither draws a badge. --%>
            <span
              :for={component <- Markers.held_components(@markers, run.stamp)}
              data-role="held"
              data-component={component}
              title={
                gettext(
                  "Kept by backup.sh prune: a schedule's keep settings hold this backup (kiln-<stamp>.hold)"
                )
              }
              class="rounded bg-primary/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-primary-ink"
            >
              {gettext("Kept by a schedule: %{component}", component: component_label(component))}
            </span>
            <span class="ml-auto tabular-nums text-base-content/70">
              {humanize_bytes(total_bytes(run))}
            </span>
          </div>

          <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
            <span data-role="verified">{verified_label(run)}</span>
            <.help_tip
              :if={unverified_import?(run)}
              id={"imported-help-#{run.id}"}
              label={gettext("About imported backups")}
              title={gettext("Made by cron")}
              learn_more={docs_url("backups.md#backup-history-2217")}
            >
              {gettext(
                "Cron's scripts/backup.sh made this backup and the app found it on disk. The app didn't check it with pg_restore; run scripts/backup.sh verify on the server to check the newest backup."
              )}
            </.help_tip>
            <a
              :for={count <- part_counts(run)}
              data-role="parts"
              href={docs_url("backups.md#restore-a-media-set-that-has-several-parts")}
              target="_blank"
              rel="noopener"
              title={gettext("How to restore a media backup written in several parts")}
              class="link inline-flex items-center gap-1 text-primary-ink"
            >
              {ngettext("%{count} part", "%{count} parts", count)}
              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
              <span class="sr-only">
                {gettext("How to restore a media backup written in several parts")}
                {gettext("(opens in a new tab)")}
              </span>
            </a>
            <span
              :for={{label, status, error} <- destination_chips(run)}
              data-role="destination"
              data-status={status}
              title={error}
              class="rounded border border-base-content/20 px-1.5 py-0.5 font-mono"
            >
              {label} · {destination_status_label(status)}
            </span>
            <%!-- #2220: a backup that reached only some destinations, or one
                  that recorded no outcome for them (finished by an older
                  node). --%>
            <span
              :if={run_offsite(run) == :partial}
              data-role="offsite-partial"
              class="rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-warning-ink"
            >
              {gettext("Partly off-site")}
            </span>
            <span
              :if={run_offsite(run) == :failed}
              data-role="offsite-failed"
              title={gettext("This backup succeeded but was copied to no off-site destination.")}
              class="rounded bg-error/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-error-ink"
            >
              {gettext("Not off-site")}
            </span>
            <span
              :if={run_offsite(run) == :unknown}
              data-role="offsite-unknown"
              title={gettext("This backup recorded no outcome for its off-site destinations.")}
              class="rounded bg-base-content/10 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-base-content/70"
            >
              {gettext("Off-site unknown")}
            </span>
            <.presence
              run={run}
              presence={Map.get(@presence, run.id)}
              disk={@disk}
            />
            <%!-- Hidden once the backup is finishing, as on the strip: Cancel is
                  refused from there (#2542). Hidden too while a resume of it
                  waits to start (#2816): the strip's Cancel stops that one.
                  `@in_flight` is read here, not when the row was built, so it
                  doesn't matter which loaded first. --%>
            <button
              :if={
                cancelable? and not finishing?(@in_flight, run) and
                  not resume_waiting?(@in_flight, run)
              }
              type="button"
              phx-click="cancel_run"
              phx-value-id={run.id}
              phx-disable-with={gettext("Canceling…")}
              data-role="cancel"
              data-confirm={cancel_confirm(@in_flight || %{waiting: nil})}
              class="btn btn-sm btn-danger ml-auto"
            >
              <.icon name="hero-stop-circle" class="mr-1 size-4" />
              {gettext("Cancel")}
            </button>
            <button
              :if={resumable?(@disk, @resumable, run)}
              type="button"
              phx-click="resume_run"
              phx-value-id={run.id}
              phx-disable-with={gettext("Requesting…")}
              data-role="resume"
              title={resume_title(run)}
              class="btn btn-sm btn-default ml-auto"
            >
              <.icon name="hero-arrow-path" class="mr-1 size-4" />
              {gettext("Resume")}
            </button>
            <%!-- #2949: a partly off-site backup whose files are here, sent
                  again to the destinations it missed. Hidden while it is
                  being re-sent; the strip says so and has its Cancel. --%>
            <span
              :if={resending?(@in_flight, run)}
              data-role="resending"
              class="rounded bg-info/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-info-ink"
            >
              {gettext("Re-sending…")}
            </span>
            <button
              :if={
                resendable?(@disk, @presence, @resend_offers, run) and not resending?(@in_flight, run)
              }
              type="button"
              phx-click="resend_run"
              phx-value-id={run.id}
              phx-disable-with={gettext("Requesting…")}
              data-role="resend"
              data-confirm={resend_confirm(@resend_offers[run.id])}
              title={gettext("Send this backup again to the off-site destinations it missed.")}
              class="btn btn-sm btn-default ml-auto"
            >
              <.icon name="hero-cloud-arrow-up" class="mr-1 size-4" />
              {gettext("Re-send")}
            </button>
            <.help_tip
              :if={
                resendable?(@disk, @presence, @resend_offers, run) and not resending?(@in_flight, run)
              }
              id={"resend-help-#{run.id}"}
              label={gettext("About Re-send")}
              title={gettext("Re-send")}
              learn_more={docs_url("backups.md#re-send-a-partly-off-site-backup")}
            >
              {gettext(
                "Sends this backup's files, as they are in the backup directory, to the destinations it missed. Each file is checked against its recorded checksum before each copy; a file that changed is not sent and the backup is marked unverified. The backup's status doesn't change."
              )}
            </.help_tip>
            <.help_tip
              :if={resumable?(@disk, @resumable, run)}
              id={"resume-help-#{run.id}"}
              label={gettext("About Resume")}
              title={gettext("Resume")}
              learn_more={docs_url("backups.md#media-backups-in-parts-2218")}
            >
              {gettext(
                "Continues from the files already written; each is reused only if its checksum still matches. It backs up the files listed when the backup first started, so its files can be from different times."
              )}
            </.help_tip>
          </div>

          <pre
            :if={run.error}
            class="overflow-x-auto whitespace-pre-wrap break-words text-xs text-base-content/80"
          >{run.error}</pre>
        </li>
      </ul>

      <div :if={@page > 1 || @page < @last_page} class="mt-4 flex items-center justify-between">
        <button
          type="button"
          phx-click="page"
          phx-value-to={@page - 1}
          disabled={@page == 1}
          class="btn btn-sm btn-default disabled:opacity-40"
        >
          {gettext("Previous")}
        </button>
        <span class="text-sm text-base-content/70">
          {gettext("Page %{page} of %{last}", page: @page, last: @last_page)}
        </span>
        <button
          type="button"
          phx-click="page"
          phx-value-to={@page + 1}
          disabled={@page >= @last_page}
          class="btn btn-sm btn-default disabled:opacity-40"
        >
          {gettext("Next")}
        </button>
      </div>
    </section>
    """
  end

  attr :run, :map, required: true
  attr :presence, :map, default: nil, doc: "`Backups.Presence.t()`, nil until read"
  attr :disk, :map, required: true

  # Whether the run's files are on this server's disk, artifact by artifact
  # when they differ (#2416), with the parts of a media set that are gone.
  # Nothing is claimed while the disk read is out or failed (#2417).
  defp presence(assigns) do
    ~H"""
    <span
      :if={@disk.state == :timed_out}
      data-role="presence"
      data-presence="timeout"
      class="text-warning-ink"
    >
      {gettext("couldn't check in time")}
    </span>
    <span
      :if={@disk.state == :failed}
      data-role="presence"
      data-presence="unknown"
      class="text-warning-ink"
    >
      {presence_label(:unknown)}
    </span>
    <%= if @disk.state in [:idle, :ready] do %>
      <span :if={is_nil(@presence)} data-role="presence" data-presence="checking">
        {gettext("checking…")}
      </span>
      <%= if @presence && @presence.state != :none do %>
        <span
          data-role="presence"
          data-presence={@presence.state}
          class={presence_class(@presence.state)}
        >
          <%= if @presence.state == :mixed do %>
            <span
              :for={artifact <- @presence.artifacts}
              data-role="artifact-presence"
              data-kind={artifact.kind}
              data-presence={artifact.state}
              class={["mr-2", presence_class(artifact.state)]}
            >
              {component_label(artifact.kind)}: {presence_label(artifact.state)}
            </span>
          <% else %>
            {presence_label(@presence.state)}
          <% end %>
        </span>
        <span
          :for={artifact <- @presence.artifacts}
          :if={artifact.parts && artifact.gone != []}
          data-role="parts-missing"
          data-kind={artifact.kind}
          title={Enum.join(artifact.gone, ", ")}
          class="text-warning-ink"
        >
          {ngettext(
            "%{count} part missing: %{parts}",
            "%{count} parts missing: %{parts}",
            length(artifact.gone),
            parts: part_numbers(artifact.gone)
          )}
        </span>
        <.help_tip
          :if={presence_help(@presence)}
          id={"presence-help-#{@run.id}"}
          label={gettext("About these files")}
          title={presence_label(presence_help(@presence))}
          learn_more={docs_url("backups.md#backup-history-2217")}
        >
          {presence_help_text(presence_help(@presence))}
        </.help_tip>
      <% end %>
    <% end %>
    """
  end

  # The state a row's ? tip explains: the worst of its artifacts' that needs
  # explaining, or nil.
  defp presence_help(%{artifacts: artifacts}) do
    states = Enum.map(artifacts, & &1.state)
    Enum.find([:missing, :probably_expired, :expired], &(&1 in states))
  end

  defp presence_help_text(:missing),
    do:
      gettext(
        "These files aren't in this server's backup directory, and nothing recorded why: they were deleted outside the app, or the backup was taken on another server. Each server has its own backup directory."
      )

  defp presence_help_text(:expired),
    do:
      gettext(
        "Cron's scripts/backup.sh prune removed these files: they are older than the BACKUP_KEEP_DAYS it records in manifest.json, and a newer backup of the same kind is on disk."
      )

  defp presence_help_text(:probably_expired),
    do:
      gettext(
        "Most likely removed by cron's scripts/backup.sh prune: they are older than this app's retention, and a newer backup of the same kind is on disk. Cron hasn't recorded its own BACKUP_KEEP_DAYS here, so this is an estimate."
      )

  defp presence_class(state) when state in [:missing, :unknown], do: "text-warning-ink"
  defp presence_class(_state), do: nil

  # "02, 05": the part numbers of the gone files, or their names when a name
  # isn't a part's.
  defp part_numbers(names) do
    Enum.map_join(names, ", ", fn name ->
      case Backups.Artifact.parse_file(name) do
        {:ok, %{part: part}} when is_integer(part) -> String.pad_leading("#{part}", 2, "0")
        _other -> name
      end
    end)
  end

  defp unverified_import?(%{origin: :imported, artifacts: [_ | _] = artifacts}),
    do: not Enum.all?(artifacts, & &1.verified)

  defp unverified_import?(_run), do: false

  # Re-send (#2949) needs the run's files on this server's disk, which only a
  # disk read that answered can vouch for (#2417), and a destination to send
  # to (`resend_offers/2`).
  defp resendable?(%{state: :ready}, presence, offers, run),
    do: Map.has_key?(offers, run.id) and match?(%{state: :present}, Map.get(presence, run.id))

  defp resendable?(_disk, _presence, _offers, _run), do: false

  defp resend_confirm(%{targets: targets, pruned_soon: []}),
    do:
      gettext(
        "Re-send this backup to %{names}? Each file is checked against its recorded checksum before it is copied.",
        names: Enum.join(targets, ", ")
      )

  defp resend_confirm(%{targets: targets, pruned_soon: pruned}),
    do:
      gettext(
        "Re-send this backup to %{names}? Each file is checked against its recorded checksum before it is copied. It is older than %{days} days, so retention on %{pruned} may remove it there again after the next backup.",
        names: Enum.join(targets, ", "),
        days: Backups.keep_days(),
        pruned: Enum.join(pruned, ", ")
      )

  defp resend_confirm(_none), do: nil

  # Resume needs the run's `.work/<stamp>/state.json`, which only a disk read
  # that answered can vouch for (#2417).
  defp resumable?(%{state: :ready}, resumable, run), do: Map.get(resumable, run.id, false)
  defp resumable?(_disk, _resumable, _run), do: false

  # The last-good line of each component (#2542, #2799): a stamp, none, or why
  # the page can't say.
  defp last_good_state(%{state: :timed_out}, _markers, _component), do: "timeout"
  defp last_good_state(%{state: :failed}, _markers, _component), do: "failed"
  defp last_good_state(%{state: :idle}, _markers, _component), do: "checking"

  defp last_good_state(_ready, markers, component) do
    cond do
      not Markers.readable?(markers, component) -> "unreadable"
      Markers.last_good(markers, component) -> "marked"
      true -> "none"
    end
  end

  defp last_good_label(disk, markers, component) do
    case last_good_state(disk, markers, component) do
      "timeout" -> gettext("couldn't check in time")
      "failed" -> gettext("couldn't check")
      "checking" -> gettext("checking…")
      "unreadable" -> gettext("couldn't read this server's backup directory")
      "marked" -> Markers.last_good(markers, component)
      "none" -> gettext("none yet")
    end
  end

  defp disk_timeout_s, do: max(div(disk_timeout_ms(), 1_000), 1)

  # Anything still out that may change what the page shows.
  defp busy?(assigns) do
    is_nil(assigns.status) or assigns.status_loading? or assigns.importing? or
      assigns.disk.running? or assigns.disk.dirty?
  end

  defp finishing?(%{stamp: stamp, phase: :finishing}, %{stamp: stamp}), do: true
  defp finishing?(_in_flight, _run), do: false

  # Resumable statuses (`Backups.run_resumable?/2`): a stale `running` run is
  # one whose chain was interrupted.
  # Static, not a countdown: the page doesn't poll when nothing is in flight,
  # so a countdown would go stale (#2538).
  defp resume_title(%{status: :canceled}),
    do:
      gettext(
        "Continue this canceled backup from the files it already wrote. Right after a Cancel, wait about two and a half minutes."
      )

  defp resume_title(%{status: :failed}),
    do: gettext("Continue this failed backup from the files it already wrote.")

  defp resume_title(_interrupted),
    do: gettext("Continue this interrupted backup from the files it already wrote.")

  # Who asked. `schedule` waits for in-app schedules (#2219); anything else
  # (an older or hand-set `BACKUP_TRIGGER`) shows as recorded.
  defp trigger_label("manual"), do: gettext("Manual")
  defp trigger_label("cron"), do: gettext("Cron")
  defp trigger_label("console"), do: gettext("Console")
  defp trigger_label("schedule"), do: gettext("Scheduled")
  defp trigger_label(other), do: other

  # The artifact's bytes are already the sum of its parts (#2218).
  defp total_bytes(run), do: Enum.reduce(run.artifacts, 0, &(&1.bytes + &2))

  # One entry per media set written in several parts.
  defp part_counts(run) do
    for %{parts: [_, _ | _] = parts} <- run.artifacts, do: length(parts)
  end

  defp status_class(:succeeded), do: "bg-success/15 text-success-ink"
  defp status_class(:failed), do: "bg-error/15 text-error-ink"
  defp status_class(:running), do: "bg-info/15 text-info-ink"
  defp status_class(:skipped), do: "bg-warning/15 text-warning-ink"
  defp status_class(:canceled), do: "bg-base-content/10 text-base-content/70"

  defp verified_label(%{artifacts: []}), do: "—"

  defp verified_label(%{artifacts: artifacts, origin: origin}) do
    cond do
      Enum.all?(artifacts, & &1.verified) -> gettext("Verified")
      origin == :imported -> gettext("unverified (imported)")
      true -> gettext("Not verified")
    end
  end

  # One chip per destination across the run's artifacts, worst status wins, so
  # a single failed copy is not hidden behind the others' success. A
  # destination the run recorded but no artifact reached (it failed before
  # its first file) gets a chip too, from the run's own entry (#2220), and
  # every chip carries that entry's error as its tooltip.
  defp destination_chips(run) do
    recorded = Map.new(run.destinations || [], &{&1.key, &1})

    from_artifacts =
      run.artifacts
      |> Enum.flat_map(&Enum.map(&1.destinations, fn {key, value} -> {key, value["status"]} end))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    only_recorded =
      for {key, d} <- recorded,
          not Map.has_key?(from_artifacts, key),
          d.status != :skipped,
          into: %{},
          do: {key, [status_key(d.status)]}

    from_artifacts
    |> Map.merge(only_recorded)
    |> Enum.sort_by(fn {key, _} -> {key != "local", key} end)
    |> Enum.map(fn {key, statuses} ->
      entry = Map.get(recorded, key)
      status = worst(statuses)
      {destination_label(key, run), status, chip_title(entry, status)}
    end)
  end

  # The entry's error, and for a destination that failed at once on an error
  # its adapter says no retry fixes, that it did (#3084).
  defp chip_title(%{permanent: true, error: error}, "failed") do
    at_once = gettext("Failed at once: the destination said no retry fixes this.")
    if is_binary(error) and error != "", do: error <> "\n" <> at_once, else: at_once
  end

  defp chip_title(%{error: error}, _status), do: error
  defp chip_title(nil, _status), do: nil

  defp destination_label("local", _run), do: gettext("Local")
  defp destination_label("rclone:" <> remote, _run), do: remote

  # A stored destination (#2220) by the name the run recorded for it, which
  # outlives the destination; "Removed destination" when the run has no
  # record of it.
  defp destination_label("dest:" <> _id = key, run) do
    case Enum.find(run.destinations || [], &(&1.key == key)) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> gettext("Removed destination")
    end
  end

  defp destination_label(other, _run), do: run_destination_label(other, nil)

  # The run's off-site outcome as History badges it (#2220), derived from its
  # destinations (`Backups.run_offsite_state/1`, #2951): `:partial`; `:failed`
  # for a succeeded run that reached no destination; or `:unknown` for a
  # succeeded run that had destinations and recorded no outcome it knows;
  # anything else gets no badge.
  defp run_offsite(%{destinations: [_ | _]} = run) do
    case {Backups.run_offsite_state(run), run.status} do
      {:partial, _status} -> :partial
      {:failed, :succeeded} -> :failed
      {:unknown, :succeeded} -> :unknown
      _other -> nil
    end
  end

  defp run_offsite(_run), do: nil

  # A `RunDestination` status as the chips spell it.
  defp status_key(status) when is_atom(status), do: Atom.to_string(status)
  defp status_key(%KilnCMS.Types.UnknownAtom{value: value}), do: value
  defp status_key(status) when is_binary(status), do: status

  defp destination_status_class("ok"), do: "text-success-ink"
  defp destination_status_class("failed"), do: "text-error-ink"
  defp destination_status_class(_other), do: "text-base-content/70"

  defp worst(statuses) do
    Enum.find(["failed", "pending", "pruned"], &(&1 in statuses)) || "ok"
  end

  defp destination_status_label("ok"), do: gettext("ok")
  defp destination_status_label("failed"), do: gettext("failed")
  defp destination_status_label("pending"), do: gettext("pending")
  defp destination_status_label("pruned"), do: gettext("pruned")
  defp destination_status_label("skipped"), do: gettext("skipped")
  defp destination_status_label(_other), do: "—"

  defp presence_label(:present), do: gettext("on disk")
  defp presence_label(:missing), do: gettext("missing")
  defp presence_label(:pruned), do: gettext("pruned (retention)")
  defp presence_label(:partly_pruned), do: gettext("partly pruned (retention)")
  defp presence_label(:expired), do: gettext("expired")
  defp presence_label(:probably_expired), do: gettext("probably expired")
  defp presence_label(:off_site_only), do: gettext("off-site only")
  defp presence_label(:unknown), do: gettext("couldn't check")

  # NOT just `stale?`. A backup that failed a minute ago is not stale — it is
  # recent and it is worthless — and tone driven by age alone rendered "The
  # last backup failed" with a green tick and a success border. Any component
  # (#2219): a fresh database backup doesn't make stale media fine.
  # Partly off-site (#2220) too: a good local backup that some destination
  # doesn't have is not a deployment that is fine.
  # Retention skipped or stopped (#2487) too: the backup is fine today, and
  # the disk fills up behind it.
  # The off-site alarm is exactly when there is an off-site line (#2951): a
  # failed destination removed since doesn't hold it up.
  defp alarming?(status),
    do:
      status.stale? or status.failed? or offsite_headline(status.offsite) != nil or
        status.retention != []

  # One component's line (#2219).
  defp headline(%{failed?: true}), do: gettext("The last backup failed")

  defp headline(%{last_good: %{at: at}, stale?: true}),
    do: gettext("Last backup was %{ago} ago", ago: ago(at))

  defp headline(%{last_good: %{at: at}}), do: gettext("Backed up %{ago} ago", ago: ago(at))

  defp headline(_never), do: gettext("No backup has ever been recorded")

  defp summary(%Manifest{} = manifest) do
    gettext("%{size} · %{count} file(s) · %{trigger}",
      size: humanize_bytes(Manifest.total_bytes(manifest)),
      count: length(manifest.artifacts),
      trigger: manifest.trigger
    )
  end

  # Coarse on purpose: "3 days" is the fact an admin acts on, and a precise
  # duration invites reading it as a schedule.

  defp humanize_bytes(b) when not is_integer(b) or b < 0, do: "—"
  defp humanize_bytes(b) when b < 1_024, do: "#{b} B"
  defp humanize_bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1_024, 1)} KB"
  defp humanize_bytes(b) when b < 1_073_741_824, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp humanize_bytes(b), do: "#{Float.round(b / 1_073_741_824, 2)} GB"

  defp backup_dir, do: Backups.dir()
  defp media_dir, do: Backups.media_dir()
  defp keep_days, do: Backups.keep_days()
  defp rclone_remote, do: Backups.rclone_remote()
end
