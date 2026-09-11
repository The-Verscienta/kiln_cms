defmodule KilnCMS.CMS.WorkingCopyTest do
  @moduledoc """
  The working copy of a live document (docs/working-copy.md).

  A published record keeps two texts: `title` / `blocks`, which every delivery
  read serves, and `working_title` / `working_blocks`, which the editor types
  into. `:save_working_copy` moves only the second; `:publish_changes` hands it
  over; `:discard_changes` puts the published text back and leaves the discarded
  words in history; leaving `:published` folds it into the row.
  """
  use KilnCMS.DataCase, async: true

  use Oban.Testing, repo: KilnCMS.Repo

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.WorkingCopy

  defp user(role, extra \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "wc-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )
  end

  defp slug, do: "wc-#{System.unique_integer([:positive])}"

  defp heading(text), do: %{"_type" => "heading", "text" => text}

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp live_page(actor, attrs \\ %{}) do
    page =
      CMS.create_page!(
        Map.merge(%{title: "Live", slug: slug(), blocks: [heading("Published body")]}, attrs),
        actor: actor
      )

    page = CMS.publish_page!(page, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()
    reload(page)
  end

  defp save_copy(page, title, blocks, actor) do
    CMS.save_page_working_copy(page, %{working_title: title, working_blocks: blocks},
      actor: actor,
      tenant: page.org_id
    )
  end

  defp heading_texts(blocks) do
    blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> Enum.map(fn %KilnCMS.Blocks.Heading{text: text} -> text end)
  end

  defp versions(page) do
    CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_other), do: false

  describe "saving the working copy" do
    test "moves the working copy alone; readers, search and the row's text stay put" do
      admin = user(:admin)
      page = live_page(admin)

      assert {:ok, saved} = save_copy(page, "Edited", [heading("Edited body")], admin)

      assert saved.title == "Live"
      assert heading_texts(saved.blocks) == ["Published body"]
      assert saved.working_title == "Edited"
      assert heading_texts(saved.working_blocks) == ["Edited body"]
      assert %DateTime{} = saved.working_copy_at
      assert WorkingCopy.pending?(saved)

      # The state pill's question and the delivery read's answer.
      view = WorkingCopy.view(saved)
      assert view.title == "Edited"
      assert view.state == :published

      delivered = CMS.get_published_page_by_slug!(page.slug, page.locale)
      assert delivered.title == "Live"
      assert heading_texts(delivered.blocks) == ["Published body"]

      # Search indexes the published words, not the draft's.
      assert reload(page).search_text == page.search_text
      assert saved.search_text =~ "Published body"
      refute saved.search_text =~ "Edited body"

      # No artifact re-fire for a draft edit.
      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
    end

    test "is refused on anything but a published row, at the row" do
      admin = user(:admin)
      draft = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)

      assert {:error, error} = save_copy(draft, "Sneaky", [], admin)
      assert stale?(error)
      refute reload(draft).working_copy_at

      # The race the row filter is for: the struct says published, the row does not.
      page = live_page(admin)
      {:ok, _} = CMS.unpublish_page(page, %{}, actor: admin)

      assert {:error, error} = save_copy(page, "Sneaky", [], admin)
      assert stale?(error)
    end

    test "a copy that matches the published text is no working copy at all" do
      admin = user(:admin)
      page = live_page(admin)

      {:ok, pending} = save_copy(page, "Edited", page.blocks, admin)
      assert WorkingCopy.pending?(pending)

      # Typing the title back is not running ahead of anything.
      {:ok, settled} = save_copy(pending, "Live", page.blocks, admin)
      refute WorkingCopy.pending?(settled)
      assert is_nil(settled.working_title)
      assert settled.working_blocks == []
      assert is_nil(settled.working_copy_at)
    end

    test "debounced saves coalesce into one version, like a draft autosave" do
      admin = user(:admin)
      page = live_page(admin)

      {:ok, one} = save_copy(page, "One", page.blocks, admin)
      {:ok, two} = save_copy(one, "Two", page.blocks, admin)
      {:ok, _three} = save_copy(two, "Three", page.blocks, admin)

      copies = Enum.filter(versions(page), &(&1.version_action_name == :save_working_copy))
      assert [%{changes: %{"working_title" => "Three"}}] = copies
    end

    test "editors write it under their title/body field grant, and only that" do
      admin = user(:admin)
      page = live_page(admin)

      title_only = user(:editor, %{field_grants: %{"page" => ["title"]}})
      assert {:ok, _} = save_copy(page, "Retitled", page.blocks, title_only)

      assert {:error, %Ash.Error.Invalid{} = error} =
               save_copy(reload(page), "Retitled", [heading("New body")], title_only)

      assert Exception.message(error) =~ "field grant"
    end
  end

  describe "publishing the changes" do
    test "hands the working copy over: same date, new live text, pointer moved" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, pending} = save_copy(page, "Edited", [heading("Edited body")], admin)

      assert {:ok, published} = CMS.publish_page_changes(pending, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      published = reload(published)

      assert published.state == :published
      assert published.title == "Edited"
      assert heading_texts(published.blocks) == ["Edited body"]
      refute WorkingCopy.pending?(published)
      assert is_nil(published.working_title)

      # Same address, same day.
      assert published.slug == page.slug
      assert published.published_at == page.published_at

      # Readers and search get the new words.
      assert CMS.get_published_page_by_slug!(page.slug, page.locale).title == "Edited"
      assert published.search_text =~ "Edited body"

      # The history panel's "live" mark follows the publish.
      [version] = Enum.filter(versions(page), &(&1.version_action_name == :publish_changes))
      assert published.published_version_id == version.id
      refute published.published_version_id == page.published_version_id
    end

    test "re-fires the artifacts and sends no workflow mail" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, pending} = save_copy(page, "Edited", page.blocks, admin)

      # The original publish mailed the author; a correction inside it does not.
      Swoosh.TestAssertions.assert_email_sent(subject: "Published: Live")
      assert {:ok, _} = CMS.publish_page_changes(pending, %{}, actor: admin)

      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
      Swoosh.TestAssertions.assert_no_email_sent()
    end

    test "is refused when nothing is pending" do
      admin = user(:admin)
      page = live_page(admin)

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.publish_page_changes(page, %{}, actor: admin)

      assert Exception.message(error) =~ "no unpublished changes"
    end

    test "publishes the row's working copy, not a stale struct's" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, older} = save_copy(page, "Older", page.blocks, admin)
      {:ok, _newer} = save_copy(older, "Newer", page.blocks, admin)

      # The struct holds "Older"; the row holds "Newer". The lock refuses it
      # rather than publishing yesterday's draft.
      assert {:error, error} = CMS.publish_page_changes(older, %{}, actor: admin)
      assert stale?(error)
      assert reload(page).title == "Live"
    end
  end

  describe "discarding the changes" do
    test "puts the published text back and keeps the discarded text as a version" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, pending} = save_copy(page, "Thrown away", [heading("Discarded body")], admin)

      assert {:ok, discarded} = CMS.discard_page_changes(pending, %{}, actor: admin)

      assert discarded.title == "Live"
      refute WorkingCopy.pending?(discarded)
      assert is_nil(discarded.working_title)

      history = versions(page)
      assert Enum.any?(history, &(&1.version_action_name == :discard_changes))

      kept = Enum.find(history, &(&1.version_action_name == :save_working_copy))
      assert kept.changes["working_title"] == "Thrown away"

      # And restoring that version brings the working copy back, live text untouched.
      {:ok, restored} = CMS.restore_page_version(discarded, %{version_id: kept.id}, actor: admin)
      restored = reload(restored)
      assert restored.title == "Live"
      assert WorkingCopy.pending?(restored)
      assert restored.working_title == "Thrown away"
      assert heading_texts(restored.working_blocks) == ["Discarded body"]
    end

    test "is refused when nothing is pending" do
      admin = user(:admin)
      page = live_page(admin)

      assert {:error, error} = CMS.discard_page_changes(page, %{}, actor: admin)
      assert stale?(error)
    end
  end

  describe "leaving :published" do
    test "unpublishing folds the working copy into the draft" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, pending} = save_copy(page, "Latest words", [heading("Latest body")], admin)

      # From a struct that predates the copy — the fold reads the row.
      assert {:ok, draft} = CMS.unpublish_page(page, %{}, actor: admin)
      draft = reload(draft)

      assert draft.state == :draft
      assert draft.title == "Latest words"
      assert heading_texts(draft.blocks) == ["Latest body"]
      assert draft.search_text =~ "Latest body"
      refute draft.working_copy_at
      assert is_nil(draft.working_title)

      # The text that was live is still the version the publish pointed at.
      assert pending.published_version_id

      {:ok, back} =
        CMS.restore_page_version(draft, %{version_id: pending.published_version_id}, actor: admin)

      assert back.title == "Live"
    end

    test "archiving folds it too" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, pending} = save_copy(page, "Archived words", page.blocks, admin)

      assert {:ok, archived} = CMS.archive_page(pending, %{}, actor: admin)
      assert archived.state == :archived
      assert archived.title == "Archived words"
      refute archived.working_copy_at
    end

    test "restoring a version from the live period onto a draft carries no shadow" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, pending} = save_copy(page, "Shadow", page.blocks, admin)
      copy_version = Enum.find(versions(page), &(&1.version_action_name == :save_working_copy))

      {:ok, draft} = CMS.unpublish_page(pending, %{}, actor: admin)

      {:ok, restored} =
        CMS.restore_page_version(reload(draft), %{version_id: copy_version.id}, actor: admin)

      assert restored.state == :draft
      assert is_nil(restored.working_title)
      assert is_nil(restored.working_copy_at)
    end
  end

  describe "in a content release" do
    defp release(admin), do: CMS.create_release!(%{name: "Launch #{slug()}"}, actor: admin)

    defp add(release, page, admin) do
      CMS.add_release_item(
        %{release_id: release.id, content_type: "page", content_id: page.id, action: :publish},
        actor: admin
      )
    end

    test "a live record with pending changes is applied, not skipped" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, pending} = save_copy(page, "Launch day title", page.blocks, admin)

      rel = release(admin)
      {:ok, item} = add(rel, pending, admin)

      assert KilnCMS.CMS.Releases.classify(item, authorize?: false, tenant: page.org_id) == :apply

      {:ok, _claimed} = CMS.start_release(rel, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      published = reload(page)
      assert published.state == :published
      assert published.title == "Launch day title"
      refute WorkingCopy.pending?(published)
      assert CMS.get_release_item!(item.id, authorize?: false).status == :applied

      # Rolling the release back puts the previous live text back.
      release = CMS.get_release!(rel.id, authorize?: false)
      {:ok, _} = CMS.start_release_rollback(release, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      rolled = reload(page)
      assert rolled.state == :published
      assert rolled.title == "Live"
    end

    test "a live record with nothing pending is still skipped" do
      admin = user(:admin)
      page = live_page(admin)
      rel = release(admin)
      {:ok, item} = add(rel, page, admin)

      assert {:skip, :already_in_state} =
               KilnCMS.CMS.Releases.classify(item, authorize?: false, tenant: page.org_id)
    end
  end
end
