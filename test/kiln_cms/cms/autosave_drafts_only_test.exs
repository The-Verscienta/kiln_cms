defmodule KilnCMS.CMS.AutosaveDraftsOnlyTest do
  @moduledoc """
  `:autosave` refuses a published row (#1015).

  The action was always meant for drafts — its own comment said so — but the
  enforcement lived in `ContentEditorLive`, which bails unless `draft?(socket)`.
  A LiveView guard is not the action refusing, and this action is a bad one to
  reach on live content: it inherits `default_accept` (so it can write
  `audience`) and carries `ApplyAccessPassword`, while deliberately carrying no
  `FireArtifacts` and no `NotifyWebhooks`, because a draft edit is silent.

  Gate or lock a *published* document through it and the artifacts, the feeds
  and the Meilisearch index all keep serving the ungated version, with nothing
  anywhere recording that the document changed (#1006, #496).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "autosave-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "autosave-#{System.unique_integer([:positive])}"

  defp autosave(record, attrs, actor) do
    record
    |> Ash.Changeset.for_update(:autosave, attrs, actor: actor, tenant: record.org_id)
    |> Ash.update()
  end

  describe "a draft" do
    test "autosaves, including its audience" do
      actor = admin()
      page = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: actor)

      assert {:ok, saved} = autosave(page, %{title: "Edited", audience: :member}, actor)
      assert saved.title == "Edited"
      # Gating a draft is fine and is a thing editors do: nothing is serving it.
      assert saved.audience == :member
    end
  end

  describe "a published document" do
    setup do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Live", slug: slug()}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      KilnCMS.DataCase.drain_oban()
      %{actor: actor, page: Ash.reload!(page, authorize?: false, tenant: page.org_id)}
    end

    test "cannot be autosaved at all", ctx do
      assert {:error, error} = autosave(ctx.page, %{title: "Sneaky"}, ctx.actor)
      assert stale?(error)

      # And nothing was written.
      assert Ash.reload!(ctx.page, authorize?: false, tenant: ctx.page.org_id).title == "Live"
    end

    test "cannot be gated through it", ctx do
      # The specific reason the guard exists: this writes `audience` and fires
      # nothing, so every downstream surface would keep serving the public
      # version with no event recording the change.
      assert {:error, error} = autosave(ctx.page, %{audience: :member}, ctx.actor)
      assert stale?(error)

      assert Ash.reload!(ctx.page, authorize?: false, tenant: ctx.page.org_id).audience == :public
    end

    test "cannot be passphrase-locked through it", ctx do
      assert {:error, error} = autosave(ctx.page, %{access_password: "shared secret"}, ctx.actor)
      assert stale?(error)

      refute Ash.reload!(ctx.page, authorize?: false, tenant: ctx.page.org_id).access_password_hash
    end

    test "the refusal is a row-level compare-and-swap, not a struct check", ctx do
      # The race the guard is actually for: an editor holds a draft struct, the
      # document is published by someone else, and the next debounce fires. A
      # `validate attribute_equals(:state, :draft)` reads the STALE struct and
      # would let this through; a `change filter` compares against the row.
      stale_draft = %{ctx.page | state: :draft}

      # `optimistic_lock(:lock_version)` raises the SAME `StaleRecord` with no
      # distinguishing payload, so without this the assertion below cannot tell
      # the guard from the lock. Pinned rather than assumed: the setup reloads,
      # so the struct's lock matches the row and the lock cannot be what fires.
      assert stale_draft.lock_version ==
               Ash.reload!(ctx.page, authorize?: false, tenant: ctx.page.org_id).lock_version

      assert {:error, error} = autosave(stale_draft, %{audience: :member}, ctx.actor)
      assert stale?(error)

      assert Ash.reload!(ctx.page, authorize?: false, tenant: ctx.page.org_id).audience == :public
    end
  end

  describe "every other non-draft state" do
    # The predicate is `== :draft`, not `!= :published`, and that difference is
    # worth pinning: relaxing it to "not published" so reviewers can autosave
    # in-review copy is a plausible-sounding future request, and it would make
    # `:autosave` reachable on an ARCHIVED row — writing `audience` and
    # `access_password` into content whose artifacts and search entries have
    # already been deleted.
    setup do
      actor = admin()
      %{actor: actor}
    end

    test "in_review is refused", ctx do
      page =
        CMS.create_page!(%{title: "Under review", slug: slug()}, actor: ctx.actor)
        |> then(&CMS.submit_page_for_review!(&1, actor: ctx.actor))

      assert {:error, error} = autosave(page, %{title: "Sneaky"}, ctx.actor)
      assert stale?(error)
    end

    test "archived is refused", ctx do
      page =
        CMS.create_page!(%{title: "Archived", slug: slug()}, actor: ctx.actor)
        |> then(&CMS.archive_page!(&1, actor: ctx.actor))

      assert {:error, error} = autosave(page, %{audience: :member}, ctx.actor)
      assert stale?(error)
    end
  end

  # `change filter` raises `StaleRecord`, which is what `ContentEditorLive`'s
  # `stale_conflict?/1` already matches on — so the editor's answer to losing
  # this race is its existing "changed elsewhere, reload" flow (#137) rather
  # than a new error path.
  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_other), do: false
end
