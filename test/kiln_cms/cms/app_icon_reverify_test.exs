defmodule KilnCMS.CMS.AppIconReverifyTest do
  @moduledoc """
  Nightly re-check of a stored app icon URL (#1147).

  Save-time verification leaves a measured size on the row; nothing else used
  to re-run it. These cases are the reason the sweep exists: a URL that later
  404s must stop being treated as installable (size cleared, URL kept), and a
  single transient failure must not yank a working icon.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query

  alias KilnCMS.Branding.AppIcon
  alias KilnCMS.CMS
  alias KilnCMS.CMS.SiteBranding

  @stub AppIcon
  @cdn "https://cdn.test/icon.png"

  setup do
    previous = Application.get_env(:kiln_cms, :csp_img_src, [])
    Application.put_env(:kiln_cms, :csp_img_src, ["cdn.test"])
    on_exit(fn -> Application.put_env(:kiln_cms, :csp_img_src, previous) end)

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "icon-reverify-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    org = KilnCMS.Accounts.default_org_id()
    %{admin: admin, org: org}
  end

  defp image(width, height) do
    {:ok, image} = Image.new(width, height, color: :green)
    path = Path.join(System.tmp_dir!(), "icon-#{System.unique_integer([:positive])}.png")
    {:ok, _image} = Image.write(image, path)
    bytes = File.read!(path)
    File.rm(path)
    bytes
  end

  defp serve(bytes) do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, bytes)
    end)
  end

  defp serve_404 do
    Req.Test.stub(@stub, fn conn ->
      Plug.Conn.send_resp(conn, 404, "gone")
    end)
  end

  defp save!(admin, org, size) do
    CMS.save_site_branding!(
      %{
        "app_icon_url" => @cdn,
        "app_icon_size" => size,
        "show_attribution" => true
      },
      actor: admin,
      tenant: org
    )
  end

  defp reverify!(row, org) do
    # The AshOban worker sets `AshObanInteraction`; calling the action directly
    # here uses the same authorize?: false trust the scheduler has.
    CMS.reverify_site_branding_app_icon!(row, tenant: org, authorize?: false)
  end

  test "a successful re-verify refreshes the size and clears the failure streak", ctx do
    serve(image(512, 512))
    row = save!(ctx.admin, ctx.org, 512)

    # Seed a prior near-miss without going through PairAppIcon (which resets).
    {1, _} =
      SiteBranding
      |> where([b], b.id == ^row.id)
      |> KilnCMS.Repo.update_all(set: [app_icon_verify_failures: 1])

    row = Ash.get!(SiteBranding, row.id, authorize?: false, tenant: ctx.org)

    serve(image(1024, 1024))
    updated = reverify!(row, ctx.org)

    assert updated.app_icon_url == @cdn
    assert updated.app_icon_size == 1024
    assert updated.app_icon_verify_failures == 0
  end

  test "one failure keeps the size; the threshold clears it without wiping the URL", ctx do
    serve(image(512, 512))
    row = save!(ctx.admin, ctx.org, 512)
    assert row.app_icon_size == 512

    serve_404()
    after_one = reverify!(row, ctx.org)
    assert after_one.app_icon_url == @cdn
    assert after_one.app_icon_size == 512
    assert after_one.app_icon_verify_failures == 1

    serve_404()
    after_two = reverify!(after_one, ctx.org)
    assert after_two.app_icon_url == @cdn
    assert is_nil(after_two.app_icon_size)
    assert after_two.app_icon_verify_failures == SiteBranding.app_icon_failure_threshold()
  end
end
