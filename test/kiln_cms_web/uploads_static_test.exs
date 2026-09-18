defmodule KilnCMSWeb.UploadsStaticTest do
  @moduledoc """
  `/uploads` serves from wherever the Local adapter writes (#1529).

  The endpoint's `Plug.Static` used to be `from: {:kiln_cms, "priv/uploads"}`,
  compiled in. `KILN_MEDIA_ROOT` moves the adapter's root at runtime, so with
  that mount a blob would be stored and then 404 on its own URL. The mount now
  reads `KilnCMS.Storage.Local.root/0` per request; these pin that it does.
  """
  # `async: false` — mutates the global Storage.Local config.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Storage

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_uploads_#{System.unique_integer([:positive])}")
    root = Path.join(base, "public")
    private_root = Path.join(base, "private")
    previous = Application.get_env(:kiln_cms, Storage.Local)

    Application.put_env(:kiln_cms, Storage.Local,
      root: root,
      private_root: private_root,
      base_url: "/uploads"
    )

    on_exit(fn ->
      File.rm_rf!(base)

      case previous do
        nil -> Application.delete_env(:kiln_cms, Storage.Local)
        opts -> Application.put_env(:kiln_cms, Storage.Local, opts)
      end
    end)

    %{root: root, private_root: private_root}
  end

  defp source(contents) do
    path = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a blob stored under a non-default root is served at its URL", %{conn: conn, root: root} do
    {:ok, key} = Storage.store(Storage.generate_key("a.txt"), source("served"))
    assert File.exists?(Path.join(root, key))

    conn = get(conn, "/uploads/#{key}")

    assert conn.status == 200
    assert conn.resp_body == "served"
    # Still behind the upload headers the endpoint sets for /uploads.
    assert get_resp_header(conn, "content-disposition") == ["attachment"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "a private blob is not served, even with the root moved", ctx do
    {:ok, key} = Storage.store_private(Storage.generate_key("p.txt"), source("secret"))
    assert File.exists?(Path.join(ctx.private_root, key))

    conn = get(ctx.conn, "/uploads/#{key}")

    refute conn.status == 200
    refute conn.resp_body =~ "secret"
  end
end
