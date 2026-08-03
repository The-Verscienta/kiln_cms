defmodule KilnCMS.OEmbedPipelineTest do
  @moduledoc """
  Save → enqueue → resolve → render, end to end (#489).

  This file exists because its absence is what let the first attempt at this
  feature ship inert. Every unit either side of the write path passed:
  `Provider.for_url/1` matched the URLs it was handed, the resolver decoded a
  stubbed response, the block rendered a card from metadata. What none of them
  covered was that `TypedBlocks.sanitize_attrs/1` rewrote the URL to a canonical
  player URL — or blanked it — *on the way in*, so nothing downstream ever saw
  an embeddable URL and no card could exist.

  The lesson generalizes past oEmbed: for anything shaped
  save → background work → read back, the end-to-end test is the one that has
  teeth. Unit tests on either side of a write path prove nothing about what the
  write path does to the value in between.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  require Ash.Query

  alias KilnCMS.Blocks.Embed
  alias KilnCMS.CMS
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.OEmbed.ResolveWorker

  @soundcloud "https://soundcloud.com/artist/a-track"
  @youtube "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.OEmbed, [])
    Application.put_env(:kiln_cms, KilnCMS.OEmbed, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.OEmbed, previous) end)

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "oembed-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    %{admin: admin}
  end

  defp stub(payload) do
    Req.Test.stub(KilnCMS.OEmbed, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

  defp page_with_embed(url, admin) do
    n = System.unique_integer([:positive])

    CMS.create_page!(
      %{
        title: "Embed #{n}",
        slug: "oembed-#{n}",
        blocks: [%{"_type" => "embed", "id" => Ash.UUID.generate(), "url" => url}]
      },
      actor: admin
    )
  end

  defp embed_block(page) do
    page.blocks |> TypedBlocks.to_typed() |> Enum.find(&match?(%Embed{}, &1))
  end

  describe "the URL survives the write path" do
    test "a non-framed provider URL is stored as typed, not blanked", %{admin: admin} do
      page = page_with_embed(@soundcloud, admin)

      # THE regression. This used to be "" — `safe_embed_url/1` knows two hosts
      # and blanks everything else — which made every provider but YouTube and
      # Vimeo unreachable and the whole feature inert.
      assert embed_block(page).url == @soundcloud
    end

    test "a YouTube watch URL keeps its watch form, not the player rewrite", %{admin: admin} do
      page = page_with_embed(@youtube, admin)

      # Also the regression: this used to be rewritten to
      # `https://www.youtube.com/embed/dQw4w9WgXcQ`, which matches no provider
      # pattern. Framing is decided at render, from this.
      assert embed_block(page).url == @youtube
    end

    test "a javascript: URL is still blanked", %{admin: admin} do
      page = page_with_embed("javascript:alert(1)", admin)

      # Blank, not "javascript:…". (`""` is dropped as an empty value on the way
      # into storage, so it reads back as nil — either way nothing survives.)
      assert blank?(embed_block(page).url)
    end

    test "an editor-supplied thumbnail_url off the provider CDN is blanked", %{admin: admin} do
      n = System.unique_integer([:positive])

      page =
        CMS.create_page!(
          %{
            title: "T #{n}",
            slug: "oembed-thumb-#{n}",
            blocks: [
              %{
                "_type" => "embed",
                "id" => Ash.UUID.generate(),
                "url" => @soundcloud,
                "title" => "Mine",
                "thumbnail_url" => "https://tracker.example/px.gif"
              }
            ]
          },
          actor: admin
        )

      # These are ordinary block scalars, so the editor's generic field renderer
      # offers them as inputs and a headless write can set them directly. Left
      # unfiltered, an arbitrary host reaches every reader's browser as an
      # `<img src>` in the fired artifact, which carries no CSP.
      assert embed_block(page).thumbnail_url in [nil, ""]
      assert embed_block(page).title == "Mine"
    end
  end

  describe "save enqueues, the worker resolves, and the card renders" do
    test "the whole path, for a provider that is not framed", %{admin: admin} do
      stub(%{
        "title" => "A track",
        "author_name" => "Artist",
        "provider_name" => "SoundCloud",
        "thumbnail_url" => "https://i1.sndcdn.com/x.jpg"
      })

      page = page_with_embed(@soundcloud, admin)

      # 1. The save enqueued exactly one resolve job for this document.
      assert [job] = all_enqueued(worker: ResolveWorker)
      assert job.args["id"] == page.id

      # 2. Running it writes the metadata back.
      assert :ok = perform_job(ResolveWorker, job.args)

      block = page.id |> CMS.get_page!(authorize?: false) |> embed_block()
      assert block.title == "A track"
      assert block.author_name == "Artist"
      assert block.provider_name == "SoundCloud"
      assert block.thumbnail_url == "https://i1.sndcdn.com/x.jpg"
      assert block.resolved_at =~ "T"

      # 3. And the block renders as a card rather than the bare figure.
      html = block |> KilnCMS.Blocks.render(:web) |> IO.iodata_to_binary()
      assert html =~ "kiln-embed-card"
      assert html =~ "A track"
      assert html =~ "https://i1.sndcdn.com/x.jpg"
    end

    test "resolving does not cut a version, fire a webhook, or bump lock_version",
         %{admin: admin} do
      stub(%{"title" => "A track", "provider_name" => "SoundCloud"})

      page = @soundcloud |> page_with_embed(admin) |> then(&CMS.publish_page!(&1, actor: admin))
      before = CMS.get_page!(page.id, authorize?: false)
      versions_before = version_count(page.id)

      [job] = all_enqueued(worker: ResolveWorker)
      assert :ok = perform_job(ResolveWorker, job.args)

      after_resolve = CMS.get_page!(page.id, authorize?: false)

      # `:update` would have done all three, and because the resolve is also
      # enqueued from `:autosave` the lock bump would land while an editor is
      # typing — their next autosave becomes a StaleRecord.
      assert after_resolve.lock_version == before.lock_version
      assert version_count(page.id) == versions_before

      # `updated_at` does move — Ash writes it on every update action and a
      # change cannot override it. Bounded rather than fixed: the resolve runs
      # seconds after the save that enqueued it, and a resolved document never
      # re-enqueues, so it never floats a document that nobody touched.
      assert DateTime.diff(after_resolve.updated_at, before.updated_at, :second) <= 5

      # The artifact is still re-fired, deliberately, so the card reaches
      # delivery — just not as a side effect of the metadata write.
      assert [_fire] = all_enqueued(worker: KilnCMS.Firing.FireWorker)
    end

    test "a provider that returns no title leaves the block bare and does not loop",
         %{admin: admin} do
      stub(%{"author_name" => "Artist"})

      page = page_with_embed(@soundcloud, admin)
      [job] = all_enqueued(worker: ResolveWorker)
      assert :ok = perform_job(ResolveWorker, job.args)

      block = page.id |> CMS.get_page!(authorize?: false) |> embed_block()

      # No title means no card, so nothing is written — which is what stops
      # write → re-enqueue → resolve → write from being a loop. Stamping
      # `resolved_at` on every attempt would have made every pass "a change".
      assert blank?(block.title)
      assert blank?(block.resolved_at)
      assert Enum.empty?(all_enqueued(worker: KilnCMS.Firing.FireWorker))
    end

    test "an already-resolved document enqueues nothing on re-save", %{admin: admin} do
      stub(%{"title" => "A track"})

      page = page_with_embed(@soundcloud, admin)
      [job] = all_enqueued(worker: ResolveWorker)
      assert :ok = perform_job(ResolveWorker, job.args)

      resolved = CMS.get_page!(page.id, authorize?: false)
      Oban.drain_queue(queue: :default)

      CMS.update_page!(resolved, %{title: "Renamed"}, actor: admin)

      # `needs_resolution?` requires a blank title, so a resolved document is
      # self-limiting — otherwise every save of every document with an embed
      # would re-fetch metadata it already had.
      assert Enum.empty?(all_enqueued(worker: ResolveWorker))
    end

    test "an editor's concurrent edit is not destroyed by the write-back", %{admin: admin} do
      page = page_with_embed(@soundcloud, admin)
      [job] = all_enqueued(worker: ResolveWorker)

      # The editor adds a block *during* the outbound fetch. The stub is where
      # that happens, so the ordering is real rather than simulated.
      Req.Test.stub(KilnCMS.OEmbed, fn conn ->
        page.id
        |> CMS.get_page!(authorize?: false)
        |> then(
          &CMS.update_page!(
            &1,
            %{
              blocks:
                TypedBlocks.to_legacy(TypedBlocks.to_typed(&1.blocks)) ++
                  [%{type: :heading, content: "Added while fetching", data: %{"level" => 2}}]
            },
            actor: admin
          )
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"title" => "A track"}))
      end)

      assert :ok = perform_job(ResolveWorker, job.args)

      blocks = page.id |> CMS.get_page!(authorize?: false) |> Map.fetch!(:blocks)
      typed = TypedBlocks.to_typed(blocks)

      # A read-modify-write around the fetch would have written the worker's
      # stale one-block list back — silently, since `:set_oembed_metadata`
      # deliberately carries no optimistic lock. `:autosave` is one of the
      # actions that enqueues this, so the collision is the normal case.
      assert length(typed) == 2
      assert Enum.any?(typed, &match?(%KilnCMS.Blocks.Heading{text: "Added while fetching"}, &1))

      # …and the metadata still landed on the embed.
      assert Enum.find(typed, &match?(%Embed{}, &1)).title == "A track"
    end

    test "changing an embed's URL re-resolves rather than keeping the old card",
         %{admin: admin} do
      stub(%{"title" => "FIRST", "thumbnail_url" => "https://i1.sndcdn.com/first.jpg"})

      page = page_with_embed(@soundcloud, admin)
      [job] = all_enqueued(worker: ResolveWorker)
      assert :ok = perform_job(ResolveWorker, job.args)
      Oban.drain_queue(queue: :default)

      resolved = CMS.get_page!(page.id, authorize?: false)
      block = embed_block(resolved)
      assert block.title == "FIRST"

      # The editor pastes a different link into the same block. Ash merges an
      # embedded block by id, so `title`/`thumbnail_url` survive — a blank-title
      # check would never re-enqueue and the first target's card would sit over
      # the second one's href forever.
      second = "https://soundcloud.com/artist/second"

      updated =
        CMS.update_page!(
          resolved,
          %{blocks: [%{"_type" => "embed", "id" => block.id, "url" => second}]},
          actor: admin
        )

      stale = embed_block(updated)
      assert stale.url == second
      refute KilnCMS.Blocks.Embed.card?(stale)
      refute stale |> KilnCMS.Blocks.render(:web) |> IO.iodata_to_binary() =~ "FIRST"

      # And a fresh resolve is enqueued for the new URL.
      assert [second_job] = all_enqueued(worker: ResolveWorker)
      stub(%{"title" => "SECOND"})
      assert :ok = perform_job(ResolveWorker, second_job.args)

      assert page.id |> CMS.get_page!(authorize?: false) |> embed_block() |> Map.fetch!(:title) ==
               "SECOND"
    end

    test "nothing is enqueued when the feature is off", %{admin: admin} do
      previous = Application.get_env(:kiln_cms, KilnCMS.OEmbed, [])
      Application.put_env(:kiln_cms, KilnCMS.OEmbed, Keyword.put(previous, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.OEmbed, previous) end)

      page_with_embed(@soundcloud, admin)

      assert Enum.empty?(all_enqueued(worker: ResolveWorker))
    end

    test "a URL no provider claims enqueues nothing", %{admin: admin} do
      page_with_embed("https://attacker.example/thing", admin)

      assert Enum.empty?(all_enqueued(worker: ResolveWorker))
    end
  end

  describe "delivery" do
    test "the card's metadata survives the legacy bridge", %{admin: admin} do
      stub(%{"title" => "A track", "provider_name" => "SoundCloud"})

      page = page_with_embed(@soundcloud, admin)
      [job] = all_enqueued(worker: ResolveWorker)
      assert :ok = perform_job(ResolveWorker, job.args)

      # Delivery, both previews and the in-context editor all render through
      # `to_legacy/1`. It used to emit `data: %{}` for an embed, so the card
      # existed in the fired artifact and nowhere a human would look.
      [legacy] =
        page.id
        |> CMS.get_page!(authorize?: false)
        |> Map.fetch!(:blocks)
        |> TypedBlocks.to_typed()
        |> TypedBlocks.to_legacy()

      assert legacy.data["title"] == "A track"
      assert legacy.data["provider_name"] == "SoundCloud"

      [thin] = KilnCMSWeb.BlockComponents.thin_blocks([legacy])
      assert thin.title == "A track"
    end
  end

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp version_count(id) do
    KilnCMS.CMS.Page.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.count!(authorize?: false)
  end
end
