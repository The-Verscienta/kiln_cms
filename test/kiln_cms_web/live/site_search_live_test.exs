defmodule KilnCMSWeb.SiteSearchLiveTest do
  @moduledoc """
  The console screen behind `/editor/site-search` (#1558): a site's own
  Meilisearch instance.

  `KilnCMS.Search.Meilisearch.SiteInstanceTest` covers the row and the
  resolver. This covers what only the screen does:

    * **the auth matrix** — a site admin is admitted on their own site, an
      editor is turned away, and a site sees only its own row;
    * **the disclosure** — the page says, before anything is saved, that the
      site's content will be sent to that URL;
    * **the write-only key** — never rendered, a blank save keeps it;
    * **the honest status line** — which instance is in use, how far the
      reindex has got, and the banner when the stored key can't be read.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault

  @password "password1234!"

  @valid %{
    "enabled" => "true",
    "url" => "https://search.site.example",
    "index" => "site_idx",
    "api_key" => "s3cret-meili-key"
  }

  setup do
    %{org: seed_org()}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/site-search")
    end

    test "turns away an editor of this very site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-search")
    end

    test "admits a site admin on their own site, and their save lands there",
         %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-search")
      save(lv, @valid)

      assert %{url: "https://search.site.example", index: "site_idx"} = row!(org)
    end

    test "a site sees only its own instance", %{conn: conn, org: org} do
      other = seed_org()

      CMS.save_site_meilisearch!(
        %{url: "https://search.other.example", index: "other_idx", api_key: "k"},
        tenant: other,
        authorize?: false
      )

      html = conn |> mount_as_admin(org) |> render()

      refute html =~ "search.other.example"
      assert html =~ "doesn&#39;t use Meilisearch"
    end
  end

  describe "the disclosure" do
    test "says plainly, before a save, that the site's content goes to that URL",
         %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)

      disclosure = lv |> element("#site-search-disclosure") |> render()
      assert disclosure =~ "Saving this sends this site&#39;s content to the URL below."
      assert disclosure =~ "full text"
    end
  end

  describe "saving" do
    test "stores the key encrypted, never renders it, and says where content goes",
         %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      html = save(lv, @valid)

      assert html =~ "Search instance saved."
      assert html =~ "indexed into https://search.site.example, index site_idx"
      refute html =~ "s3cret-meili-key"
      assert html =~ "Saved. Leave blank to keep it."

      assert {:ok, "s3cret-meili-key"} = Vault.decrypt(row!(org).api_key_encrypted)
    end

    test "shows the reindex the save started", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)

      Oban.Testing.with_testing_mode(:manual, fn ->
        html = save(lv, @valid)
        assert html =~ "Indexing: 1 job left."
      end)
    end

    test "a later save with a blank key keeps the stored one", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)
      save(lv, %{@valid | "api_key" => "", "index" => "renamed"})

      row = row!(org)
      assert row.index == "renamed"
      assert {:ok, "s3cret-meili-key"} = Vault.decrypt(row.api_key_encrypted)
    end

    test "a private address is refused, with the reason", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      html = save(lv, %{@valid | "url" => "https://10.0.0.5"})

      assert html =~ "private or link-local"
      assert {:ok, []} = CMS.list_site_meilisearch(tenant: org, authorize?: false)
    end

    test "Reindex now enqueues a reindex of this site", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      Oban.Testing.with_testing_mode(:manual, fn ->
        KilnCMS.Repo.delete_all(Oban.Job)
        lv |> element("#site-search-reindex") |> render_click()

        assert [%{args: %{"op" => "reindex", "org_id" => org_id}}] =
                 KilnCMS.Repo.all(Oban.Job)

        assert org_id == org.id
      end)
    end

    test "Remove takes the site off its own instance", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      lv |> element("button", "Remove") |> render_click()

      assert {:ok, []} = CMS.list_site_meilisearch(tenant: org, authorize?: false)
    end
  end

  describe "an unreadable key" do
    test "is called out, because the site's indexing is being held", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      # What a SECRET_KEY_BASE rotation leaves behind.
      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "site_meilisearch", where: r.org_id == type(^org.id, :binary_id)),
          set: [api_key_encrypted: :crypto.strong_rand_bytes(48)]
        )

      html = conn |> mount_as_admin(org) |> render()
      assert html =~ "The saved API key can&#39;t be read. Re-enter it."
    end
  end

  defp mount_as_admin(conn, org) do
    {:ok, lv, _html} =
      conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/site-search")

    lv
  end

  defp save(lv, params) do
    lv |> form("#site-search-form", search: params) |> render_submit()
  end

  defp row!(org) do
    {:ok, [row]} = CMS.list_site_meilisearch(tenant: org, authorize?: false)
    row
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Search Site",
      slug: "sitesearch-#{System.unique_integer([:positive])}",
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
    email = "sitesearch-#{role}-#{System.unique_integer([:positive])}@example.com"

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
