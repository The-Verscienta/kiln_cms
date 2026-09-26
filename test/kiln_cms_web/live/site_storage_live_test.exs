defmodule KilnCMSWeb.SiteStorageLiveTest do
  @moduledoc """
  The console screen behind `/editor/site-storage` (#1559): a site's own
  object storage.

  `KilnCMS.Storage.SiteProfilesTest` covers the rows and the resolver. This
  covers what only the screen does:

    * **the auth matrix** — a site admin is admitted on their own site, an
      editor is turned away, and a site sees only its own settings;
    * **the write-only secret** — never rendered, a blank save keeps it;
    * **the honest status line** — where new uploads go, that switching moves
      nothing, and the banner when the stored secret can't be read;
    * **the test button** — a write, read and delete against the saved bucket;
    * **the page's CSP** — the site's bucket origin is allowed to render.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  @valid %{
    "enabled" => "true",
    "endpoint" => "https://s3.site.example",
    "region" => "auto",
    "bucket" => "site-bucket",
    "private_bucket" => "",
    "public_base_url" => "https://cdn.site.example/site-bucket",
    "access_key_id" => "SITEKEYID",
    "secret_access_key" => "site-secret-value"
  }

  setup do
    %{org: seed_org()}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/site-storage")
    end

    test "turns away an editor of this very site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-storage")
    end

    test "admits a site admin on their own site, and their save lands there",
         %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, lv, _html} =
        conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-storage")

      save(lv, @valid)

      assert %{enabled: true, profile_id: id} = row!(org)

      assert %{bucket: "site-bucket"} =
               CMS.get_storage_profile!(id, tenant: org, authorize?: false)
    end

    test "a site sees only its own settings", %{conn: conn, org: org} do
      other = seed_org()

      CMS.save_site_storage!(
        %{
          "enabled" => true,
          "bucket" => "other-bucket",
          "endpoint" => "https://s3.other.example",
          "region" => "auto",
          "public_base_url" => "https://cdn.other.example/b",
          "access_key_id" => "OTHERKEY",
          "secret_access_key" => "other-secret"
        },
        tenant: other,
        authorize?: false
      )

      html = conn |> mount_as_admin(org) |> render()

      refute html =~ "other-bucket"
      refute html =~ "OTHERKEY"
    end
  end

  describe "the form" do
    test "never renders the secret, and a blank save keeps it", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      html = render(lv)
      refute html =~ "site-secret-value"
      assert html =~ "Saved. Leave blank to keep it."

      save(lv, %{@valid | "secret_access_key" => "", "access_key_id" => "SITEKEYID"})
      {:ok, profile} = KilnCMS.Storage.SiteProfiles.for_upload(org.id)
      assert profile.config.secret_access_key == "site-secret-value"
    end

    test "says where new uploads go, and that switching moves nothing",
         %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      assert render(lv) =~ "New uploads go to the deployment&#39;s storage."

      save(lv, @valid)
      status = lv |> element("#site-storage-status") |> render()
      assert status =~ "site-bucket"
      assert status =~ "Changing this moves nothing"
    end

    test "refuses a private endpoint, and says why", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, %{@valid | "endpoint" => "https://169.254.169.254"})

      assert CMS.list_site_storage!(tenant: org, authorize?: false) == []
      assert CMS.list_storage_profiles!(tenant: org, authorize?: false) == []
      # The admin's entry survives the refusal, so they can see what to fix.
      assert lv |> element("#site-storage-form input[name='storage[endpoint]']") |> render() =~
               "169.254.169.254"
    end

    test "warns when the stored secret can't be read", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      KilnCMS.Repo.query!(
        "UPDATE storage_profiles SET secret_access_key_encrypted = $1 WHERE id = $2",
        ["not ciphertext", Ecto.UUID.dump!(row!(org).profile_id)]
      )

      lv = mount_as_admin(conn, org)
      assert has_element?(lv, "#site-storage-secret-unreadable")
    end
  end

  describe "the test button" do
    test "writes, reads back and deletes a file in the saved bucket", %{conn: conn, org: org} do
      stub_bucket()
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      lv |> element("#site-storage-test") |> render_click()

      assert render_async(lv) =~ "The bucket works"
      assert_received {:s3, "PUT", "s3.site.example", "/site-bucket/kiln-probe/" <> _}
      assert_received {:s3, "GET", "s3.site.example", "/site-bucket/kiln-probe/" <> _}
      assert_received {:s3, "DELETE", "s3.site.example", "/site-bucket/kiln-probe/" <> _}
    end

    test "says which step failed", %{conn: conn, org: org} do
      test = self()

      Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
        send(test, {:s3, conn.method})
        Plug.Conn.send_resp(conn, 403, "")
      end)

      lv = mount_as_admin(conn, org)
      save(lv, @valid)
      lv |> element("#site-storage-test") |> render_click()

      assert render_async(lv) =~ "couldn&#39;t write a test file to the bucket (HTTP 403)"
    end
  end

  test "the site's bucket origin is allowed in the page's CSP", %{conn: conn, org: org} do
    lv = mount_as_admin(conn, org)
    save(lv, @valid)

    conn =
      conn
      |> org_conn(org)
      |> log_in(authed_user(:admin))
      |> get(~p"/editor/site-storage")

    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ ~r/img-src [^;]*https:\/\/cdn\.site\.example/
    assert csp =~ ~r/media-src [^;]*https:\/\/cdn\.site\.example/
    refute csp =~ ~r/script-src [^;]*cdn\.site\.example/
  end

  defp stub_bucket do
    test = self()
    {:ok, bucket} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:s3, conn.method, conn.host, conn.request_path})

      case conn.method do
        "PUT" ->
          Agent.update(bucket, &Map.put(&1, conn.request_path, body))
          Plug.Conn.send_resp(conn, 200, "")

        "GET" ->
          Plug.Conn.send_resp(conn, 200, Agent.get(bucket, &Map.get(&1, conn.request_path, "")))

        "DELETE" ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)
  end

  defp mount_as_admin(conn, org) do
    {:ok, lv, _html} =
      conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/site-storage")

    lv
  end

  defp save(lv, params) do
    lv |> form("#site-storage-form", storage: params) |> render_submit()
  end

  defp row!(org) do
    {:ok, [row]} = CMS.list_site_storage(tenant: org, authorize?: false)
    row
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Storage Site",
      slug: "sitestorage-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "sitestorage-#{role}-#{System.unique_integer([:positive])}@example.com"

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
end
