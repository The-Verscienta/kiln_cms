defmodule KilnCMS.Firing.SyncExposureBackfillTest do
  @moduledoc """
  #2275 (A3): the documents that were public before the change feed recorded
  what it disclosed get an exposure, so the feed may name them when they are
  withdrawn — and nothing that is not public right now gets one.
  """
  # async: false — `enqueue/0` asserts on the shared `oban_jobs` uniqueness.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Firing.SyncExposureBackfill

  @moduletag :capture_log

  setup do
    org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "Backfill Site",
        slug: "backfill-#{System.unique_integer([:positive])}",
        status: :active
      })

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "backfill-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    %{org: org, admin: admin}
  end

  defp post!(ctx, attrs) do
    CMS.create_post!(
      Map.merge(
        %{title: "Post", slug: "backfill-#{System.unique_integer([:positive])}"},
        attrs
      ),
      actor: ctx.admin,
      tenant: ctx.org
    )
  end

  defp published!(ctx, attrs \\ %{}),
    do: ctx |> post!(attrs) |> CMS.publish_post!(%{}, actor: ctx.admin, tenant: ctx.org)

  defp exposed(ctx, ids) do
    ids
    |> KilnCMS.Firing.sync_exposures_for!(actor: KilnCMS.SystemActor.new(:sync), tenant: ctx.org)
    |> Enum.map(& &1.document_id)
    |> Enum.sort()
  end

  defp exposure_rows(ctx) do
    KilnCMS.Repo.all(
      from(e in "sync_exposures",
        where: e.org_id == type(^ctx.org.id, Ecto.UUID),
        select: %{document_id: e.document_id, tuple: fragment("ctid::text")},
        order_by: e.document_id
      )
    )
  end

  # As an install that predates the feed's recording: no exposure at all.
  defp forget_exposures(ctx) do
    KilnCMS.Repo.delete_all(
      from(e in "sync_exposures", where: e.org_id == type(^ctx.org.id, Ecto.UUID))
    )
  end

  test "records every public document of the site, and nothing else", ctx do
    public = published!(ctx)

    page =
      %{title: "A page", slug: "backfill-page-#{System.unique_integer([:positive])}"}
      |> CMS.create_page!(actor: ctx.admin, tenant: ctx.org)
      |> CMS.publish_page!(%{}, actor: ctx.admin, tenant: ctx.org)

    gated = published!(ctx, %{audience: hd(Audiences.gated())})
    locked = published!(ctx, %{access_password: "shared secret"})
    draft = post!(ctx, %{})

    forget_exposures(ctx)
    all = [public.id, page.id, gated.id, locked.id, draft.id]
    assert exposed(ctx, all) == []

    assert SyncExposureBackfill.run_org(ctx.org.id) == 2
    assert exposed(ctx, all) == Enum.sort([public.id, page.id])

    # A second run walks the same documents and writes nothing: not a new
    # row, and not a rewrite of an old one (which would move its `ctid`).
    rows = exposure_rows(ctx)
    assert SyncExposureBackfill.run_org(ctx.org.id) == 2
    assert exposure_rows(ctx) == rows
  end

  test "is queued once, and never raises" do
    assert :ok = SyncExposureBackfill.enqueue()
    assert :ok = SyncExposureBackfill.enqueue()
    assert [_one] = all_enqueued(worker: SyncExposureBackfill)
  end
end
