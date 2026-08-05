defmodule KilnCMSWeb.MediaLiveTest do
  @moduledoc false
  # async: false — the upload test points Storage.Local at a temp dir via the
  # global app env.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  # A minimal valid 1x1 PNG.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207, 0, 0,
         0, 7, 0, 1, 2, 254, 165, 53, 230, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  @password "password123456"

  # Seed a user and sign in so the returned struct carries the token metadata
  # that `store_in_session/2` needs (token presence is required).
  defp authed_user(role) do
    email = "media-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/media")
    end

    test "viewers are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:viewer))
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/media")
    end

    test "editors can load the media library", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))
      {:ok, _lv, html} = live(conn, ~p"/media")
      assert html =~ "Media library"
    end
  end

  describe "library filter" do
    defp seed_media(filename) do
      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: filename,
        url: "/uploads/#{System.unique_integer([:positive])}"
      })
    end

    test "filters the library by filename", %{conn: conn} do
      seed_media("sunset.png")
      seed_media("logo.svg")
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      # Match the filename text node (the navbar also references logo.svg).
      assert html =~ ">sunset.png<"
      assert html =~ ">logo.svg<"

      filtered = lv |> form("#media-filter", %{q: "sunset"}) |> render_change()

      assert filtered =~ ">sunset.png<"
      refute filtered =~ ">logo.svg<"
    end

    # The heading reports the true library size, not just the loaded page —
    # "Library (<page size> of N)" until Load more exhausts it (then "Library
    # (N)"). Seeds relative to whatever's already there (the shared sandbox
    # can carry rows from other async: false tests — see
    # [[test-suite-shared-sandbox-flakiness]]) rather than assuming zero, so
    # the total lands exactly one item past the (private) page size of 60
    # regardless of what else is in the library.
    test "the heading shows loaded vs total across pages", %{conn: conn} do
      editor = authed_user(:editor)
      existing = length(CMS.list_media_items!(actor: editor))
      for i <- 1..(61 - existing), do: seed_media("bulk-#{i}.png")

      {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/media")
      assert html =~ "Library (60 of 61)"

      html = lv |> element(~s(button[phx-click="load_more"])) |> render_click()
      assert html =~ "Library (61)"
      refute html =~ "61 of"
    end

    test "the heading counts filter matches while filtering", %{conn: conn} do
      seed_media("sunset.png")
      seed_media("logo.svg")
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      filtered = lv |> form("#media-filter", %{q: "sunset"}) |> render_change()
      assert filtered =~ "Library (1)"
    end

    # #160: the delete button isn't hover-only — visible on touch and on focus.
    test "the delete button is visible without hover", %{conn: conn} do
      seed_media("touchable.png")
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      [_, delete_class] =
        Regex.run(~r/phx-click="delete"[^>]*class="([^"]+)"/s, html) ||
          Regex.run(~r/class="([^"]+)"[^>]*phx-click="delete"/s, html)

      assert delete_class =~ "opacity-100"
      assert delete_class =~ "focus:opacity-100"
    end
  end

  describe "detail panel" do
    test "opens a panel with metadata and saves alt text + caption", %{conn: conn} do
      item =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "photo.png",
          url: "/uploads/photo",
          content_type: "image/png",
          byte_size: 2048,
          width: 1200,
          height: 800,
          variants: %{
            "thumb" => %{"key" => "k", "url" => "/uploads/thumb", "width" => 400, "height" => 267}
          }
        })

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      panel =
        lv |> element(~s(button[phx-click="select"][phx-value-id="#{item.id}"])) |> render_click()

      assert panel =~ "Alt text"
      assert panel =~ "2.0 KB"
      assert panel =~ "image/png"
      # Dimensions + responsive variants are surfaced.
      assert panel =~ "1200"
      assert panel =~ "Responsive variants"
      assert panel =~ "thumb"

      # Variants preview inline. They must not be links: media blobs carry
      # `content-disposition: attachment` on both storage adapters, so navigating
      # to one downloads a UUID-named file rather than opening it.
      assert panel =~ ~s(src="/uploads/thumb")
      refute panel =~ ~s(href="/uploads/thumb")

      lv
      |> form("form[phx-submit=save_meta]", %{alt: "A nice photo", caption: "At dusk"})
      |> render_submit()

      saved = CMS.get_media_item!(item.id, authorize?: false)
      assert saved.alt == "A nice photo"
      assert saved.caption == "At dusk"
    end

    test "clicking the preview sets the focal point (clamped) and re-queues variants", %{
      conn: conn
    } do
      item =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "focal.png",
          url: "/uploads/focal",
          content_type: "image/png",
          width: 1200,
          height: 800
        })

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      panel =
        lv |> element(~s(button[phx-click="select"][phx-value-id="#{item.id}"])) |> render_click()

      # The focal editor renders with the marker at the default center, and is
      # keyboard-operable (focusable button + current point as data attrs the
      # arrow-key handler reads).
      assert panel =~ "focal-editor-#{item.id}"
      assert panel =~ "left: 50.0%"
      assert panel =~ ~s(role="button")
      assert panel =~ ~s(tabindex="0")
      assert panel =~ ~s(data-focal-x="0.5")

      # The FocalPoint hook pushes fractional coordinates (click or keyboard
      # nudge both arrive as this event).
      render_hook(lv, "set_focal", %{"x" => 0.25, "y" => 0.75})

      saved = CMS.get_media_item!(item.id, authorize?: false)
      assert saved.focal_x == 0.25
      assert saved.focal_y == 0.75

      # After a move, the data attributes reflect the new point so the next
      # keyboard nudge starts from the right place.
      panel =
        lv |> element(~s(button[phx-click="select"][phx-value-id="#{item.id}"])) |> render_click()

      assert panel =~ ~s(data-focal-x="0.25")
      assert panel =~ ~s(data-focal-y="0.75")
    end

    test "the rotate button edits the image and reports regeneration", %{conn: conn} do
      root = Path.join(System.tmp_dir!(), "kiln_ui_edit_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

      on_exit(fn ->
        File.rm_rf!(root)
        Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
      end)

      src = Path.join(System.tmp_dir!(), "ui-src-#{System.unique_integer([:positive])}.png")
      {:ok, image} = Image.new(600, 400, color: :green)
      {:ok, _} = Image.write(image, src)
      key = "ui-orig-#{System.unique_integer([:positive])}.png"
      {:ok, ^key} = KilnCMS.Storage.store(key, src)
      File.rm(src)

      item =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "rotate.png",
          url: "/uploads/#{key}",
          storage_key: key,
          content_type: "image/png",
          width: 600,
          height: 400
        })

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")
      lv |> element(~s(button[phx-click="select"][phx-value-id="#{item.id}"])) |> render_click()

      html =
        lv
        |> element(~s(button[phx-click="transform"][phx-value-op="rotate_right"]))
        |> render_click()

      assert html =~ "variants are regenerating"

      saved = CMS.get_media_item!(item.id, authorize?: false)
      assert saved.width == 400
      assert saved.height == 600
      refute saved.storage_key == key
    end

    # Regression for #169: the drawer is a labeled modal dialog with a focus trap.
    test "the detail drawer exposes dialog semantics and a focus trap", %{conn: conn} do
      item = Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{filename: "dlg.png", url: "/uploads/dlg"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      panel =
        lv |> element(~s(button[phx-click="select"][phx-value-id="#{item.id}"])) |> render_click()

      assert panel =~ ~s(role="dialog")
      assert panel =~ ~s(aria-modal="true")
      assert panel =~ ~s(aria-labelledby="media-detail-title")
      assert panel =~ ~s(id="media-detail-title")
      assert panel =~ ~s(phx-hook="FocusTrap")
    end
  end

  describe "trash" do
    test "admin can soft-delete from the library, then restore from trash", %{conn: conn} do
      item = seed_media("doomed.png")
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/media")

      # Soft-delete: the item leaves the library but the row survives.
      lv |> element(~s(button[phx-value-id="#{item.id}"][phx-click="delete"])) |> render_click()
      refute render(lv) =~ ">doomed.png<"
      assert CMS.list_trashed_media_items!(authorize?: false) |> Enum.any?(&(&1.id == item.id))

      # Trash view lists it; restoring returns it to the library.
      trash = lv |> element("button", "Trash") |> render_click()
      assert trash =~ ">doomed.png<"

      lv |> element(~s(button[phx-value-id="#{item.id}"][phx-click="restore"])) |> render_click()
      assert CMS.get_media_item!(item.id, authorize?: false)
      refute CMS.list_trashed_media_items!(authorize?: false) |> Enum.any?(&(&1.id == item.id))
    end

    test "purge permanently removes a trashed item", %{conn: conn} do
      item = seed_media("gone.png")
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/media")

      lv |> element(~s(button[phx-value-id="#{item.id}"][phx-click="delete"])) |> render_click()
      lv |> element("button", "Trash") |> render_click()
      lv |> element(~s(button[phx-value-id="#{item.id}"][phx-click="purge"])) |> render_click()

      assert {:error, _} = CMS.get_media_item(item.id, authorize?: false)
    end

    test "non-admins don't see the trash toggle", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")
      refute html =~ ~s(phx-click="show_trash")
    end
  end

  describe "live refresh" do
    test "the library refreshes when a variant job broadcasts completion", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      # An item created after mount isn't shown until a refresh.
      item = seed_media("late-arrival.png")
      refute render(lv) =~ ">late-arrival.png<"

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        KilnCMS.Media.VariantWorker.topic(),
        {:media_processed, item.id}
      )

      # Broadcast bursts are coalesced behind a short timer; fire it directly
      # rather than sleeping through the debounce.
      send(lv.pid, :refresh_media)
      assert render(lv) =~ ">late-arrival.png<"
    end
  end

  describe "upload" do
    setup do
      root = Path.join(System.tmp_dir!(), "kiln_media_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

      on_exit(fn ->
        File.rm_rf!(root)
        Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
      end)

      %{root: root}
    end

    test "rejects a file whose content is not a real image", %{conn: conn, root: root} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "fake.png", content: "not-a-png", type: "image/png"}
        ])

      assert render_upload(input, "fake.png")

      html = lv |> element("#upload-form") |> render_submit()
      # The flash names the file and the reason, not just a count (audit U-M5).
      # "unsupported file format", not "...image format" (#481): the content
      # fails BOTH ImageProcessor and DocumentProcessor now, and the reason
      # returned is the latter's (type-neutral wording either way).
      assert html =~ "Upload failed"
      assert html =~ "fake.png"
      assert html =~ "unsupported file format"
      refute Enum.any?(CMS.list_media_items!(actor: editor))
      refute File.exists?(Path.join(root, "fake.png"))
    end

    # #178: the upload progress bar exposes progressbar semantics.
    test "the upload progress bar has progressbar semantics", %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "pixel.png", content: @png, type: "image/png"}
        ])

      html = render_upload(input, "pixel.png", 40)

      assert html =~ ~s(role="progressbar")
      assert html =~ ~s(aria-valuenow="40")
      assert html =~ ~s(aria-valuemax="100")
    end

    test "uploading an image stores it and adds it to the library", %{conn: conn, root: root} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "pixel.png", content: @png, type: "image/png"}
        ])

      assert render_upload(input, "pixel.png")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "pixel.png"

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.filename == "pixel.png"
      assert item.content_type == "image/png"
      assert File.exists?(Path.join(root, item.storage_key))

      # Dimensions are filled in asynchronously by the variant worker (the 1x1
      # pixel is too small for any responsive variant, so none are produced).
      KilnCMS.DataCase.drain_oban()
      processed = CMS.get_media_item!(item.id, actor: editor)
      assert processed.width == 1
      assert processed.height == 1
    end

    test "uploading a PDF stores it as a document, not an image (#481)", %{
      conn: conn,
      root: root
    } do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      pdf = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\nsome pdf content"

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "brochure.pdf", content: pdf, type: "application/pdf"}
        ])

      assert render_upload(input, "brochure.pdf")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "brochure.pdf"

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.filename == "brochure.pdf"
      assert item.content_type == "application/pdf"
      assert item.width == nil
      assert item.audience == :public
      assert File.exists?(Path.join(root, item.storage_key))
    end

    test "a file with a .pdf name but non-PDF bytes is rejected, not silently accepted", %{
      conn: conn
    } do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "fake.pdf", content: "just some text, not a real pdf", type: "application/pdf"}
        ])

      assert render_upload(input, "fake.pdf")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "Upload failed"
      assert html =~ "fake.pdf"
      refute Enum.any?(CMS.list_media_items!(actor: editor))
    end

    test "a document under the document cap but over the (smaller) image cap still uploads", %{
      conn: conn
    } do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      # 11MB: over the 10MB image cap, under the 25MB document cap — proves
      # the per-type size cap is real, not the tighter image cap applied to
      # everything (#481).
      big_pdf = "%PDF-1.7\n" <> :binary.copy(<<0>>, 11_000_000)

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "big.pdf", content: big_pdf, type: "application/pdf"}
        ])

      assert render_upload(input, "big.pdf")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "big.pdf"
      refute html =~ "Upload failed"

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.filename == "big.pdf"
    end

    test "an oversized image is rejected under the (smaller) image cap, not waved through under the document ceiling",
         %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      # A structurally-valid 1x1 PNG padded past 10MB with a private ancillary
      # tEXt chunk (safe for any PNG decoder, libvips included, to skip) —
      # over the 10MB image cap, under the 25MB Phoenix-level ceiling
      # `@max_file_size` sets for the upload socket itself. Proves the image
      # cap is actually enforced, not just the looser document one (#481).
      big_png = @png |> insert_padding_chunk(11_000_000 - byte_size(@png))

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "big.png", content: big_png, type: "image/png"}
        ])

      assert render_upload(input, "big.png")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "Upload failed"
      assert html =~ "big.png"
      refute Enum.any?(CMS.list_media_items!(actor: editor))
    end

    # A minimal ISO-BMFF head — enough for `AVProcessor` to byte-sniff. There
    # is no real video here and none is needed: the upload path never decodes
    # the file (ffprobe runs in `Media.AVWorker`, off the request).
    defp mp4_bytes, do: <<0, 0, 0, 0x20>> <> "ftypisom" <> :binary.copy(<<0>>, 64)

    test "uploading an MP4 stores it as video, not as a document (#494)", %{
      conn: conn,
      root: root
    } do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "clip.mp4", content: mp4_bytes(), type: "video/mp4"}
        ])

      assert render_upload(input, "clip.mp4")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "clip.mp4"
      refute html =~ "Upload failed"

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.content_type == "video/mp4"
      assert File.exists?(Path.join(root, item.storage_key))

      # A/V goes to AVWorker, NOT the image VariantWorker — the whole point of
      # `enqueue_processing/1`'s dispatch, and invisible without this.
      assert [%Oban.Job{worker: "KilnCMS.Media.AVWorker", args: args}] =
               KilnCMS.Repo.all(Oban.Job)

      assert args["media_item_id"] == item.id
    end

    test "uploading an image still goes to the image VariantWorker", %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "pixel.png", content: @png, type: "image/png"}
        ])

      assert render_upload(input, "pixel.png")
      lv |> element("#upload-form") |> render_submit()

      assert [%Oban.Job{worker: "KilnCMS.Media.VariantWorker"}] = KilnCMS.Repo.all(Oban.Job)
    end

    test "a caption track enqueues no job at all — there is nothing to derive", %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "captions.vtt", content: "WEBVTT\n\nhello", type: "text/vtt"}
        ])

      assert render_upload(input, "captions.vtt")
      lv |> element("#upload-form") |> render_submit()

      assert KilnCMS.Repo.all(Oban.Job) == []
    end

    test "byte_size records the STORED file, not the client's declared size", %{
      conn: conn,
      root: root
    } do
      # The two differ for every image: what gets stored is the
      # metadata-stripped copy, not the uploaded bytes. The recorded size
      # should describe what a reader will actually download.
      #
      # (The stronger property — that a *lying* `client_size` can't slip past a
      # per-kind cap — is what moving `check_size/2` onto `File.stat` buys, but
      # `Phoenix.LiveViewTest` refuses to build an entry whose declared size
      # disagrees with its content, so the lie itself isn't reachable from here.
      # The oversized-`.vtt` test above covers the cap with honest bytes.)
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "pixel.png", content: @png, type: "image/png"}
        ])

      assert render_upload(input, "pixel.png")
      lv |> element("#upload-form") |> render_submit()

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.byte_size == File.stat!(Path.join(root, item.storage_key)).size
    end

    test "uploading an MP3 stores it as audio", %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      mp3 = "ID3" <> <<3, 0, 0, 0, 0, 0, 0>> <> :binary.copy(<<0>>, 64)

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "episode.mp3", content: mp3, type: "audio/mpeg"}
        ])

      assert render_upload(input, "episode.mp3")

      html = lv |> element("#upload-form") |> render_submit()
      refute html =~ "Upload failed"

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.content_type == "audio/mpeg"
    end

    test "uploading a WebVTT caption track is accepted as its own kind", %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nHello.\n"

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "captions.vtt", content: vtt, type: "text/vtt"}
        ])

      assert render_upload(input, "captions.vtt")

      html = lv |> element("#upload-form") |> render_submit()
      refute html =~ "Upload failed"

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.content_type == "text/vtt"
    end

    test "a .mp4-named file with non-video bytes is rejected, not silently accepted", %{
      conn: conn
    } do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "fake.mp4", content: "not a video at all", type: "video/mp4"}
        ])

      assert render_upload(input, "fake.mp4")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "Upload failed"
      assert html =~ "fake.mp4"
      refute Enum.any?(CMS.list_media_items!(actor: editor))
    end

    test "QuickTime bytes are rejected even under an .mp4 name — nothing transcodes them", %{
      conn: conn
    } do
      # The `.mov` extension never reaches the server (`allow_upload`'s accept
      # list stops it in the browser), so the case worth covering is the one
      # that gets past that: a renamed file whose ftyp brand is `qt  `.
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      mov = <<0, 0, 0, 0x20>> <> "ftypqt  " <> :binary.copy(<<0>>, 64)

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "master.mp4", content: mov, type: "video/mp4"}
        ])

      assert render_upload(input, "master.mp4")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "Upload failed"
      refute Enum.any?(CMS.list_media_items!(actor: editor))
    end

    test "an oversized caption track is rejected under the (tiny) captions cap", %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      # 3MB of "captions": well under the video cap, well over the 2MB one
      # that actually applies. Proves the per-kind A/V caps are real.
      vtt = "WEBVTT\n" <> :binary.copy("x", 3_000_000)

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "huge.vtt", content: vtt, type: "text/vtt"}
        ])

      assert render_upload(input, "huge.vtt")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "Upload failed"
      refute Enum.any?(CMS.list_media_items!(actor: editor))
    end
  end

  # Splices a private `teXt` ancillary chunk (safe for any PNG decoder to
  # skip) of `pad_bytes` of content into a valid PNG, right after IHDR —
  # inflates the file size without touching pixel data.
  defp insert_padding_chunk(png, pad_bytes) do
    ihdr_end = 8 + 4 + 4 + 13 + 4
    <<head::binary-size(^ihdr_end), tail::binary>> = png
    data = :binary.copy(<<0>>, pad_bytes)
    type = "teXt"
    crc = :erlang.crc32(type <> data)
    chunk = <<byte_size(data)::32, type::binary, data::binary, crc::32>>
    head <> chunk <> tail
  end

  describe "unsplash" do
    setup do
      root = Path.join(System.tmp_dir!(), "kiln_unsplash_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

      previous = Application.get_env(:kiln_cms, :unsplash, [])
      Application.put_env(:kiln_cms, :unsplash, Keyword.put(previous, :access_key, "test-key"))

      on_exit(fn ->
        File.rm_rf!(root)
        Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
        Application.put_env(:kiln_cms, :unsplash, previous)
      end)

      %{root: root}
    end

    defp stub_unsplash(png) do
      Req.Test.stub(KilnCMS.Unsplash, fn conn ->
        case conn.request_path do
          "/search/photos" ->
            Req.Test.json(conn, %{
              "total_pages" => 1,
              "results" => [
                %{
                  "id" => "abc123",
                  "width" => 4000,
                  "height" => 3000,
                  "alt_description" => "dried herbs on a table",
                  "urls" => %{"small" => "https://images.unsplash.com/photo-abc123?w=400"},
                  "links" => %{
                    "html" => "https://unsplash.com/photos/abc123",
                    "download_location" => "https://api.unsplash.com/photos/abc123/download"
                  },
                  "user" => %{
                    "name" => "Jane Lens",
                    "links" => %{"html" => "https://unsplash.com/@janelens"}
                  }
                }
              ]
            })

          "/photos/abc123/download" ->
            Req.Test.json(conn, %{"url" => "https://images.unsplash.com/file-abc123"})

          "/file-abc123" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/png")
            |> Plug.Conn.send_resp(200, png)
        end
      end)
    end

    test "the tab is hidden while no access key is configured", %{conn: conn} do
      previous = Application.get_env(:kiln_cms, :unsplash, [])
      Application.put_env(:kiln_cms, :unsplash, Keyword.delete(previous, :access_key))
      on_exit(fn -> Application.put_env(:kiln_cms, :unsplash, previous) end)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")
      refute html =~ "show_unsplash"
    end

    test "searching lists photos with photographer attribution", %{conn: conn} do
      stub_unsplash(@png)
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      assert html =~ "show_unsplash"
      lv |> element(~s(button[phx-click="show_unsplash"])) |> render_click()
      lv |> form("#unsplash-search", %{q: "herbs"}) |> render_submit()

      html = render_async(lv, 2_000)
      assert html =~ "unsplash-abc123"
      assert html =~ "dried herbs on a table"
      assert html =~ "Jane Lens"
      assert html =~ "utm_source=kiln_cms"
    end

    test "importing a photo stores it in the library with attribution", %{conn: conn, root: root} do
      stub_unsplash(@png)
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      lv |> element(~s(button[phx-click="show_unsplash"])) |> render_click()
      lv |> form("#unsplash-search", %{q: "herbs"}) |> render_submit()
      render_async(lv, 2_000)

      lv
      |> element(~s(button[phx-click="unsplash_import"][phx-value-id="abc123"]))
      |> render_click()

      html = render_async(lv, 5000)
      assert html =~ "Imported unsplash-abc123.png into the library."

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.filename == "unsplash-abc123.png"
      assert item.content_type == "image/png"
      assert item.alt == "dried herbs on a table"
      assert item.caption == "Photo by Jane Lens on Unsplash"
      assert File.exists?(Path.join(root, item.storage_key))
    end

    test "a failed download surfaces an error flash", %{conn: conn} do
      Req.Test.stub(KilnCMS.Unsplash, fn conn ->
        case conn.request_path do
          "/search/photos" ->
            Req.Test.json(conn, %{
              "total_pages" => 1,
              "results" => [
                %{
                  "id" => "abc123",
                  "urls" => %{"small" => "https://images.unsplash.com/photo-abc123?w=400"},
                  "links" => %{
                    "download_location" => "https://api.unsplash.com/photos/abc123/download"
                  },
                  "user" => %{"name" => "Jane Lens"}
                }
              ]
            })

          _ ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end)

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      lv |> element(~s(button[phx-click="show_unsplash"])) |> render_click()
      lv |> form("#unsplash-search", %{q: "herbs"}) |> render_submit()
      render_async(lv, 2_000)

      lv
      |> element(~s(button[phx-click="unsplash_import"][phx-value-id="abc123"]))
      |> render_click()

      html = render_async(lv, 5000)
      assert html =~ "Couldn&#39;t import that photo from Unsplash."
      assert CMS.list_media_items!(authorize?: false) == []
    end
  end
end
