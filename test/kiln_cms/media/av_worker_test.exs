defmodule KilnCMS.Media.AVWorkerTest do
  @moduledoc """
  The A/V background worker (#494).

  ffmpeg is a *system* dependency this application doesn't declare, so the
  behaviour that has to hold on every machine — CI included — is the
  degraded one: the job succeeds, writes nothing, and never crashes. That is
  what most of this file pins.

  The exception is `revoke_poster_if_gated/2`, which is a security property
  rather than a nice-to-have and is reachable without ffmpeg by writing the
  poster the worker would have written.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Media.AVWorker
  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_avw_#{System.unique_integer([:positive])}")

    private_root =
      Path.join(System.tmp_dir!(), "kiln_avw_priv_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(private_root)

    Application.put_env(:kiln_cms, KilnCMS.Storage.Local,
      root: root,
      private_root: private_root,
      base_url: "/uploads"
    )

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(private_root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    %{root: root, private_root: private_root}
  end

  defp put(key, contents) do
    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}")
    File.write!(src, contents)
    {:ok, ^key} = Storage.store(key, src)
    key
  end

  defp video!(attrs \\ %{}) do
    key = Storage.generate_key("clip.mp4")
    put(key, "fake mp4 bytes")

    CMS.create_media_item!(
      Map.merge(
        %{
          filename: "clip.mp4",
          content_type: "video/mp4",
          storage_key: key,
          url: Storage.url(key)
        },
        attrs
      ),
      authorize?: false
    )
  end

  defp perform(item) do
    AVWorker.perform(%Oban.Job{args: %{"media_item_id" => item.id, "org_id" => item.org_id}})
  end

  describe "degrading without ffmpeg" do
    test "an unprobeable file leaves the item untouched and the job successful" do
      item = video!()

      assert :ok = perform(item)

      reloaded = CMS.get_media_item!(item.id, authorize?: false)
      assert reloaded.duration_seconds == nil
      assert reloaded.variants == %{}
      # The upload itself is intact and still playable.
      assert reloaded.storage_key == item.storage_key
    end

    test "a since-deleted item is a no-op, not a crash" do
      item = video!()
      :ok = CMS.purge_media_item(item, authorize?: false)

      assert :ok = perform(item)
    end

    test "a missing blob is a no-op, not a crash" do
      item = video!()
      :ok = Storage.delete(item.storage_key)

      assert :ok = perform(item)
    end

    test "an item with no storage_key at all is a no-op" do
      item =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{filename: "x.mp4", content_type: "video/mp4"})

      assert :ok = AVWorker.perform(%Oban.Job{args: %{"media_item_id" => item.id}})
    end
  end

  describe "a poster must never outlive the gate" do
    test "a poster written while the item was being gated is revoked, blob and all", %{
      root: root
    } do
      # The race: the worker reads `audience: :public` when the job starts,
      # then spends however long ffmpeg takes extracting a frame. An editor
      # gating the item in that window clears a `variants` map that is still
      # empty — and the worker then writes a PUBLIC still of a now-gated video
      # that nothing would ever delete.
      #
      # Simulated by doing exactly what the worker does after a slow probe:
      # store a poster blob and write it onto an item that has since been
      # gated, then run the revocation.
      item = video!()
      {:ok, gated} = CMS.update_media_item(item, %{audience: :member}, authorize?: false)
      assert gated.variants == %{}

      poster_key = Storage.generate_key("poster.jpg")
      put(poster_key, "a still frame")

      {:ok, leaked} =
        CMS.update_media_item(
          gated,
          %{
            variants: %{
              "poster" => %{
                "key" => poster_key,
                "url" => Storage.url(poster_key),
                "width" => 640,
                "height" => 360
              }
            }
          },
          authorize?: false
        )

      assert File.exists?(Path.join(root, poster_key))

      assert :ok = AVWorker.revoke_poster_if_gated(leaked, leaked.org_id)

      reloaded = CMS.get_media_item!(item.id, authorize?: false)
      assert reloaded.variants == %{}
      refute File.exists?(Path.join(root, poster_key))
    end

    test "a public item's poster is left alone" do
      poster = %{"key" => "k.jpg", "url" => "/uploads/k.jpg", "width" => 1, "height" => 1}
      item = video!(%{variants: %{"poster" => poster}})

      assert :ok = AVWorker.revoke_poster_if_gated(item, item.org_id)

      assert CMS.get_media_item!(item.id, authorize?: false).variants == %{"poster" => poster}
    end

    test "a gated item with no poster needs no write" do
      item = video!()
      {:ok, gated} = CMS.update_media_item(item, %{audience: :member}, authorize?: false)

      assert :ok = AVWorker.revoke_poster_if_gated(gated, gated.org_id)
      assert CMS.get_media_item!(item.id, authorize?: false).variants == %{}
    end
  end
end
