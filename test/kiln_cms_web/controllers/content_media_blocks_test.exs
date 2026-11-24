defmodule KilnCMSWeb.ContentMediaBlocksTest do
  @moduledoc """
  A public page whose video and file blocks point at audience-gated media
  (#2767): the page HTML carries only the authorizing routes, never a storage
  URL or key, so it stays shareable by a public cache while the bytes stay
  behind `KilnCMSWeb.MediaDownloadController`'s per-request check.

  `async: false` because the storage root is pointed at a temporary directory
  with `Application.put_env/3`, which is VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_pmb_#{System.unique_integer([:positive])}")

    private_root =
      Path.join(System.tmp_dir!(), "kiln_pmb_priv_#{System.unique_integer([:positive])}")

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

    :ok
  end

  # Seeds AND signs in: `store_in_session/2` needs the token metadata a real
  # sign-in stamps on the returned struct.
  defp signed_in_user(attrs) do
    email = "pmb-#{System.unique_integer([:positive])}@example.com"

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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => "password123456"},
        []
      )

    user
  end

  defp editor, do: signed_in_user(%{role: :editor})

  defp member,
    do: %{role: :viewer} |> signed_in_user() |> KilnCMS.OrgFixtures.grant_audiences([:member])

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp gated_media!(actor, filename, content_type) do
    key = Storage.generate_key(filename)
    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}")
    File.write!(src, "gated bytes")
    {:ok, ^key} = Storage.store(key, src)

    item =
      CMS.create_media_item!(
        %{
          filename: filename,
          content_type: content_type,
          storage_key: key,
          url: Storage.url(key)
        },
        actor: actor
      )

    {:ok, gated} = CMS.update_media_item(item, %{audience: :member}, actor: actor)
    gated
  end

  test "gated media on a public page: routes only, shared-cacheable, bytes still gated", %{
    conn: conn
  } do
    actor = editor()
    clip = gated_media!(actor, "clip.mp4", "video/mp4")
    doc = gated_media!(actor, "brochure.pdf", "application/pdf")

    page =
      Ash.Seed.seed!(Page, %{
        title: "Public page, gated media",
        slug: "pmb-#{System.unique_integer([:positive])}",
        state: :published,
        blocks: [
          %{"_type" => "video", "media_id" => clip.id, "title" => "Clip"},
          %{"_type" => "file", "media_id" => doc.id, "title" => "Brochure"}
        ]
      })

    conn = get(conn, ~p"/#{page.slug}")
    html = html_response(conn, 200)

    stream = "/media/#{clip.id}/stream"
    download = "/media/#{doc.id}/download"

    assert html =~ ~s(src="#{stream}")
    assert html =~ ~s(href="#{download}" download)

    # Nothing that would fetch the bytes without the route's check.
    # (Gating clears an item's public `url`; the key's own URL is checked too.)
    for item <- [clip, doc] do
      refute html =~ item.storage_key

      for url <- [item.url, Storage.url(item.storage_key)], is_binary(url) do
        refute html =~ url
      end
    end

    refute html =~ "/uploads/"

    # The page depends on no session or audience, so a shared cache may keep it.
    assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")

    # The routes the page hands out refuse an anonymous reader and serve a member.
    for path <- [stream, download] do
      assert build_conn() |> get(path) |> Map.fetch!(:status) == 404
      assert build_conn() |> log_in(member()) |> get(path) |> Map.fetch!(:status) == 200
    end
  end
end
