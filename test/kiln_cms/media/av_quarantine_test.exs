defmodule KilnCMS.Media.AVQuarantineTest do
  @moduledoc """
  The deferred A/V metadata strip behind a quarantine (#1122): `Ingest` stages
  the upload privately as `quarantined: true`, every non-editor read surface
  refuses it, `AVStripWorker` promotes and releases it, and `QuarantineReaper`
  removes one that never completes.

  `async: false` — swaps `:av_metadata_strip` (VM-global) and the Local storage
  roots.
  """
  use KilnCMSWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Media.{AVStripWorker, Ingest, QuarantineReaper}
  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_q_#{System.unique_integer([:positive])}")

    private_root =
      Path.join(System.tmp_dir!(), "kiln_q_priv_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(private_root)

    Application.put_env(:kiln_cms, KilnCMS.Storage.Local,
      root: root,
      private_root: private_root,
      base_url: "/uploads"
    )

    previous_mode = Application.get_env(:kiln_cms, :av_metadata_strip, :sync)
    previous_require = Application.fetch_env(:kiln_cms, :require_av_metadata_strip)
    Application.put_env(:kiln_cms, :av_metadata_strip, :deferred)
    Application.put_env(:kiln_cms, :require_av_metadata_strip, false)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(private_root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
      Application.put_env(:kiln_cms, :av_metadata_strip, previous_mode)

      case previous_require do
        {:ok, value} -> Application.put_env(:kiln_cms, :require_av_metadata_strip, value)
        :error -> Application.delete_env(:kiln_cms, :require_av_metadata_strip)
      end
    end)

    :ok
  end

  defp user(attrs) do
    email = "q-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now()
        },
        attrs
      )
    )

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => "password123456"
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Minimal ISO-BMFF: a 4-byte size, `ftyp`, then an allowlisted brand. Sniffs
  # as video/mp4; ffmpeg cannot remux it (no `moov`), which is the point for
  # the "could not strip" branches below.
  defp mp4_path do
    path = Path.join(System.tmp_dir!(), "q-#{System.unique_integer([:positive])}.mp4")
    File.write!(path, <<0, 0, 0, 24>> <> "ftyp" <> "isom" <> String.duplicate("\0", 64))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp quarantined_upload!(actor) do
    {:ok, item} = Ingest.store_file(mp4_path(), "clip.mp4", actor: actor)
    item
  end

  defp strip_job_args(item),
    do: %{"media_item_id" => item.id, "org_id" => item.org_id, "ext" => ".mp4"}

  describe "Ingest under :deferred" do
    test "stages the upload privately as quarantined, queues the strip and NOT derivation" do
      actor = user(%{role: :editor})
      item = quarantined_upload!(actor)

      assert item.quarantined
      assert item.content_type == "video/mp4"

      # The bytes are in PRIVATE storage only; the public key — which `url`
      # points at — has nothing behind it.
      assert {:ok, _bytes} = Storage.fetch_private(item.storage_key)
      assert {:error, _} = Storage.fetch(item.storage_key)

      # The strip job is queued, the derivation jobs are not (they would fetch
      # a public key with nothing behind it).
      assert [%{worker: "KilnCMS.Media.AVStripWorker", args: args}] =
               all_enqueued(worker: AVStripWorker)

      assert args["media_item_id"] == item.id
      assert all_enqueued(worker: KilnCMS.Media.AVWorker) == []
    end

    test ":sync (the default) is unchanged — the item lands released, publicly stored" do
      Application.put_env(:kiln_cms, :av_metadata_strip, :sync)
      actor = user(%{role: :editor})

      capture_log(fn ->
        {:ok, item} = Ingest.store_file(mp4_path(), "clip.mp4", actor: actor)
        refute item.quarantined
        assert {:ok, _} = Storage.fetch(item.storage_key)
        assert all_enqueued(worker: AVStripWorker) == []
      end)
    end

    test "an image is never quarantined, whatever the mode" do
      actor = user(%{role: :editor})
      png = Path.join(System.tmp_dir!(), "q-#{System.unique_integer([:positive])}.png")
      # 1x1 PNG.
      File.write!(
        png,
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        )
      )

      on_exit(fn -> File.rm(png) end)

      {:ok, item} = Ingest.store_file(png, "dot.png", actor: actor)
      refute item.quarantined
    end
  end

  defp all_enqueued(opts) do
    worker = Keyword.fetch!(opts, :worker) |> inspect()

    Oban.Job
    |> KilnCMS.Repo.all()
    |> Enum.filter(&(&1.worker == worker and &1.state in ["available", "scheduled"]))
  end

  describe "a quarantined item is unreachable from every non-editor read surface" do
    test "the read policy hides it from anonymous and audience-holding readers, not editors" do
      editor = user(%{role: :editor})
      item = quarantined_upload!(editor)

      # Editors see it (the library shows it as processing).
      assert {:ok, %{quarantined: true}} = CMS.get_media_item(item.id, actor: editor)

      # Anonymous — a `:public` item would be readable — is refused.
      assert {:error, _} = CMS.get_media_item(item.id, actor: nil)

      assert CMS.list_media_items!(actor: nil) |> Enum.map(& &1.id) |> Enum.member?(item.id) ==
               false

      # An audience-holding viewer, likewise (`MediaInAudience` excludes it).
      viewer = user(%{role: :viewer, audiences: [:member]})
      assert {:error, _} = CMS.get_media_item(item.id, actor: viewer)
    end

    test "/media/:id/download and /stream are 404 for everyone, even an admin", %{conn: conn} do
      admin = user(%{role: :admin})
      item = quarantined_upload!(admin)

      conn = log_in(conn, admin)
      assert conn |> get("/media/#{item.id}/download") |> response(404)
      assert conn |> get("/media/#{item.id}/stream") |> response(404)
    end
  end

  describe "AVStripWorker" do
    # ffmpeg is present on this host but cannot remux the minimal fixture, so
    # the strip fails as "this file could not be remuxed" — the branch the sync
    # path also has, applied one step later.
    @tag :ffmpeg
    test "promotes an un-remuxable upload as it arrived when the strip is not required, releases, derives" do
      editor = user(%{role: :editor})
      item = quarantined_upload!(editor)

      log =
        capture_log(fn ->
          assert :ok = AVStripWorker.perform(%Oban.Job{args: strip_job_args(item)})
        end)

      assert log =~ "container metadata intact"

      released = CMS.get_media_item!(item.id, actor: editor)
      refute released.quarantined
      # Promoted to the public key, private copy gone.
      assert {:ok, _} = Storage.fetch(item.storage_key)
      assert {:error, _} = Storage.fetch_private(item.storage_key)
      # Now readable anonymously, and derivation is queued.
      assert {:ok, _} = CMS.get_media_item(item.id, actor: nil)
      assert [_] = all_enqueued(worker: KilnCMS.Media.AVWorker)
    end

    @tag :ffmpeg
    test "REFUSES under require_av_metadata_strip: row purged, private blob deleted" do
      Application.put_env(:kiln_cms, :require_av_metadata_strip, true)
      editor = user(%{role: :editor})
      item = quarantined_upload!(editor)

      log =
        capture_log(fn ->
          assert :ok = AVStripWorker.perform(%Oban.Job{args: strip_job_args(item)})
        end)

      assert log =~ "refused"
      assert {:error, _} = CMS.get_media_item(item.id, actor: editor)
      assert {:error, _} = Storage.fetch_private(item.storage_key)
      assert {:error, _} = Storage.fetch(item.storage_key)
      assert all_enqueued(worker: KilnCMS.Media.AVWorker) == []
    end

    test "is a no-op for an item that is gone or already released" do
      editor = user(%{role: :editor})
      item = quarantined_upload!(editor)

      # Released by someone else (a duplicate job, say): nothing to do, and the
      # public key is not touched.
      {:ok, _} =
        item
        |> Ash.Changeset.for_update(:release_quarantine, %{}, authorize?: false)
        |> Ash.update()

      assert :ok = AVStripWorker.perform(%Oban.Job{args: strip_job_args(item)})
      assert {:error, _} = Storage.fetch(item.storage_key)

      assert :ok =
               AVStripWorker.perform(%Oban.Job{
                 args: %{"media_item_id" => Ash.UUID.generate(), "org_id" => item.org_id}
               })
    end

    test "release_quarantine is system-only: an editor cannot release their own upload" do
      editor = user(%{role: :editor})
      item = quarantined_upload!(editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:release_quarantine, %{}, actor: editor)
               |> Ash.update()

      # Nor smuggle it through the ordinary update.
      assert {:error, _} = CMS.update_media_item(item, %{quarantined: false}, actor: editor)
      assert CMS.get_media_item!(item.id, actor: editor).quarantined
    end
  end

  describe "QuarantineReaper" do
    test "removes a quarantined item older than the window, and leaves a fresh one" do
      editor = user(%{role: :editor})
      stale = quarantined_upload!(editor)
      fresh = quarantined_upload!(editor)

      old =
        DateTime.add(DateTime.utc_now(), -(QuarantineReaper.max_age_hours() + 1) * 3600, :second)

      Ash.Seed.update!(stale, %{inserted_at: old})

      log = capture_log(fn -> assert QuarantineReaper.run() == 1 end)
      assert log =~ "Reaping quarantined media #{stale.id}"

      assert {:error, _} = CMS.get_media_item(stale.id, actor: editor)
      assert {:error, _} = Storage.fetch_private(stale.storage_key)

      assert {:ok, %{quarantined: true}} = CMS.get_media_item(fresh.id, actor: editor)
      assert {:ok, _} = Storage.fetch_private(fresh.storage_key)
    end

    test "never touches a released item, however old" do
      editor = user(%{role: :editor})

      capture_log(fn ->
        Application.put_env(:kiln_cms, :av_metadata_strip, :sync)
        {:ok, item} = Ingest.store_file(mp4_path(), "clip.mp4", actor: editor)
        old = DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
        Ash.Seed.update!(item, %{inserted_at: old})

        assert QuarantineReaper.run() == 0
        assert {:ok, _} = CMS.get_media_item(item.id, actor: editor)
      end)
    end
  end
end
