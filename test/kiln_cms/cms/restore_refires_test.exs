defmodule KilnCMS.CMS.RestoreRefiresTest do
  @moduledoc """
  Restoring a trashed **published** document rebuilds what trashing tore down
  (#1025).

  Trashing is a soft delete, and `:destroy` runs `DeleteArtifacts`: it purges the
  fired artifacts and enqueues a Meilisearch removal. It does not touch `state`,
  so the record is still `:published` underneath — and restoring it put it
  straight back on the delivery path with no artifacts and no search entry,
  indefinitely, until some unrelated edit happened to re-fire it.

  The inverse of #1015: there a write changed a live document without firing;
  here a document became live again without firing.
  """
  use KilnCMS.DataCase, async: false

  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Firing

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "restore-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "restore-#{System.unique_integer([:positive])}"

  # A trashed row is filtered out of every ordinary read by AshArchival; the
  # `:trashed` action is the only one that sees it.
  defp trashed_page(record) do
    CMS.list_trashed_pages!(authorize?: false, tenant: record.org_id)
    |> Enum.find(&(&1.id == record.id))
  end

  defp artifact_count(record) do
    {:ok, artifacts} =
      Firing.artifacts_for(:page, record.id, authorize?: false, tenant: record.org_id)

    length(artifacts)
  end

  test "a trashed published page comes back with its artifacts rebuilt" do
    actor = admin()

    page =
      CMS.create_page!(%{title: "Live", slug: slug()}, actor: actor)
      |> then(&CMS.publish_page!(&1, actor: actor))

    drain_oban()
    assert artifact_count(page) > 0, "publishing did not fire"

    CMS.destroy_page!(page, actor: actor)
    drain_oban()

    # Trashing purged them, and left the record published underneath.
    assert artifact_count(page) == 0
    trashed = trashed_page(page)
    assert trashed.state == :published

    CMS.restore_page!(trashed, actor: actor)
    drain_oban()

    assert artifact_count(page) > 0,
           "restoring left the document live with no artifacts — #1025"
  end

  test "restoring a trashed draft stays silent" do
    # Nothing to rebuild: a draft never had artifacts to purge, and firing one
    # would publish an artifact for unpublished content.
    #
    # Asserted on the ENQUEUE, not on the artifact count. A count of zero proves
    # nothing here: an unconditional fire would enqueue a worker that loads the
    # draft, finds it absent, and purges — leaving zero artifacts either way. So
    # the count passes with `only_when: :published` removed, and this does not.
    actor = admin()
    draft = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: actor)

    CMS.destroy_page!(draft, actor: actor)
    drain_oban()

    CMS.restore_page!(trashed_page(draft), actor: actor)

    refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => draft.id})

    drain_oban()
    assert artifact_count(draft) == 0
  end

  test "a re-fire cancelled while the document was trashed does not swallow the restore" do
    # The issue's own timing — "restores it a minute later". Anything that
    # enqueues a `FireWorker` while the document is trashed (a read miss, an
    # oEmbed resolve, the sweep, or the publish's own job landing late) finds no
    # published row, purges, and CANCELS. With `:cancelled` in the worker's
    # unique states, the restore's enqueue collided with that row and the
    # document came back live with nothing rebuilt.
    actor = admin()

    page =
      CMS.create_page!(%{title: "Raced", slug: slug()}, actor: actor)
      |> then(&CMS.publish_page!(&1, actor: actor))

    drain_oban()
    CMS.destroy_page!(page, actor: actor)
    drain_oban()

    # A fire attempt while trashed: finds nothing, purges, cancels.
    {:ok, _job} =
      %{"org_id" => page.org_id, "type" => "page", "id" => page.id}
      |> KilnCMS.Firing.FireWorker.new()
      |> Oban.insert()

    drain_oban()

    CMS.restore_page!(trashed_page(page), actor: actor)
    drain_oban()

    assert artifact_count(page) > 0,
           "the restore's fire was deduped against a cancelled job — #1025"
  end
end
