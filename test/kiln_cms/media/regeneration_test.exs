defmodule KilnCMS.Media.RegenerationTest do
  @moduledoc """
  Bulk variant regeneration (#473): what a rollout run skips, what it picks up,
  and the deduplication that stops a double-click doubling the work.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Media.Regeneration

  defp uniq, do: System.unique_integer([:positive])

  defp media(attrs \\ %{}) do
    Ash.Seed.seed!(
      MediaItem,
      Map.merge(
        %{
          filename: "f-#{uniq()}.jpg",
          content_type: "image/jpeg",
          storage_key: "k-#{uniq()}.jpg",
          url: "/uploads/k-#{uniq()}.jpg",
          size: 1000
        },
        attrs
      )
    )
  end

  defp variant(url, content_type),
    do: %{"url" => url, "width" => 400, "height" => 200, "content_type" => content_type}

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp queued_ids do
    KilnCMS.Repo.all(
      from(j in Oban.Job,
        where: j.worker == "KilnCMS.Media.VariantWorker",
        select: fragment("? ->> 'media_item_id'", j.args)
      )
    )
  end

  describe "current?/1" do
    test "an item carrying every configured alternate is up to date" do
      item =
        media(%{
          variants: %{
            "thumb" => variant("/t.jpg", "image/jpeg"),
            "thumb.webp" => variant("/t.webp", "image/webp")
          }
        })

      assert Regeneration.current?(item)
    end

    test "an item missing an alternate is not" do
      item = media(%{variants: %{"thumb" => variant("/t.jpg", "image/jpeg")}})

      refute Regeneration.current?(item)
    end

    # A WebP upload's source-format variant IS the WebP one — it has no suffix,
    # and demanding `thumb.webp` as well would reprocess it forever.
    test "a source format that is also a configured alternate counts" do
      item = media(%{variants: %{"thumb" => variant("/t.webp", "image/webp")}})

      assert Regeneration.current?(item)
    end

    # An unprocessed item (no recorded width) is exactly what a rollout wants to
    # catch — mid-flight, or a run that failed.
    test "an unprocessed item is never up to date" do
      refute Regeneration.current?(media(%{variants: %{}}))
      refute Regeneration.current?(media())
    end

    # …but an item that WAS processed and legitimately produced nothing — a
    # source narrower than every responsive target — must count as current, or
    # the missing-only run re-decodes every icon in the library for ever.
    test "a processed image too small for any variant is up to date" do
      assert Regeneration.current?(media(%{variants: %{}, width: 150, height: 100}))
    end

    # A GIF gets no alternates by design (its variants are flattened stills), so
    # demanding one would never converge either.
    test "an animated source is up to date without alternates" do
      item =
        media(%{
          content_type: "image/gif",
          filename: "a-#{uniq()}.gif",
          variants: %{"thumb" => variant("/t.gif", "image/gif")}
        })

      assert Regeneration.current?(item)
    end
  end

  describe "run/2" do
    test "a rollout enqueues only what's missing" do
      stale = media(%{variants: %{"thumb" => variant("/t.jpg", "image/jpeg")}})

      _current =
        media(%{
          variants: %{
            "thumb" => variant("/t.jpg", "image/jpeg"),
            "thumb.webp" => variant("/t.webp", "image/webp")
          }
        })

      assert %{enqueued: 1, scanned: 2} = Regeneration.run(org_id())
      assert queued_ids() == [stale.id]
    end

    # After a quality or width change the variants are present but wrong, so
    # "missing" is the wrong question.
    test "only_missing?: false enqueues everything" do
      media(%{
        variants: %{
          "thumb" => variant("/t.jpg", "image/jpeg"),
          "thumb.webp" => variant("/t.webp", "image/webp")
        }
      })

      assert %{enqueued: 1, scanned: 1} = Regeneration.run(org_id(), only_missing?: false)
    end

    test "a second run inside the unique window doesn't double the work" do
      media(%{variants: %{"thumb" => variant("/t.jpg", "image/jpeg")}})

      assert %{enqueued: 1} = Regeneration.run(org_id())
      assert %{enqueued: 0} = Regeneration.run(org_id())
      assert length(queued_ids()) == 1
    end

    test "non-image media is never touched" do
      media(%{content_type: "application/pdf", filename: "doc-#{uniq()}.pdf"})

      assert %{enqueued: 0, scanned: 0} = Regeneration.run(org_id())
    end

    # Oban's default unique states include `:completed`, so without a
    # discriminating arg every image uploaded in the previous hour would collide
    # with its own upload job and be silently skipped.
    test "a completed upload job doesn't suppress a regeneration of the same item" do
      item = media(%{variants: %{"thumb" => variant("/t.jpg", "image/jpeg")}})

      # Exactly what MediaLive enqueues on upload, then completed.
      {:ok, upload_job} =
        %{media_item_id: item.id, org_id: org_id()}
        |> KilnCMS.Media.VariantWorker.new()
        |> Oban.insert()

      KilnCMS.Repo.update_all(
        from(j in Oban.Job, where: j.id == ^upload_job.id),
        set: [state: "completed"]
      )

      assert %{enqueued: 1} = Regeneration.run(org_id())
    end

    # `:media` is a concurrency-3 queue shared with upload processing; Oban
    # fetches by priority then id, so an un-deprioritised bulk run would sit
    # ahead of every subsequent upload for hours.
    test "regeneration jobs run at the lowest priority" do
      media(%{variants: %{"thumb" => variant("/t.jpg", "image/jpeg")}})

      Regeneration.run(org_id())

      assert [9] =
               KilnCMS.Repo.all(
                 from(j in Oban.Job,
                   where: j.worker == "KilnCMS.Media.VariantWorker",
                   select: j.priority
                 )
               )
    end
  end
end
