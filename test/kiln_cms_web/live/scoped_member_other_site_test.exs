defmodule KilnCMSWeb.ScopedMemberOtherSiteTest do
  @moduledoc """
  A member scoped to certain content types on a NON-default site is judged on
  that site by the two UI callers of `Scoping.permitted?/4` (#2599): the
  content list's New buttons (`NewDraft`) and the translations dashboard's
  Missing chip. Both used to pass a bare org id and so read the default site's
  scope instead.

  The fixtures are one-sided on purpose: the member is unrestricted on the
  default site and narrow on org B, so a wrong-site read flips every answer.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp signed_in(role) do
    email = "other-site-#{uniq()}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp member(user, org_id, attrs) do
    Ash.Seed.seed!(
      OrgMembership,
      Map.merge(
        %{user_id: user.id, organization_id: org_id, role: :editor, status: :active},
        Map.new(attrs)
      )
    )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp content(module, org_id) do
    Ash.Seed.seed!(module, %{
      title: "Other site #{uniq()}",
      slug: "os-#{uniq()}",
      locale: "en",
      org_id: org_id
    })
  end

  setup %{conn: conn} do
    site = org("other-site")
    page = content(KilnCMS.CMS.Page, site.id)
    post = content(KilnCMS.CMS.Post, site.id)

    editor =
      :editor
      |> signed_in()
      |> member(Accounts.default_org_id(), editable_types: [])
      |> member(site.id, editable_types: ["post"])

    %{conn: org_conn(conn, site), site: site, page: page, post: post, editor: editor}
  end

  describe "translations dashboard" do
    test "offers Missing only for the type permitted on that site", ctx do
      {:ok, lv, _html} = ctx.conn |> log_in(ctx.editor) |> live(~p"/editor/translations")

      assert has_element?(
               lv,
               ~s(button[phx-click="create_translation"][phx-value-id="#{ctx.post.id}"])
             )

      assert has_element?(lv, ~s(#row-page-#{ctx.page.id}))

      refute has_element?(
               lv,
               ~s(button[phx-click="create_translation"][phx-value-id="#{ctx.page.id}"])
             )
    end

    test "a viewer, a foreign-site editor and a pending registrant are offered none", ctx do
      viewer = signed_in(:viewer) |> member(ctx.site.id, role: :viewer)

      foreign =
        signed_in(:editor) |> member(Accounts.default_org_id(), editable_types: [])

      pending = signed_in(:editor) |> member(ctx.site.id, status: :pending, editable_types: [])

      for user <- [viewer, foreign, pending] do
        case ctx.conn |> log_in(user) |> live(~p"/editor/translations") do
          {:ok, lv, _html} ->
            refute has_element?(lv, ~s(button[phx-click="create_translation"]))

          {:error, {kind, _}} when kind in [:redirect, :live_redirect] ->
            :ok
        end
      end
    end
  end

  describe "content list New buttons" do
    test "offer the type permitted on that site and hide the other", ctx do
      {:ok, lv, _html} = ctx.conn |> log_in(ctx.editor) |> live(~p"/editor")

      assert has_element?(lv, ~s(button[phx-click="new"][phx-value-kind="post"]))
      refute has_element?(lv, ~s(button[phx-click="new"][phx-value-kind="page"]))
    end

    test "the create policy agrees with the buttons", ctx do
      assert {:ok, _} =
               KilnCMS.CMS.create_post(%{title: "Mine", slug: "mine-#{uniq()}", locale: "en"},
                 actor: ctx.editor,
                 tenant: ctx.site.id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               KilnCMS.CMS.create_page(%{title: "Not mine", slug: "nm-#{uniq()}", locale: "en"},
                 actor: ctx.editor,
                 tenant: ctx.site.id
               )
    end

    test "refused actors see no New buttons", ctx do
      viewer = signed_in(:viewer) |> member(ctx.site.id, role: :viewer)
      pending = signed_in(:editor) |> member(ctx.site.id, status: :pending, editable_types: [])

      for user <- [viewer, pending] do
        case ctx.conn |> log_in(user) |> live(~p"/editor") do
          {:ok, lv, _html} -> refute has_element?(lv, ~s(button[phx-click="new"]))
          {:error, {kind, _}} when kind in [:redirect, :live_redirect] -> :ok
        end
      end
    end
  end
end
