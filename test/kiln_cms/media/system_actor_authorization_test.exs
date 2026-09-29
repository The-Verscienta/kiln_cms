defmodule KilnCMS.Media.SystemActorAuthorizationTest do
  @moduledoc """
  What the media pipeline is *authorized* to do, now that its workers, the
  regeneration scan and the quarantine reaper run as `Media.system/0` instead
  of `authorize?: false` (#1659), and that the reads a worker decides on fail
  CLOSED when that grant is gone.

  Every grant has a refusal next to it: the system records what it derived and
  releases a quarantine, but cannot `:update` (which gates an item), edit its
  metadata, soft-delete it, or purge an item that is no longer quarantined; an
  editor cannot reach the pipeline's actions; nobody but the system — an admin
  included — lists every site's stale quarantines.

  Reads assert on the ROW, never on `{:ok, _}`: a refused read under a filter
  policy comes back empty (or `NotFound`), so a shape-only assertion would pass
  with the grant removed. The fail-closed tests assert on what a filtered read
  could NOT produce — a `Forbidden`, or a raise.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Media
  alias KilnCMS.Media.{AVStripWorker, AVWorker, QuarantineReaper, Regeneration, VariantWorker}
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])
  defp system, do: Media.system()
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "msa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # Seeded around every policy, with no blob behind it: each worker below
  # stops at "the original is not there", which is where a GRANTED read ends
  # up — the contrast with a refused one.
  defp item!(attrs \\ %{}) do
    n = uniq()

    Ash.Seed.seed!(
      MediaItem,
      Map.merge(
        %{
          filename: "m-#{n}.png",
          content_type: "image/png",
          storage_key: "msa-#{n}.png",
          url: "/uploads/msa-#{n}.png",
          org_id: org_id()
        },
        attrs
      )
    )
  end

  defp quarantined!(attrs \\ %{}) do
    n = uniq()

    item!(
      Map.merge(
        %{
          filename: "clip-#{n}.mp4",
          content_type: "video/mp4",
          storage_key: "msa-#{n}.mp4",
          url: "/uploads/msa-#{n}.mp4",
          quarantined: true
        },
        attrs
      )
    )
  end

  defp gated_image!, do: item!(%{audience: :member})

  defp aged(item) do
    old = DateTime.add(DateTime.utc_now(), -(QuarantineReaper.max_age_hours() + 1) * 3600)
    Ash.Seed.update!(item, %{inserted_at: old})
  end

  defp stored?(item), do: Ash.get(MediaItem, item.id, authorize?: false) |> elem(0) == :ok

  defp args(item), do: %{"media_item_id" => item.id, "org_id" => item.org_id}

  test "Media.system/0 is a system actor labelled :media" do
    assert %SystemActor{subsystem: :media} = Media.system()
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> Media.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :media} = Media.system()
    assert Media.with_actor(nil, &Media.system/0) == nil
  end

  describe "MediaItem — reads" do
    test "the system reads a quarantined item and a gated one; no actor reads neither" do
      quarantined = quarantined!()
      gated = gated_image!()

      for item <- [quarantined, gated] do
        assert {:ok, %{id: id}} = CMS.get_media_item(item.id, actor: system(), tenant: org_id())
        assert id == item.id
        assert {:error, _not_found} = CMS.get_media_item(item.id, tenant: org_id())
      end
    end

    test "the system lists stale quarantines across every site, and only stale ones" do
      other_org = org("msa-reaper-#{uniq()}").id
      here = aged(quarantined!())
      there = aged(quarantined!(%{org_id: other_org}))
      fresh = quarantined!()
      released = aged(item!())

      ids =
        DateTime.utc_now()
        |> DateTime.add(-QuarantineReaper.max_age_hours() * 3600)
        |> CMS.list_expired_quarantined_media!(actor: system())
        |> Enum.map(& &1.id)

      assert here.id in ids
      assert there.id in ids
      refute fresh.id in ids
      refute released.id in ids
    end

    test "nobody else lists them — no actor, an editor, not even an admin" do
      aged(quarantined!())

      for actor <- [nil, user(:editor), user(:admin)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.list_expired_quarantined_media(DateTime.utc_now(),
                   actor: actor,
                   authorize_with: :error
                 )

        assert {:ok, []} = CMS.list_expired_quarantined_media(DateTime.utc_now(), actor: actor)
      end
    end
  end

  describe "MediaItem — the pipeline's writes" do
    test "the system records what it derived and releases a quarantine" do
      item = item!()

      assert {:ok, %{width: 640, variants: %{"thumb" => _}}} =
               CMS.record_media_processing(
                 item,
                 %{width: 640, height: 480, variants: %{"thumb" => %{"key" => "t.webp"}}},
                 actor: system(),
                 tenant: org_id()
               )

      assert {:ok, %{quarantined: false, byte_size: 42}} =
               CMS.release_media_quarantine(quarantined!(), %{byte_size: 42},
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "the system cannot :update (gate), edit metadata or soft-delete an item" do
      item = item!()

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_media_item(item, %{width: 1}, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_media_item_metadata(item, %{alt: "x"},
                 actor: system(),
                 tenant: org_id()
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_media_item(item, actor: system(), tenant: org_id())

      assert stored?(item)
    end

    test "an editor reaches neither of the pipeline's writes; no actor neither" do
      for actor <- [user(:editor), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.record_media_processing(item!(), %{width: 1},
                   actor: actor,
                   tenant: org_id()
                 )

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.release_media_quarantine(quarantined!(), %{},
                   actor: actor,
                   tenant: org_id()
                 )
      end
    end

    test "the system purges a quarantined item, but never a released one" do
      quarantined = quarantined!()
      assert :ok = CMS.purge_media_item(quarantined, actor: system(), tenant: org_id())
      refute stored?(quarantined)

      released = item!()

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.purge_media_item(released, actor: system(), tenant: org_id())

      assert stored?(released)
    end

    test "the system cannot soft-delete even a quarantined item — `purge` is its only delete" do
      quarantined = quarantined!()

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_media_item(quarantined, actor: system(), tenant: org_id())

      assert %{archived_at: nil} = Ash.get!(MediaItem, quarantined.id, authorize?: false)
    end

    test "an editor purges nothing, quarantined or not" do
      editor = user(:editor)
      quarantined = quarantined!()

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.purge_media_item(quarantined, actor: editor, tenant: org_id())

      assert stored?(quarantined)
    end
  end

  describe ~s(fail closed: a lost grant never reads as "gone" or "nothing to do") do
    test "the strip worker fails the job instead of leaving the upload to the reaper" do
      item = quarantined!()

      # Granted: the read succeeds and the job stops at the missing blob.
      assert capture_log(fn -> assert :ok = perform_job(AVStripWorker, args(item)) end) =~
               "private blob unreadable"

      log =
        capture_log(fn ->
          assert {:error, %Ash.Error.Forbidden{}} =
                   Media.with_actor(nil, fn -> perform_job(AVStripWorker, args(item)) end)
        end)

      assert log =~ "refused a read"
      assert %{quarantined: true} = Ash.get!(MediaItem, item.id, authorize?: false)
    end

    test "the variant worker fails the job rather than skip a gated image" do
      item = gated_image!()
      assert :ok = perform_job(VariantWorker, args(item))

      assert {:error, %Ash.Error.Forbidden{}} =
               Media.with_actor(nil, fn -> perform_job(VariantWorker, args(item)) end)
    end

    test "the A/V worker fails the job rather than skip a gated item" do
      item = item!(%{content_type: "video/mp4", audience: :member})
      assert :ok = perform_job(AVWorker, args(item))

      assert {:error, %Ash.Error.Forbidden{}} =
               Media.with_actor(nil, fn -> perform_job(AVWorker, args(item)) end)
    end

    test "a refused poster revocation raises rather than leave a public still up" do
      item = item!(%{audience: :member, variants: %{"poster" => %{"key" => "p-#{uniq()}.jpg"}}})

      assert_raise MatchError, fn ->
        Media.with_actor(nil, fn -> AVWorker.revoke_poster_if_gated(item, org_id()) end)
      end

      assert :ok = AVWorker.revoke_poster_if_gated(item, org_id())
      assert %{variants: variants} = Ash.get!(MediaItem, item.id, authorize?: false)
      assert variants == %{}
    end

    test "the regeneration scan raises rather than skip what it cannot see" do
      gated_image!()
      assert %{scanned: scanned} = Regeneration.run(org_id())
      assert scanned >= 1

      assert_raise Ash.Error.Forbidden, fn ->
        Media.with_actor(nil, fn -> Regeneration.run(org_id()) end)
      end
    end

    test "the reaper raises rather than report a clean sweep" do
      item = aged(quarantined!())

      assert_raise Ash.Error.Forbidden, fn ->
        Media.with_actor(nil, &QuarantineReaper.run/0)
      end

      assert stored?(item)

      capture_log(fn -> assert QuarantineReaper.run() >= 1 end)
      refute stored?(item)
    end
  end
end
