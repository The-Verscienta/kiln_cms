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
      # `full.webp` included because every processed item has had one since #473
      # — `build_full/2` is unconditional on size. A fixture without it is a
      # shape the pipeline does not produce, and since #1000 it is correctly
      # reported as needing a run.
      item =
        media(%{
          variants: %{
            "thumb" => variant("/t.jpg", "image/jpeg"),
            "thumb.webp" => variant("/t.webp", "image/webp"),
            "full.webp" => variant("/f.webp", "image/webp")
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
      # A WebP upload: `full_alternates/1` excludes the source's own format, so
      # with WebP the only configured alternate there is no `full.*` to want.
      previous = Application.get_env(:kiln_cms, :image_variants, [])
      Application.put_env(:kiln_cms, :image_variants, Keyword.put(previous, :formats, [:webp]))
      on_exit(fn -> Application.put_env(:kiln_cms, :image_variants, previous) end)

      item =
        media(%{
          content_type: "image/webp",
          variants: %{"thumb" => variant("/t.webp", "image/webp")}
        })

      assert Regeneration.current?(item)
    end

    # #1000. The `base_labels` sweep only asks whether the labels that ALREADY
    # exist carry every format, so an item missing the `full` label entirely
    # passed it — never being asked about the one write that is unconditional.
    # `full.webp` is the largest of the nine writes and the first to fail on
    # ENOSPC or an encoder OOM, and `write/4` swallows that into a log line.
    test "an item that lost only its full-size alternate is not up to date" do
      item =
        media(%{
          variants: %{
            "thumb" => variant("/t.jpg", "image/jpeg"),
            "thumb.webp" => variant("/t.webp", "image/webp"),
            "medium" => variant("/m.jpg", "image/jpeg"),
            "medium.webp" => variant("/m.webp", "image/webp")
          }
        })

      refute Regeneration.current?(item)
    end

    # The other half, and the reason a bare key check would not do: a source
    # past libvips' WebP dimension ceiling can NEVER gain a `full.webp`, and
    # re-decoding it on every run is the standing tax this module exists to
    # avoid. A recorded failure is what tells the two apart.
    test "an alternate recorded as impossible does not keep re-enqueuing" do
      item =
        media(%{
          variants: %{
            "thumb" => variant("/t.jpg", "image/jpeg"),
            "thumb.webp" => variant("/t.webp", "image/webp")
          },
          variant_failures: %{"full.webp" => "encoder refused this source"}
        })

      assert Regeneration.current?(item)
    end

    test "a recorded failure for one format does not excuse another" do
      previous = Application.get_env(:kiln_cms, :image_variants, [])

      Application.put_env(
        :kiln_cms,
        :image_variants,
        Keyword.put(previous, :formats, [:webp, :avif])
      )

      on_exit(fn -> Application.put_env(:kiln_cms, :image_variants, previous) end)

      # NO `full.*` key at all, so `full` is not one of the `base_labels` and the
      # existing sweep passes on `thumb` alone. That leaves the full-size check
      # as the only thing deciding the answer — with a `full.webp` present
      # instead, the sweep would catch the missing `full.avif` itself and this
      # would pass whether or not the new check exists.
      item =
        media(%{
          variants: %{
            "thumb" => variant("/t.jpg", "image/jpeg"),
            "thumb.webp" => variant("/t.webp", "image/webp"),
            "thumb.avif" => variant("/t.avif", "image/avif")
          },
          variant_failures: %{"full.webp" => "encoder refused this source"}
        })

      # WebP is excused by the record; AVIF is neither present nor impossible.
      refute Regeneration.current?(item)
    end

    # A WebP upload with two configured formats. `build_full/2` never writes a
    # SOURCE-format full — the original is the source-format full — so the item
    # gets `full.avif` and no `full.webp`. That made `full` a base label, and the
    # sweep then demanded the `full.webp` that will never exist: a permanent
    # re-enqueue. `full` is excluded from the sweep now, because `full_present?/1`
    # owns it and the two rules disagreed.
    test "a source-format upload does not demand a full it will never be given" do
      previous = Application.get_env(:kiln_cms, :image_variants, [])

      Application.put_env(
        :kiln_cms,
        :image_variants,
        Keyword.put(previous, :formats, [:webp, :avif])
      )

      on_exit(fn -> Application.put_env(:kiln_cms, :image_variants, previous) end)

      item =
        media(%{
          content_type: "image/webp",
          variants: %{
            "thumb" => variant("/t.webp", "image/webp"),
            "thumb.avif" => variant("/t.avif", "image/avif"),
            "full.avif" => variant("/f.avif", "image/avif")
          }
        })

      assert Regeneration.current?(item)
    end

    # The empty-variants clause has to consult the failure record too: a source
    # narrower than every responsive target produces no variants at all, so if
    # its one full alternate is also impossible there is genuinely nothing left
    # to do — and answering "not current" re-decodes it on every run for ever.
    test "a tiny source whose only alternate is impossible is up to date" do
      item =
        media(%{
          variants: %{},
          width: 150,
          height: 100,
          variant_failures: %{"full.webp" => "encoder refused this source"}
        })

      assert Regeneration.current?(item)
    end

    # An unprocessed item (no recorded width) is exactly what a rollout wants to
    # catch — mid-flight, or a run that failed.
    test "an unprocessed item is never up to date" do
      refute Regeneration.current?(media(%{variants: %{}}))
      refute Regeneration.current?(media())
    end

    # #919: this used to assert the opposite. Before #473 a source narrower than
    # every responsive target legitimately produced nothing, so declaring it
    # current was what stopped the missing-only run re-decoding every icon for
    # ever. `build_full/2` is unconditional on size, so a non-GIF source now
    # yields at least one `full.<format>` — and calling it current made the
    # documented rollout default skip it permanently. `image_processor_test.exs`
    # asserts the same 150px input yields `["full.webp"]`; the two suites
    # contradicted each other, and this is the side that was wrong.
    test "a processed image too small for the responsive ladder still needs its alternates" do
      refute Regeneration.current?(
               media(%{variants: %{}, width: 150, height: 100, content_type: "image/jpeg"})
             )
    end

    # The convergence guarantee the old assertion was protecting, stated where it
    # is actually true: nothing more to add means current, whatever the size.
    test "a processed image is up to date when no alternate is configured for it" do
      previous = Application.get_env(:kiln_cms, :image_variants, [])
      Application.put_env(:kiln_cms, :image_variants, Keyword.put(previous, :formats, [:webp]))
      on_exit(fn -> Application.put_env(:kiln_cms, :image_variants, previous) end)

      # A WebP source with WebP as the only configured alternate: `build_full/2`
      # rejects the source's own format, so a run would add nothing.
      assert Regeneration.current?(
               media(%{
                 variants: %{},
                 width: 150,
                 height: 100,
                 content_type: "image/webp",
                 filename: "s-#{uniq()}.webp"
               })
             )
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
            "thumb.webp" => variant("/t.webp", "image/webp"),
            "full.webp" => variant("/f.webp", "image/webp")
          }
        })

      assert %{enqueued: 1, scanned: 2} = Regeneration.run(org_id())
      assert queued_ids() == [stale.id]
    end

    # THROUGH `run/2`, not `current?/1` — the bug this pins was invisible to a
    # direct call. `run/2` reads rows through `fetch_batch/2`'s `select/2`, and
    # an unselected Ash attribute arrives as `%Ash.NotLoaded{}`, which is
    # truthy: `Map.has_key?/2` then answers false for every format and every
    # recorded failure silently reads as "never recorded". Seeded structs have
    # every attribute loaded, so the `current?/1` tests above all passed while
    # the feature did nothing in production.
    test "a recorded failure is honoured by an actual run, not just by current?/1" do
      media(%{
        variants: %{
          "thumb" => variant("/t.jpg", "image/jpeg"),
          "thumb.webp" => variant("/t.webp", "image/webp")
        },
        variant_failures: %{"full.webp" => "encoder refused this source"}
      })

      assert %{enqueued: 0, scanned: 1} = Regeneration.run(org_id())
    end

    test "an item missing its full alternate IS enqueued by a run" do
      # The other side of the same path: no record, so the work is still owed.
      stale =
        media(%{
          variants: %{
            "thumb" => variant("/t.jpg", "image/jpeg"),
            "thumb.webp" => variant("/t.webp", "image/webp")
          }
        })

      assert %{enqueued: 1, scanned: 1} = Regeneration.run(org_id())
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
