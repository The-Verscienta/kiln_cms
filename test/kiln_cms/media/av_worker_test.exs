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

  The `:ffmpeg` block at the end is the other half, and it needs a **real**
  file: the fixture above is a plausible-looking byte string that ffprobe
  refuses, which is exactly right for the degraded cases and useless for the
  successful one. It generates a 1-second 64x48 clip with ffmpeg itself
  (~3 KB), so everything the worker writes on a good probe — duration,
  dimensions, and a poster stored under a real key — is asserted against a
  file ffprobe genuinely measured.
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

  test "the job declares a finite ceiling" do
    # Not decoration: closing an Erlang port does not signal the OS child, so
    # an ffmpeg spinning on CPU is bounded by its own `-timelimit` and this is
    # what stops the *job* holding a `:media` queue slot behind it. A change
    # here is a decision, so it is pinned exactly.
    assert AVWorker.timeout(%Oban.Job{}) == :timer.minutes(5)
  end

  describe "with ffmpeg present" do
    # A real, tiny clip: `testsrc` at 64x48 for one second is ~3 KB and takes
    # milliseconds to produce. The dimensions are deliberately not a common
    # default, so an assertion on 64x48 cannot pass by coincidence.
    defp real_video!(attrs \\ %{}) do
      src = Path.join(System.tmp_dir!(), "avw-real-#{System.unique_integer([:positive])}.mp4")

      {_out, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-hide_banner -loglevel error -y -f lavfi -i testsrc=size=64x48:rate=10:duration=1
             -pix_fmt yuv420p) ++ [src],
          stderr_to_stdout: true
        )

      on_exit(fn -> File.rm(src) end)

      key = Storage.generate_key("clip.mp4")
      {:ok, ^key} = Storage.store(key, src)

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

    @tag :ffmpeg
    test "a good probe writes duration, dimensions and a poster" do
      item = real_video!()

      assert :ok = perform(item)

      written = CMS.get_media_item!(item.id, authorize?: false)
      # ffprobe reports the container's duration, which for a generated clip
      # is a shade over the requested second — assert the neighbourhood, not
      # an exact float.
      assert_in_delta written.duration_seconds, 1.0, 0.5
      assert written.width == 64
      assert written.height == 48

      assert %{"poster" => %{"key" => key, "url" => url, "width" => 64, "height" => 48}} =
               written.variants

      # The poster is a real stored blob, not just a row that claims one.
      assert {:ok, bytes} = Storage.fetch(key)
      assert byte_size(bytes) > 0
      assert url =~ key
    end

    @tag :ffmpeg
    test "a gated video is measured but gets no poster" do
      # A poster renders as a plain <img> from public storage, so extracting
      # one for a members-only video would publish a still of it. The
      # measurements are not secret and are still written.
      # `audience` is not a create input — gating is an update, and it moves
      # the blob to private storage on the way (`MigrateMediaStorage`), so this
      # also exercises the worker's private download.
      {:ok, item} = CMS.update_media_item(real_video!(), %{audience: :member}, authorize?: false)

      assert :ok = perform(item)

      written = CMS.get_media_item!(item.id, authorize?: false)
      assert written.width == 64
      assert (written.variants || %{}) == %{}
    end

    @tag :ffmpeg
    test "a second run does not erase what the first measured" do
      # `max_attempts: 3`, so a retry re-probes. The put_* clauses omit rather
      # than nil a measurement they could not take, and this is the property
      # that protects: running twice must not downgrade the row.
      item = real_video!()
      assert :ok = perform(item)
      first = CMS.get_media_item!(item.id, authorize?: false)

      assert :ok = perform(CMS.get_media_item!(item.id, authorize?: false))
      second = CMS.get_media_item!(item.id, authorize?: false)

      assert second.width == first.width
      assert second.height == first.height
      assert second.duration_seconds == first.duration_seconds
      assert map_size(second.variants) == 1
    end

    @tag :ffmpeg
    test "audio gets a duration and no dimensions" do
      src = Path.join(System.tmp_dir!(), "avw-tone-#{System.unique_integer([:positive])}.m4a")

      {_out, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=1) ++ [src],
          stderr_to_stdout: true
        )

      on_exit(fn -> File.rm(src) end)

      key = Storage.generate_key("tone.m4a")
      {:ok, ^key} = Storage.store(key, src)

      item =
        CMS.create_media_item!(
          %{
            filename: "tone.m4a",
            content_type: "audio/mp4",
            storage_key: key,
            url: Storage.url(key)
          },
          authorize?: false
        )

      assert :ok = perform(item)

      written = CMS.get_media_item!(item.id, authorize?: false)
      assert_in_delta written.duration_seconds, 1.0, 0.5
      # Audio has no dimensions, and a poster frame is meaningless for it.
      assert is_nil(written.width)
      assert is_nil(written.height)
      assert (written.variants || %{}) == %{}
    end
  end
end
