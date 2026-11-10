defmodule KilnCMSWeb.SafetyFieldsLiveTest do
  @moduledoc """
  The per-site safety-field list page (`/editor/safety-fields`): the admin auth
  matrix, a real save that the next edit sees, and clearing a type.
  """
  # `async: false`: the safety-field list is cached under a key that is the
  # organization alone, and these tests all use the default org.
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    org_id = Accounts.default_org_id()
    on_exit(fn -> KilnCMS.Cache.bust_safety_fields(org_id) end)
    %{org_id: org_id}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/safety-fields")
    end

    test "turns away an editor", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/safety-fields")
    end

    test "loads for an admin, listing the types", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/safety-fields")

      assert html =~ "Every field"
      assert html =~ "safety-type-post"
      assert html =~ "safety-type-page"
    end
  end

  describe "saving" do
    test "an admin's save is read by the next edit", %{conn: conn, org_id: org_id} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/safety-fields")

      html =
        lv
        |> form("#safety-fields-form", %{"safety" => %{"field" => ["post:title"]}})
        |> render_submit()

      assert html =~ "Safety fields saved."
      assert KilnCMS.CMS.Severity.safety_fields_for(org_id, "post") == ["title"]
      assert KilnCMS.CMS.Severity.safety_fields_for(org_id, "page") == []

      post = CMS.create_post!(%{title: "Dose", slug: unique_slug()}, actor: admin)
      post = CMS.publish_post!(post, %{}, actor: admin)
      edited = CMS.update_post!(post, %{title: "Dose 2"}, actor: admin)

      version =
        CMS.list_post_versions!(authorize?: false, tenant: edited.org_id)
        |> Enum.filter(&(&1.version_source_id == edited.id and &1.version_action_name == :update))
        |> Enum.max_by(&{DateTime.to_unix(&1.version_inserted_at, :microsecond), &1.id})

      assert version.change_severity == :notable
    end

    test "the every-field switch stores a wildcard", %{conn: conn, org_id: org_id} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/safety-fields")

      lv |> form("#safety-fields-form", %{"safety" => %{"all" => ["page"]}}) |> render_submit()

      assert KilnCMS.CMS.Severity.safety_fields_for(org_id, "page") == ["*"]
    end

    test "an empty selection clears a type", %{conn: conn, org_id: org_id} do
      admin = authed_user(:admin)

      CMS.save_site_safety_fields!(%{fields: %{"post" => ["title"]}},
        actor: admin,
        tenant: org_id
      )

      KilnCMS.Cache.bust_safety_fields(org_id)

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/safety-fields")
      assert html =~ ~s(value="post:title")

      # Nothing ticked: the browser omits the key entirely, so submit the bare
      # event rather than the form's server-rendered defaults.
      render_submit(lv, "save", %{})

      assert KilnCMS.CMS.Severity.safety_fields_for(org_id, "post") == []
    end

    test "an editor cannot save", %{org_id: org_id} do
      editor = authed_user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_safety_fields(%{fields: %{"post" => ["title"]}},
                 actor: editor,
                 tenant: org_id
               )

      assert KilnCMS.CMS.Severity.safety_fields_for(org_id, "post") == []
    end
  end

  defp unique_slug, do: "safety-live-#{System.unique_integer([:positive])}"

  defp authed_user(role) do
    email = "safetylive-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
