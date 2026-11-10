defmodule KilnCMS.CMS.TrashedRowGuardTest do
  @moduledoc """
  A trashed content row takes no update (#2332).

  Trashing is a soft delete: AshArchival stamps `archived_at` and hides the
  row from every ordinary read, but did nothing for updates. Anyone holding
  the struct from before the trash (an open editor, an API client between
  its read and its write, a background job) wrote straight into the trashed
  row: an autosave, a transition, a *Publish changes* that re-fired the
  artifacts and sent `updated` after `deleted`.

  `KilnCMS.CMS.Changes.RefuseTrashed` puts a row filter on every update
  action except `:restore`, `:clear_reference_target` and the contract-step
  backfills `:convert_custom_field` and `:resnapshot_media` (#2533), and `:restore` and
  `:destroy` each carry a compare-and-swap of their own so neither runs twice
  from one held struct. `:purge` takes only a row still in the trash (#2531):
  a held struct of a row someone restored meanwhile hard-deleted live content.

  Every refusal below is called with the struct loaded BEFORE the trash, the
  race itself. A trash does not bump `lock_version`, so the held struct still
  matches the row's lock and the refusal is the trash guard, not the
  optimistic lock; `assert_refused/2` pins that.
  """
  # Oban jobs are drained in this process, and `AshOban.schedule_and_run_triggers/2`
  # scans every org's content, so another test's scheduled rows would be published
  # by this one's run.
  use KilnCMS.DataCase, async: false

  use Oban.Testing, repo: KilnCMS.Repo

  alias Ash.Error.Changes.StaleRecord
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.RefuseTrashed
  alias KilnCMS.Firing
  alias KilnCMS.Firing.FireWorker
  alias KilnCMS.Repo

  @content_resources [CMS.Page, CMS.Post, CMS.Entry]

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "trg-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "trg-#{System.unique_integer([:positive])}"

  defp draft(actor, attrs \\ %{}),
    do: CMS.create_page!(Map.merge(%{title: "Draft", slug: slug()}, attrs), actor: actor)

  defp live(actor) do
    page = CMS.publish_page!(draft(actor, %{title: "Live"}), %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()
    reload(page)
  end

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp trashed(page) do
    CMS.list_trashed_pages!(authorize?: false, tenant: page.org_id)
    |> Enum.find(&(&1.id == page.id))
  end

  defp autosave(record, attrs, actor) do
    record
    |> Ash.Changeset.for_update(:autosave, attrs, actor: actor, tenant: record.org_id)
    |> Ash.update()
  end

  # Raw, so neither AshArchival's read filter nor a policy hides the row.
  defp row(%CMS.Page{id: id}), do: row("SELECT #{columns()} FROM pages WHERE id = $1", id)
  defp row(%CMS.Entry{id: id}), do: row("SELECT #{columns()} FROM entries WHERE id = $1", id)

  defp row(sql, id) do
    %{rows: [[title, lock_version, updated_at, archived_at]]} =
      Repo.query!(sql, [Ecto.UUID.dump!(id)])

    %{title: title, lock_version: lock_version, updated_at: updated_at, archived_at: archived_at}
  end

  defp columns, do: "title, lock_version, updated_at, archived_at"

  # `held` was loaded before the trash. The write must be refused with
  # `StaleRecord` and leave the row exactly as the trash left it.
  defp assert_refused(held, write) do
    before = row(held)
    assert before.archived_at, "the record under test is not trashed"

    assert held.lock_version == before.lock_version,
           "the held struct's lock no longer matches the row, so the optimistic " <>
             "lock and not the trash guard could be what refuses"

    assert {:error, %Ash.Error.Invalid{errors: [%StaleRecord{} | _]}} = write.(held)
    assert row(held) == before
  end

  defp stub_capture do
    test_pid = self()

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:delivered, conn.host, conn.request_path, Map.new(conn.req_headers), body})
      Req.Test.json(conn, %{ok: true})
    end)
  end

  defp events_received do
    Stream.repeatedly(fn ->
      receive do
        {:delivered, _, _, %{"x-kilncms-event" => event}, body} -> {event, Jason.decode!(body)}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
  end

  defp artifact_count(page) do
    {:ok, artifacts} =
      Firing.artifacts_for(:page, page.id, authorize?: false, tenant: page.org_id)

    length(artifacts)
  end

  describe "the guard is on every update action" do
    test "each content resource carries RefuseTrashed as a global update change" do
      for resource <- @content_resources do
        modules =
          resource
          |> Ash.Resource.Info.changes(:update)
          |> Enum.map(fn %{change: {module, _opts}} -> module end)

        assert RefuseTrashed in modules, "#{inspect(resource)} lost the trash guard (#2332)"
      end
    end

    test "exactly :restore, :clear_reference_target and the two contract-step backfills are exempt, all update actions" do
      assert RefuseTrashed.exempt_actions() == [
               :restore,
               :clear_reference_target,
               :convert_custom_field,
               :resnapshot_media
             ]

      for resource <- @content_resources, name <- RefuseTrashed.exempt_actions() do
        assert %{type: :update} = Ash.Resource.Info.action(resource, name),
               "#{inspect(resource)} has no update action #{inspect(name)}"
      end
    end

    # Pins the exemption logic per action, without running each action: a new
    # update action refuses a trashed row unless someone adds it to the list.
    test "every other update action gets the archived_at row filter" do
      for resource <- @content_resources,
          %{type: :update} = action <- Ash.Resource.Info.actions(resource) do
        changeset =
          resource
          |> Ash.Changeset.new()
          |> Map.put(:action, action)
          |> RefuseTrashed.change([], %{})

        if action.name in RefuseTrashed.exempt_actions() do
          assert changeset.filter == nil,
                 "#{inspect(resource)}.#{action.name} is exempt but got a filter"
        else
          assert archived_at_refs(changeset.filter) != [],
                 "#{inspect(resource)}.#{action.name} got no trash filter: update actions " <>
                   "refuse a trashed row by default (#2332); exempt one only in " <>
                   "RefuseTrashed, with the reason"
        end
      end
    end

    defp archived_at_refs(nil), do: []

    defp archived_at_refs(filter) do
      filter
      |> Ash.Filter.list_refs()
      |> Enum.filter(fn
        %{attribute: %{name: :archived_at}} -> true
        %{attribute: :archived_at} -> true
        _other -> false
      end)
    end
  end

  describe "a held struct of a trashed draft" do
    test "cannot autosave" do
      actor = admin()
      held = draft(actor)
      :ok = CMS.destroy_page!(held, actor: actor)

      assert_refused(held, &autosave(&1, %{title: "Typed after the trash"}, actor))
    end

    test "cannot update" do
      actor = admin()
      held = draft(actor)
      :ok = CMS.destroy_page!(held, actor: actor)

      assert_refused(held, &CMS.update_page(&1, %{title: "Saved after the trash"}, actor: actor))
    end

    test "cannot be marked reviewed" do
      actor = admin()
      held = draft(actor)
      :ok = CMS.destroy_page!(held, actor: actor)

      assert_refused(held, &CMS.mark_page_reviewed(&1, %{}, actor: actor))
    end

    test "cannot restore an old version" do
      actor = admin()
      page = draft(actor)
      held = CMS.update_page!(page, %{title: "Second"}, actor: actor)

      [first | _] =
        CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
        |> Enum.filter(&(&1.version_source_id == page.id))
        |> Enum.sort_by(& &1.version_inserted_at, DateTime)

      :ok = CMS.destroy_page!(held, actor: actor)

      assert_refused(
        held,
        &CMS.restore_page_version(&1, %{version_id: first.id}, actor: actor)
      )
    end
  end

  describe "a held struct of a trashed live document" do
    test "cannot have oEmbed metadata written into it" do
      actor = admin()
      held = live(actor)
      :ok = CMS.destroy_page!(held, actor: actor)
      KilnCMS.DataCase.drain_oban()

      # The write `KilnCMS.OEmbed.ResolveWorker` makes. The worker re-fires a
      # published document only after this succeeds, so the refusal is what
      # keeps a held resolve from re-firing a trashed page.
      assert_refused(held, fn held ->
        held
        |> Ash.Changeset.for_update(:set_oembed_metadata, %{blocks: []},
          authorize?: false,
          tenant: held.org_id
        )
        |> Ash.update()
      end)

      refute_enqueued(worker: FireWorker, args: %{"id" => held.id})
    end

    test "cannot save a working copy" do
      actor = admin()
      held = live(actor)
      :ok = CMS.destroy_page!(held, actor: actor)

      assert_refused(
        held,
        &CMS.save_page_working_copy(&1, %{working_title: "After the trash"},
          actor: actor,
          tenant: &1.org_id
        )
      )
    end

    test "cannot publish its changes: no re-fire, no updated after deleted" do
      stub_capture()
      actor = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: actor)

      page = live(actor)

      {:ok, held} =
        CMS.save_page_working_copy(page, %{working_title: "Pending edit"},
          actor: actor,
          tenant: page.org_id
        )

      KilnCMS.DataCase.drain_oban()
      _ = events_received()

      :ok = CMS.destroy_page!(held, actor: actor)
      KilnCMS.DataCase.drain_oban()
      assert [{"page.deleted", _}] = events_received()

      assert_refused(held, &CMS.publish_page_changes(&1, %{}, actor: actor))

      # The fix: before #2332 this re-fired the artifacts of a trashed page and
      # announced `updated` to every subscriber after `deleted`.
      refute_enqueued(worker: FireWorker, args: %{"id" => page.id})
      KilnCMS.DataCase.drain_oban()
      assert events_received() == []

      # Regression pins (true before the fix too): nothing is delivered.
      assert artifact_count(page) == 0
      assert {:error, _} = CMS.get_published_page_by_slug(page.slug, page.locale)
    end
  end

  describe "workflow transitions on a held struct of a trashed page" do
    test "are refused, each one" do
      actor = admin()

      cases = [
        {:submit, fn -> draft(actor) end, &CMS.submit_page_for_review(&1, %{}, actor: actor)},
        {:return_to_draft, fn -> CMS.submit_page_for_review!(draft(actor), %{}, actor: actor) end,
         &CMS.return_page_to_draft(&1, %{}, actor: actor)},
        {:publish, fn -> draft(actor) end, &CMS.publish_page(&1, %{}, actor: actor)},
        {:unpublish, fn -> live(actor) end, &CMS.unpublish_page(&1, %{}, actor: actor)},
        {:archive, fn -> live(actor) end, &CMS.archive_page(&1, %{}, actor: actor)},
        {:unarchive, fn -> reload(CMS.archive_page!(live(actor), %{}, actor: actor)) end,
         &CMS.unarchive_page(&1, %{}, actor: actor)}
      ]

      for {name, setup, write} <- cases do
        held = setup.()
        :ok = CMS.destroy_page!(held, actor: actor)
        KilnCMS.DataCase.drain_oban()

        try do
          assert_refused(held, write)
        rescue
          error in ExUnit.AssertionError ->
            reraise %{error | message: "#{name}: #{error.message}"}, __STACKTRACE__
        end
      end
    end
  end

  describe "scheduled publishing" do
    test "a trashed draft whose date has passed is not published, until it is restored" do
      actor = admin()
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      held = draft(actor, %{scheduled_at: past})
      :ok = CMS.destroy_page!(held, actor: actor)

      # Regression pin (true before the fix too): the trigger reads through the
      # archival-filtered read, so it never picks a trashed row.
      run_scheduled_triggers()
      assert trashed(held).state == :draft

      # The worker's action itself refuses the held struct.
      assert_refused(held, &CMS.publish_scheduled_page(&1, %{}, actor: actor))

      # Restored, its date has still passed, so the next run publishes it.
      CMS.restore_page!(trashed(held), actor: actor)
      run_scheduled_triggers()
      assert reload(held).state == :published
    end

    defp run_scheduled_triggers do
      AshOban.schedule_and_run_triggers(CMS.Page,
        drain_queues?: true,
        with_recursion: true,
        with_scheduled: true
      )
    end
  end

  describe ":restore" do
    test "still restores a trashed draft and a trashed live page, re-firing the live one" do
      actor = admin()
      draft = draft(actor)
      page = live(actor)
      :ok = CMS.destroy_page!(draft, actor: actor)
      :ok = CMS.destroy_page!(page, actor: actor)
      KilnCMS.DataCase.drain_oban()

      assert {:ok, %{archived_at: nil}} = CMS.restore_page(trashed(draft), actor: actor)
      assert {:ok, %{archived_at: nil}} = CMS.restore_page(trashed(page), actor: actor)
      assert_enqueued(worker: FireWorker, args: %{"id" => page.id})
    end

    test "a second restore of the same held struct is refused, with one restored webhook" do
      stub_capture()
      actor = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: actor)

      page = draft(actor)
      :ok = CMS.destroy_page!(page, actor: actor)
      KilnCMS.DataCase.drain_oban()
      _ = events_received()

      held = trashed(page)
      assert {:ok, _} = CMS.restore_page(held, actor: actor)

      assert {:error, %Ash.Error.Invalid{errors: [%StaleRecord{} | _]}} =
               CMS.restore_page(held, actor: actor)

      KilnCMS.DataCase.drain_oban()
      assert [{"page.restored", _}] = events_received()
    end
  end

  describe ":destroy" do
    test "a second trash of the same held struct is refused, with one deleted webhook" do
      stub_capture()
      actor = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: actor)

      held = live(actor)
      _ = events_received()

      assert :ok = CMS.destroy_page(held, actor: actor)

      assert {:error, %Ash.Error.Invalid{errors: [%StaleRecord{} | _]}} =
               CMS.destroy_page(held, actor: actor)

      KilnCMS.DataCase.drain_oban()
      assert [{"page.deleted", _}] = events_received()
    end
  end

  describe ":purge" do
    test "of a held struct someone restored is refused, and the row stays live" do
      stub_capture()
      actor = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: actor)

      page = live(actor)
      :ok = CMS.destroy_page!(page, actor: actor)
      KilnCMS.DataCase.drain_oban()

      held = trashed(page)
      assert {:ok, _} = CMS.restore_page(held, actor: actor)
      KilnCMS.DataCase.drain_oban()
      artifacts = artifact_count(page)
      assert artifacts > 0
      _ = events_received()

      assert {:error, %Ash.Error.Invalid{errors: [%StaleRecord{} | _]}} =
               CMS.purge_page(held, actor: actor)

      KilnCMS.DataCase.drain_oban()
      assert %{archived_at: nil, state: :published} = CMS.get_page!(page.id, actor: actor)
      assert artifact_count(page) == artifacts
      assert events_received() == []
    end

    test "of a page that was never trashed is refused" do
      actor = admin()
      page = draft(actor)

      assert {:error, %Ash.Error.Invalid{errors: [%StaleRecord{} | _]}} =
               CMS.purge_page(page, actor: actor)

      assert CMS.get_page!(page.id, actor: actor).id == page.id
    end

    test "a second purge, or a restore, of a held struct someone purged is refused" do
      actor = admin()
      page = draft(actor)
      :ok = CMS.destroy_page!(page, actor: actor)

      held = trashed(page)
      assert :ok = CMS.purge_page(held, actor: actor)

      assert {:error, %Ash.Error.Invalid{errors: [%StaleRecord{} | _]}} =
               CMS.purge_page(held, actor: actor)

      assert {:error, %Ash.Error.Invalid{errors: [%StaleRecord{} | _]}} =
               CMS.restore_page(held, actor: actor)
    end
  end

  describe "a dynamic type's entry" do
    test "cannot be autosaved once trashed" do
      actor = admin()

      type =
        CMS.create_type_definition!(
          %{name: "trg#{System.unique_integer([:positive])}", label: "Guarded"},
          actor: actor
        )

      held =
        CMS.create_entry!(%{type_definition_id: type.id, title: "Entry", slug: slug()},
          actor: actor
        )

      :ok = CMS.destroy_entry!(held, actor: actor)

      assert_refused(held, &autosave(&1, %{title: "Typed after the trash"}, actor))
    end
  end

  describe "purging a reference target (:clear_reference_target, exempt)" do
    test "clears a trashed published referrer without re-firing or announcing it" do
      stub_capture()
      actor = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: actor)

      name = "authors_#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: name,
          label: "Authors",
          field_type: :reference,
          target_type: "page",
          on_target_delete: :clear
        },
        actor: actor
      )

      target = draft(actor, %{title: "Gone"})

      published_post = fn title ->
        %{title: title, slug: slug(), custom_fields: %{name => target.id}}
        |> CMS.create_post!(actor: actor)
        |> CMS.publish_post!(%{}, actor: actor)
      end

      # The control: a live referrer is re-fired and announced, as before.
      live_referrer = published_post.("Live referrer")
      trashed_referrer = published_post.("Trashed referrer")
      :ok = CMS.destroy_post!(trashed_referrer, actor: actor)
      KilnCMS.DataCase.drain_oban()
      _ = events_received()

      :ok = CMS.destroy_page!(target, actor: actor)
      assert :ok = CMS.purge_page(trashed(target), actor: actor)

      assert_enqueued(worker: FireWorker, args: %{"id" => live_referrer.id})
      refute_enqueued(worker: FireWorker, args: %{"id" => trashed_referrer.id})

      KilnCMS.DataCase.drain_oban()

      updated =
        for {"post.updated", %{"data" => %{"id" => id}}} <- events_received(), do: id

      assert updated == [live_referrer.id]

      # The clear itself still happens, so a restore cannot bring the purged
      # record back.
      [still_trashed] =
        CMS.list_trashed_posts!(authorize?: false, tenant: trashed_referrer.org_id)
        |> Enum.filter(&(&1.id == trashed_referrer.id))

      refute Map.has_key?(still_trashed.custom_fields, name)
    end
  end
end
