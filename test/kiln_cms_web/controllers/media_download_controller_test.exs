defmodule KilnCMSWeb.MediaDownloadControllerTest do
  @moduledoc """
  The one path every document download goes through (#481): authorization
  (public vs. audience-gated), the correct bytes from the right storage
  backend, the original filename (not the UUID storage key), and the
  download counter. A denied/missing item 404s — never 403, so a gated
  document's existence isn't confirmed to a reader without its audience.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_dl_#{System.unique_integer([:positive])}")

    private_root =
      Path.join(System.tmp_dir!(), "kiln_dl_priv_#{System.unique_integer([:positive])}")

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

  # Seeds AND signs in — `store_in_session/2` needs the token metadata a real
  # sign-in action stamps on the returned struct (a plain `Ash.Seed.seed!`
  # alone isn't enough).
  defp signed_in_user(attrs) do
    email = "dl-#{System.unique_integer([:positive])}@example.com"

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

  defp editor, do: signed_in_user(%{role: :editor})
  defp reader(audiences), do: signed_in_user(%{role: :viewer, audiences: audiences})

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp public_document!(actor, body \\ "%PDF-1.7\nreal pdf bytes") do
    key = Storage.generate_key("brochure.pdf")
    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}")
    File.write!(src, body)
    {:ok, ^key} = Storage.store(key, src)

    CMS.create_media_item!(
      %{
        filename: "brochure.pdf",
        content_type: "application/pdf",
        storage_key: key,
        url: Storage.url(key)
      },
      actor: actor
    )
  end

  defp gated_document!(actor, audience) do
    doc = public_document!(actor)
    {:ok, gated} = CMS.update_media_item(doc, %{audience: audience}, actor: actor)
    gated
  end

  test "downloads a public document anonymously, with the original filename and correct bytes", %{
    conn: conn
  } do
    doc = public_document!(editor(), "%PDF-1.7\nhello world")

    conn = get(conn, "/media/#{doc.id}/download")

    assert conn.status == 200
    assert conn.resp_body == "%PDF-1.7\nhello world"
    assert get_resp_header(conn, "content-type") == ["application/pdf; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"brochure.pdf\""
           ]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "a gated document 404s for an anonymous reader" do
    conn = Phoenix.ConnTest.build_conn()
    doc = gated_document!(editor(), :member)

    conn = get(conn, "/media/#{doc.id}/download")
    assert conn.status == 404
  end

  test "a gated document 404s for a signed-in reader without that audience", %{conn: conn} do
    doc = gated_document!(editor(), :member)
    conn = conn |> log_in(reader([])) |> get("/media/#{doc.id}/download")
    assert conn.status == 404
  end

  test "a gated document downloads (from PRIVATE storage) for a reader who holds the audience", %{
    conn: conn,
    private_root: private_root
  } do
    doc = gated_document!(editor(), :member)
    assert File.exists?(Path.join(private_root, doc.storage_key))

    conn = conn |> log_in(reader([:member])) |> get("/media/#{doc.id}/download")

    assert conn.status == 200
    assert conn.resp_body =~ "real pdf bytes"

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"brochure.pdf\""
           ]
  end

  test "an editor can always download a gated document" do
    conn = Phoenix.ConnTest.build_conn()
    actor = editor()
    doc = gated_document!(actor, :member)

    conn = conn |> log_in(actor) |> get("/media/#{doc.id}/download")
    assert conn.status == 200
  end

  test "an unknown id 404s rather than raising" do
    conn = Phoenix.ConnTest.build_conn()
    conn = get(conn, "/media/#{Ash.UUID.generate()}/download")
    assert conn.status == 404
  end

  test "a malformed id 404s rather than raising" do
    conn = Phoenix.ConnTest.build_conn()
    conn = get(conn, "/media/not-a-uuid/download")
    assert conn.status == 404
  end

  test "a filename with a quote and a newline can't break the Content-Disposition header", %{
    conn: conn
  } do
    doc =
      editor()
      |> public_document!()
      |> then(fn item ->
        {:ok, updated} =
          CMS.update_media_item(item, %{filename: "evil\"\r\nX-Injected: yes.pdf"},
            actor: editor(),
            authorize?: false
          )

        updated
      end)

    conn = get(conn, "/media/#{doc.id}/download")

    [disposition] = get_resp_header(conn, "content-disposition")
    refute disposition =~ "\r"
    refute disposition =~ "\n"
    assert disposition == "attachment; filename=\"evil' X-Injected: yes.pdf\""
  end

  test "a successful download increments the item's counter", %{conn: conn} do
    doc = public_document!(editor())
    assert doc.download_count == 0

    conn |> get("/media/#{doc.id}/download")

    reloaded = CMS.get_media_item!(doc.id, authorize?: false)
    assert reloaded.download_count == 1
  end
end
