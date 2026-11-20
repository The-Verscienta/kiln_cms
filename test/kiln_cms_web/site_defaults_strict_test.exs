defmodule KilnCMSWeb.SiteDefaultsStrictTest do
  @moduledoc """
  `GET /api/site` (#2577) on the strict build (#419), where a tenant-less read
  raises instead of answering every site's rows: each host answers its own
  site's values, and a branding save and reset (whose CDN purge decision reads
  the site's row first, `KilnCMS.CMS.Changes.BustBranding`) work tenant-scoped.

  The main suite's `KilnCMSWeb.SiteControllerTest` covers the same tenancy on
  the fail-open build. `async: false`: branding saves bust the shared Cachex
  table.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @moduletag :strict_tenancy

  setup do
    previous = Application.get_env(:kiln_cms, :branding)
    Application.put_env(:kiln_cms, :branding, [])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:kiln_cms, :branding),
        else: Application.put_env(:kiln_cms, :branding, previous)
    end)

    default_id = Accounts.default_org_id()
    b = org("strict-site-b")
    c = org("strict-site-c")

    for id <- [default_id, b.id, c.id] do
      KilnCMS.Cache.bust_branding(id)
      on_exit(fn -> KilnCMS.Cache.bust_branding(id) end)
    end

    %{default_id: default_id, b: b, c: c}
  end

  # authorize?: false — test setup; the admin-only write is covered by
  # `KilnCMSWeb.BrandingLiveTest`.
  defp save!(org_id, attrs),
    do: CMS.save_site_branding!(attrs, authorize?: false, tenant: org_id)

  defp site_json(conn), do: conn |> get("/api/site") |> json_response(200)

  test "each host answers its own site's values", ctx do
    save!(ctx.default_id, %{site_name: "Strict Default", twitter_site: "@strictdefault"})
    save!(ctx.b.id, %{site_name: "Strict B", twitter_site: "@strictb"})
    # A second save takes the upsert path, which reads the row first.
    save!(ctx.b.id, %{site_name: "Strict B", twitter_site: "@strictb2"})

    assert %{"site_name" => "Strict Default", "twitter_site" => "@strictdefault"} =
             site_json(build_conn())

    assert %{"site_name" => "Strict B", "twitter_site" => "@strictb2"} =
             site_json(org_conn(build_conn(), ctx.b))

    assert site_json(org_conn(build_conn(), ctx.c)) == %{
             "site_name" => "KilnCMS",
             "twitter_site" => nil,
             "social_image_url" => nil
           }
  end

  test "a reset answers the defaults again", ctx do
    row = save!(ctx.b.id, %{site_name: "Strict Reset"})
    assert site_json(org_conn(build_conn(), ctx.b))["site_name"] == "Strict Reset"

    CMS.reset_site_branding!(row, authorize?: false, tenant: ctx.b.id)

    assert site_json(org_conn(build_conn(), ctx.b))["site_name"] == "KilnCMS"
  end
end
