defmodule KilnCMSWeb.CspImgSrcTest do
  @moduledoc """
  The browser CSP's `img-src` must admit operator-configured external image
  hosts (`config :kiln_cms, :csp_img_src` / `CSP_IMG_SRC`) — media libraries
  whose files serve from an external CDN render blank thumbnails otherwise —
  plus Unsplash's thumbnail host while that integration is enabled.
  """
  # async: false — tests mutate the global :csp_img_src / :unsplash app env.
  # A project overlay (config/project.exs) may preconfigure :csp_img_src, so
  # every test pins it explicitly rather than assuming an empty default.
  use KilnCMSWeb.ConnCase, async: false

  setup do
    previous = Application.fetch_env(:kiln_cms, :csp_img_src)
    Application.put_env(:kiln_cms, :csp_img_src, [])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kiln_cms, :csp_img_src, value)
        :error -> Application.delete_env(:kiln_cms, :csp_img_src)
      end
    end)

    :ok
  end

  defp csp(conn),
    do: conn |> get("/sign-in") |> get_resp_header("content-security-policy") |> hd()

  test "img-src stays same-origin with no hosts configured", %{conn: conn} do
    assert csp(conn) =~ "img-src 'self' data: blob:;"
  end

  test "configured hosts join img-src", %{conn: conn} do
    Application.put_env(:kiln_cms, :csp_img_src, ["https://imagedelivery.net"])

    assert csp(conn) =~ "img-src 'self' data: blob: https://imagedelivery.net;"
  end

  test "enabling Unsplash admits its thumbnail host", %{conn: conn} do
    previous = Application.get_env(:kiln_cms, :unsplash, [])
    Application.put_env(:kiln_cms, :unsplash, Keyword.put(previous, :access_key, "test-key"))
    on_exit(fn -> Application.put_env(:kiln_cms, :unsplash, previous) end)

    assert csp(conn) =~ "img-src 'self' data: blob: https://images.unsplash.com;"
  end
end
