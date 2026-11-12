defmodule KilnCMSWeb.TeamLiveTest do
  @moduledoc "Team + granular-RBAC management UI (#332, slice 4)."
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Test.AccessibleNames

  @password "password123456"

  defp authed_user(role) do
    email = "team-live-#{System.unique_integer([:positive])}@example.com"

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
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/team")
    end

    test "editors are turned away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               live(conn, ~p"/editor/team")
    end
  end

  describe "team management" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "adds a member and shows them in the list", %{conn: conn} do
      colleague = authed_user(:viewer)
      {:ok, view, _html} = live(conn, ~p"/editor/team")

      html =
        view
        |> form("#add-member-form", %{"member" => %{"email" => to_string(colleague.email)}})
        |> render_submit()

      assert html =~ "Member added"
      assert html =~ to_string(colleague.email)
    end

    test "a site admin with no membership is listed and counted, without site-tier controls",
         %{conn: conn} do
      # What `/setup` creates: `User.role == :admin` and no OrgMembership row.
      admin = authed_user(:admin)
      conn = log_in(conn, admin)

      {:ok, view, html} = live(conn, ~p"/editor/team")

      assert has_element?(view, "#site-admin-#{admin.id}", "Site admin")
      assert has_element?(view, "#site-admin-#{admin.id}", to_string(admin.email))
      refute has_element?(view, "#site-admin-#{admin.id} button")
      refute html =~ "No members on this site yet."
      assert html =~ ~r/Members\s*\(\d+\)/
      refute html =~ ~r/Members\s*\(0\)/
    end

    test "a normal membership keeps its edit and remove controls", %{conn: conn} do
      colleague = authed_user(:editor)

      {:ok, membership} =
        Accounts.create_org_membership(
          %{user_id: colleague.id, organization_id: Accounts.default_org_id(), role: :editor},
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")

      assert has_element?(view, "#member-#{membership.id} button", "Edit")
      assert has_element?(view, "#member-#{membership.id} button[phx-click='remove_member']")
      refute has_element?(view, "#member-#{membership.id}", "Site admin")
      refute has_element?(view, "#site-admin-#{colleague.id}")
    end

    test "each row's actions name the member or role they act on (#1774)", %{conn: conn} do
      admin = authed_user(:admin)
      conn = log_in(conn, admin)

      memberships =
        for _ <- 1..2 do
          colleague = authed_user(:editor)

          {:ok, membership} =
            Accounts.create_org_membership(
              %{user_id: colleague.id, organization_id: Accounts.default_org_id(), role: :editor},
              authorize?: false
            )

          {membership, to_string(colleague.email)}
        end

      roles =
        for name <- ["Blog editor", "Docs editor"] do
          {:ok, role} =
            Accounts.create_role(%{name: name, org_id: Accounts.default_org_id()},
              authorize?: false
            )

          role
        end

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      html = render(view)

      assert AccessibleNames.name(html, "#site-admin-#{admin.id} a") ==
               "Manage account #{admin.email}"

      for {membership, email} <- memberships do
        assert AccessibleNames.name(
                 html,
                 "#member-#{membership.id} button[phx-click='edit_member']"
               ) ==
                 "Edit #{email}"

        assert AccessibleNames.name(
                 html,
                 "#member-#{membership.id} button[phx-click='remove_member']"
               ) == "Remove #{email}"
      end

      for role <- roles do
        assert AccessibleNames.name(html, "#role-#{role.id} button[phx-click='edit_role']") ==
                 "Edit role #{role.name}"

        assert AccessibleNames.name(html, "#role-#{role.id} button[phx-click='delete_role']") ==
                 "Delete role #{role.name}"
      end

      assert AccessibleNames.repeated(html, "li a, li button") == []
    end

    test "an admin who also holds a membership is listed once, on the membership row",
         %{conn: conn} do
      other_admin = authed_user(:admin)

      {:ok, membership} =
        Accounts.create_org_membership(
          %{user_id: other_admin.id, organization_id: Accounts.default_org_id(), role: :viewer},
          authorize?: false
        )

      {:ok, view, html} = live(conn, ~p"/editor/team")

      refute has_element?(view, "#site-admin-#{other_admin.id}")
      assert has_element?(view, "#member-#{membership.id}", "Site admin")

      # Counted in rows, not in raw HTML: the row's action names carry the
      # address too (#1774), so a string count would see it three times on
      # the one row.
      rows =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("li[id^='site-admin-'], li[id^='member-']")
        |> Enum.filter(&(LazyHTML.text(&1) =~ to_string(other_admin.email)))

      assert length(rows) == 1
    end

    test "an unknown address is invited and listed as pending (#2135)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/team")
      email = "newcomer-#{System.unique_integer([:positive])}@example.com"

      html =
        view
        |> form("#add-member-form", %{"member" => %{"email" => email, "role" => "editor"}})
        |> render_submit()

      assert html =~ "Invitation sent to #{email}"

      [invitation] =
        Accounts.list_invitations_for_org!(Accounts.default_org_id(), authorize?: false)
        |> Enum.filter(&(to_string(&1.email) == email))

      assert invitation.role == :editor
      assert has_element?(view, "#invitation-#{invitation.id}", email)
      assert has_element?(view, "#team-invitations-heading", "Pending invitations")
    end

    test "an address already on the site is refused by name", %{conn: conn} do
      colleague = authed_user(:viewer)

      Accounts.create_org_membership!(
        %{user_id: colleague.id, organization_id: Accounts.default_org_id(), role: :viewer},
        authorize?: false
      )

      {:ok, view, _html} = live(conn, ~p"/editor/team")

      html =
        view
        |> form("#add-member-form", %{"member" => %{"email" => to_string(colleague.email)}})
        |> render_submit()

      assert html =~ "already on this site"
    end

    test "an address the mail queue would refuse is a message, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/team")

      html =
        view
        |> form("#add-member-form", %{"member" => %{"email" => "two@@example.com"}})
        |> render_submit()

      assert html =~ "must be a valid email address"
      refute has_element?(view, "#team-invitations")
    end

    test "a pending invitation can be resent and revoked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/team")
      email = "pending-#{System.unique_integer([:positive])}@example.com"

      view
      |> form("#add-member-form", %{"member" => %{"email" => email}})
      |> render_submit()

      [invitation] =
        Accounts.list_invitations_for_org!(Accounts.default_org_id(), authorize?: false)
        |> Enum.filter(&(to_string(&1.email) == email))

      html = render_click(view, "resend_invitation", %{"id" => invitation.id})
      assert html =~ "Invitation sent again to #{email}"

      resent = Accounts.list_invitations!(authorize?: false, query: [filter: [id: invitation.id]])
      assert [%{sent_count: 2}] = resent
      refute hd(resent).token_hash == invitation.token_hash

      html = render_click(view, "revoke_invitation", %{"id" => invitation.id})
      assert html =~ "Invitation revoked"
      refute has_element?(view, "#invitation-#{invitation.id}")

      assert Accounts.list_invitations!(authorize?: false, query: [filter: [id: invitation.id]]) ==
               []
    end

    test "another site's invitation id does nothing", %{conn: conn} do
      admin = authed_user(:admin)
      other = KilnCMS.OrgFixtures.org("other-site")

      foreign =
        Accounts.invite_to_org!(
          %{
            organization_id: other.id,
            email: "foreign-#{System.unique_integer([:positive])}@example.com"
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")

      render_click(view, "revoke_invitation", %{"id" => foreign.id})
      render_click(view, "resend_invitation", %{"id" => foreign.id})
      render_click(view, "revoke_invitation", %{"id" => ["not", "a", "string"]})

      assert [%{sent_count: 1}] =
               Accounts.list_invitations!(authorize?: false, query: [filter: [id: foreign.id]])
    end

    test "each invitation's actions name the address they act on", %{conn: conn} do
      admin = authed_user(:admin)

      emails =
        for _ <- 1..2 do
          email = "named-#{System.unique_integer([:positive])}@example.com"

          Accounts.invite_to_org!(%{organization_id: Accounts.default_org_id(), email: email},
            actor: admin
          )

          email
        end

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      html = render(view)

      for invitation <-
            Accounts.list_invitations_for_org!(Accounts.default_org_id(), authorize?: false),
          to_string(invitation.email) in emails do
        assert AccessibleNames.name(
                 html,
                 "#invitation-#{invitation.id} button[phx-click='resend_invitation']"
               ) == "Resend the invitation to #{invitation.email}"

        assert AccessibleNames.name(
                 html,
                 "#invitation-#{invitation.id} button[phx-click='revoke_invitation']"
               ) == "Revoke the invitation to #{invitation.email}"
      end

      assert AccessibleNames.repeated(html, "li a, li button") == []
    end

    test "assigns a custom role to a member", %{conn: conn} do
      colleague = authed_user(:editor)

      {:ok, role} =
        Accounts.create_role(
          %{name: "Assignable", org_id: Accounts.default_org_id()},
          authorize?: false
        )

      {:ok, membership} =
        Accounts.create_org_membership(
          %{
            user_id: colleague.id,
            organization_id: Accounts.default_org_id(),
            role: :editor
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")

      view |> element("#member-#{membership.id} button", "Edit") |> render_click()

      html =
        view
        |> form("#edit-member-#{membership.id}", %{"member" => %{"role_id" => role.id}})
        |> render_submit()

      assert html =~ "Saved."
      assert html =~ "Assignable"
    end

    test "grants and then ends a temporary tier on this site", %{conn: conn} do
      colleague = authed_user(:viewer)

      {:ok, membership} =
        Accounts.create_org_membership(
          %{
            user_id: colleague.id,
            organization_id: Accounts.default_org_id(),
            role: :viewer
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      view |> element("#member-#{membership.id} button", "Edit") |> render_click()

      html =
        view
        |> form("#grant-member-#{membership.id}", %{"role" => "editor", "hours" => "24"})
        |> render_submit()

      assert html =~ "Editor on this site until"

      granted = reread_membership(membership)
      assert granted.granted_role == :editor
      # The standing site tier is untouched — that is what lets the grant expire
      # without anything having to run (see KilnCMS.Accounts.RoleGrant).
      assert granted.role == :viewer

      view |> element("#member-#{membership.id} button", "Edit") |> render_click()
      html = view |> element("#member-#{membership.id} button", "End it now") |> render_click()

      assert html =~ "Temporary tier ended"
      assert is_nil(reread_membership(membership).granted_role)
    end

    test "an explicit expiry wins over the preset on a site tier", %{conn: conn} do
      colleague = authed_user(:viewer)

      {:ok, membership} =
        Accounts.create_org_membership(
          %{
            user_id: colleague.id,
            organization_id: Accounts.default_org_id(),
            role: :viewer
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      view |> element("#member-#{membership.id} button", "Edit") |> render_click()

      until = DateTime.utc_now() |> DateTime.add(9, :day) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      view
      |> form("#grant-member-#{membership.id}", %{
        "role" => "editor",
        "hours" => "24",
        "until" => until
      })
      |> render_submit()

      granted = reread_membership(membership)
      assert granted.granted_role == :editor
      assert DateTime.diff(granted.granted_role_expires_at, DateTime.utc_now(), :day) >= 8
    end

    # A crafted payload — blank role, unparseable date — used to validate as a
    # no-op revoke and then crash formatting a nil expiry for the success flash.
    test "a blank role with a garbage date is refused, not crashed on", %{conn: conn} do
      colleague = authed_user(:viewer)

      {:ok, membership} =
        Accounts.create_org_membership(
          %{
            user_id: colleague.id,
            organization_id: Accounts.default_org_id(),
            role: :viewer
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")

      html =
        render_hook(view, "grant_member_role", %{
          "membership_id" => membership.id,
          "role" => "",
          "hours" => "24",
          "until" => "nope"
        })

      assert html =~ "is required"
      assert is_nil(reread_membership(membership).granted_role)
    end

    test "offers no grant to a member who already holds the top tier", %{conn: conn} do
      colleague = authed_user(:viewer)

      {:ok, membership} =
        Accounts.create_org_membership(
          %{
            user_id: colleague.id,
            organization_id: Accounts.default_org_id(),
            role: :admin
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      html = view |> element("#member-#{membership.id} button", "Edit") |> render_click()

      assert html =~ "already holds the highest tier"
      refute html =~ "grant-member-#{membership.id}"
    end
  end

  describe "scope pickers (#2141)" do
    setup %{conn: conn} do
      admin = authed_user(:admin)
      %{conn: log_in(conn, admin), admin: admin}
    end

    test "creates a custom role through the pickers", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/editor/team")
      post = grant_index(html, "#new-role-form", "post")
      page = grant_index(html, "#new-role-form", "page")

      modes = %{
        "editable_mode" => "only",
        "readable_mode" => "only",
        "grant_mode" => %{post => "only", page => "none"}
      }

      view |> form("#new-role-form", %{"role" => modes}) |> render_change()

      html =
        view
        |> form("#new-role-form", %{
          "role" =>
            Map.merge(modes, %{
              "name" => "Blog editor",
              "description" => "Posts only",
              "editable_types" => ["post"],
              "readable_types" => ["post", "page"],
              "grant_fields" => %{post => ["title", "blocks"]}
            })
        })
        |> render_submit()

      assert html =~ "Role added"
      assert html =~ "fields: Page: none; Post: title, blocks"

      [role] = list_roles()
      assert role.editable_types == ["post"]
      assert role.readable_types == ["post", "page"]
      assert role.field_grants == %{"post" => ["title", "blocks"], "page" => []}
    end

    test "an untouched create stores no restriction on any axis", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/team")

      view |> form("#new-role-form", %{"role" => %{"name" => "Plain"}}) |> render_submit()

      [role] = list_roles()
      assert role.editable_types == []
      assert role.readable_types == []
      assert role.field_grants == %{}
    end

    test "Only with nothing ticked is refused, on a type axis and on a grant row",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/editor/team")
      post = grant_index(html, "#new-role-form", "post")

      view
      |> form("#new-role-form", %{"role" => %{"editable_mode" => "only"}})
      |> render_change()

      html =
        view
        |> form("#new-role-form", %{"role" => %{"name" => "Broken", "editable_mode" => "only"}})
        |> render_submit()

      assert html =~ "Pick at least one type, or choose No restriction from this role."
      assert list_roles() == []

      view
      |> form("#new-role-form", %{
        "role" => %{"editable_mode" => "all", "grant_mode" => %{post => "only"}}
      })
      |> render_change()

      html =
        view
        |> form("#new-role-form", %{
          "role" => %{
            "name" => "Broken",
            "editable_mode" => "all",
            "grant_mode" => %{post => "only"}
          }
        })
        |> render_submit()

      assert html =~ "Pick at least one field, or choose No fields."
      refute html =~ "Pick at least one type"
      assert list_roles() == []
    end

    test "unticking every stored type is refused, not widened to every type",
         %{conn: conn} do
      role = create_role!(%{name: "Narrow", editable_types: ["post"]})

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      view |> element("#role-#{role.id} button", "Edit") |> render_click()

      html =
        view
        |> form("#edit-role-#{role.id}", %{"role" => %{"editable_types" => [""]}})
        |> render_submit()

      assert html =~ "Pick at least one type"
      assert get_role(role).editable_types == ["post"]
    end

    test "the three grant modes store three shapes", %{conn: conn} do
      role =
        create_role!(%{
          name: "Shapes",
          field_grants: %{"post" => ["title"], "page" => ["title"]}
        })

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      html = view |> element("#role-#{role.id} button", "Edit") |> render_click()
      post = grant_index(html, "#edit-role-#{role.id}", "post")
      page = grant_index(html, "#edit-role-#{role.id}", "page")

      view
      |> form("#edit-role-#{role.id}", %{
        "role" => %{"grant_mode" => %{post => "any", page => "none"}}
      })
      |> render_submit()

      grants = get_role(role).field_grants
      refute Map.has_key?(grants, "post")
      assert grants == %{"page" => []}
    end

    test "saving a role untouched changes nothing and sends no update", %{conn: conn} do
      role =
        create_role!(%{
          name: "Steady",
          editable_types: ["post"],
          field_grants: %{"post" => ["title", "blocks"]}
        })

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      view |> element("#role-#{role.id} button", "Edit") |> render_click()
      html = view |> form("#edit-role-#{role.id}") |> render_submit()

      assert html =~ "No changes."
      reread = get_role(role)
      assert reread.updated_at == role.updated_at
      assert reread.field_grants == role.field_grants
    end

    test "stored values the site does not recognize survive every save",
         %{conn: conn, admin: admin} do
      recipe = dynamic_type!(admin, "Recipe")

      stored = %{
        "post" => ["title", "author_id"],
        "deleted_type" => [],
        recipe.name => ["title"]
      }

      role =
        create_role!(%{name: "Legacy", editable_types: ["post", "ghost"], field_grants: stored})

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      html = view |> element("#role-#{role.id} button", "Edit") |> render_click()

      assert html =~ "ghost (not found)"
      assert html =~ "deleted_type (type not found)"
      assert html =~ "author_id (not found)"

      # Untouched: identical, and nothing sent.
      assert view |> form("#edit-role-#{role.id}") |> render_submit() =~ "No changes."
      assert scope(get_role(role)) == {["post", "ghost"], [], stored}

      # Renamed through the form: the scope rides along byte for byte.
      view |> element("#role-#{role.id} button", "Edit") |> render_click()

      view
      |> form("#edit-role-#{role.id}", %{"role" => %{"name" => "Legacy 2"}})
      |> render_submit()

      assert %{name: "Legacy 2"} = reread = get_role(role)
      assert scope(reread) == {["post", "ghost"], [], stored}

      # A post in an older page's shape — no picker modes, raw attribute
      # values — touches nothing it carries no mode for.
      view |> element("#role-#{role.id} button", "Edit") |> render_click()

      render_submit(view, "save_role", %{
        "role" => %{
          "name" => "Legacy 3",
          "editable_types" => "page",
          "readable_types" => "page",
          "field_grants" => "{}"
        }
      })

      assert %{name: "Legacy 3"} = reread = get_role(role)
      assert scope(reread) == {["post", "ghost"], [], stored}

      # Only what is changed changes.
      html = view |> element("#role-#{role.id} button", "Edit") |> render_click()
      deleted = grant_index(html, "#edit-role-#{role.id}", "deleted_type")

      view
      |> form("#edit-role-#{role.id}", %{
        "role" => %{"editable_types" => ["post"], "grant_mode" => %{deleted => "any"}}
      })
      |> render_submit()

      assert scope(get_role(role)) == {["post"], [], Map.delete(stored, "deleted_type")}
    end

    test "custom types: grants by their own name, type axes by the shared key",
         %{conn: conn, admin: admin} do
      recipe = dynamic_type!(admin, "Recipe")

      {:ok, view, html} = live(conn, ~p"/editor/team")

      assert grant_types(html, "#new-role-form") |> Enum.member?(recipe.name)
      refute grant_types(html, "#new-role-form") |> Enum.member?("entry")

      row = grant_index(html, "#new-role-form", recipe.name)
      post = grant_index(html, "#new-role-form", "post")

      html =
        view
        |> form("#new-role-form", %{
          "role" => %{
            "editable_mode" => "only",
            "grant_mode" => %{row => "only", post => "only"}
          }
        })
        |> render_change()

      editable = values(html, ~s(#new-role-form input[name="role[editable_types][]"]))
      assert "entry" in editable
      refute recipe.name in editable
      assert html =~ "Custom content types (all of them)"

      recipe_fields = values(html, ~s(#new-role-form input[name="role[grant_fields][#{row}][]"]))
      assert ["", "title", "blocks" | _] = recipe_fields
      refute "excerpt" in recipe_fields
      refute "type_definition_id" in recipe_fields

      post_fields = values(html, ~s(#new-role-form input[name="role[grant_fields][#{post}][]"]))
      assert "excerpt" in post_fields
      assert "custom_fields" in post_fields
      refute "working_title" in post_fields
      assert html =~ "Custom fields (all of them)"
    end

    test "the member form inherits, and a member's No fields stores []", %{conn: conn} do
      role = create_role!(%{name: "Posts", editable_types: ["post"]})
      colleague = authed_user(:editor)

      membership =
        create_membership!(%{user_id: colleague.id, role: :editor, role_id: role.id})

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      html = view |> element("#member-#{membership.id} button", "Edit") |> render_click()

      assert html =~ "Inherit (custom role, then account)"
      assert html =~ "Currently inherited: post"

      post = grant_index(html, "#edit-member-#{membership.id}", "post")

      view
      |> form("#edit-member-#{membership.id}", %{
        "member" => %{"grant_mode" => %{post => "none"}}
      })
      |> render_submit()

      reread = reread_membership(membership)
      assert reread.field_grants == %{"post" => []}
      assert reread.editable_types == []
      assert reread.role_id == role.id
    end

    test "the inherited hint follows the custom role picked in the form", %{conn: conn} do
      posts = create_role!(%{name: "Posts", editable_types: ["post"]})
      pages = create_role!(%{name: "Pages", editable_types: ["page"]})
      colleague = authed_user(:editor)

      membership =
        create_membership!(%{user_id: colleague.id, role: :editor, role_id: posts.id})

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      view |> element("#member-#{membership.id} button", "Edit") |> render_click()

      html =
        view
        |> form("#edit-member-#{membership.id}", %{"member" => %{"role_id" => pages.id}})
        |> render_change()

      assert html =~ "Currently inherited: page"
      refute html =~ "Currently inherited: post"

      html =
        view
        |> form("#edit-member-#{membership.id}", %{"member" => %{"role_id" => ""}})
        |> render_change()

      refute html =~ "Currently inherited: post"
      refute html =~ "Currently inherited: page"
    end

    test "a create_role push without a role map does not crash the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/team")
      assert render_hook(view, "create_role", %{}) =~ "new-role-form"
    end

    test "every picker control has a name and every group a legend", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/editor/team")
      post = grant_index(html, "#new-role-form", "post")

      html =
        view
        |> form("#new-role-form", %{
          "role" => %{"editable_mode" => "only", "grant_mode" => %{post => "only"}}
        })
        |> render_change()

      assert AccessibleNames.name(html, "#new-role-editable-mode-all") ==
               "No restriction from this role"

      assert AccessibleNames.name(html, "#new-role-editable-mode-only") == "Only these types"
      # Found by value, not position: a project overlay's own types sort first.
      [page_type] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s([id^="new-role-editable-type-"][value="page"]))
        |> LazyHTML.attribute("id")

      assert AccessibleNames.name(html, "##{page_type}") == "Page"
      assert AccessibleNames.name(html, "#new-role-grant-#{post}-field-0") == "Title title"

      assert AccessibleNames.name(html, "#new-role-grant-#{post}-mode") =~
               ~r/^Fields of Post/

      legends =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#new-role-form legend")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert "Content types they may edit" in legends
      assert "Content types they may read in the editor" in legends
      assert "Field grants" in legends
      assert "Fields of Post they may change" in legends
    end
  end

  describe "scope pickers end to end (#2141)" do
    setup %{conn: conn} do
      admin = authed_user(:admin)
      %{conn: log_in(conn, admin), admin: admin}
    end

    test "a picked field grant binds the editors holding the role",
         %{conn: conn, admin: admin} do
      {:ok, view, html} = live(conn, ~p"/editor/team")
      post = grant_index(html, "#new-role-form", "post")
      modes = %{"grant_mode" => %{post => "only"}}

      view |> form("#new-role-form", %{"role" => modes}) |> render_change()

      view
      |> form("#new-role-form", %{
        "role" => Map.merge(modes, %{"name" => "Titles", "grant_fields" => %{post => ["title"]}})
      })
      |> render_submit()

      [role] = list_roles()
      editor = authed_user(:editor)
      create_membership!(%{user_id: editor.id, role: :editor, role_id: role.id})
      doc = KilnCMS.CMS.create_post!(%{title: "Doc", slug: unique_slug()}, actor: admin)

      assert {:ok, doc} = KilnCMS.CMS.update_post(doc, %{title: "Renamed"}, actor: editor)

      assert {:error, %Ash.Error.Invalid{}} =
               KilnCMS.CMS.update_post(doc, %{excerpt: "Nope"}, actor: editor)
    end

    test "No fields stops every field change but not creates or workflow verbs",
         %{conn: conn, admin: admin} do
      {:ok, view, html} = live(conn, ~p"/editor/team")
      post = grant_index(html, "#new-role-form", "post")

      view
      |> form("#new-role-form", %{
        "role" => %{"name" => "Frozen", "grant_mode" => %{post => "none"}}
      })
      |> render_submit()

      [role] = list_roles()
      assert role.field_grants == %{"post" => []}

      editor = authed_user(:editor)
      create_membership!(%{user_id: editor.id, role: :editor, role_id: role.id})
      doc = KilnCMS.CMS.create_post!(%{title: "Doc", slug: unique_slug()}, actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               KilnCMS.CMS.update_post(doc, %{title: "Renamed"}, actor: editor)

      assert {:ok, own} =
               KilnCMS.CMS.create_post(%{title: "Mine", slug: unique_slug()}, actor: editor)

      assert {:ok, _} = KilnCMS.CMS.submit_post_for_review(own, actor: editor)
    end
  end

  defp list_roles,
    do: Accounts.list_roles_for_org!(Accounts.default_org_id(), authorize?: false)

  defp get_role(role), do: Accounts.get_role!(role.id, authorize?: false)

  defp create_role!(attrs) do
    Accounts.create_role!(Map.put(attrs, :org_id, Accounts.default_org_id()), authorize?: false)
  end

  defp create_membership!(attrs) do
    Accounts.create_org_membership!(
      Map.put(attrs, :organization_id, Accounts.default_org_id()),
      authorize?: false
    )
  end

  defp dynamic_type!(admin, label) do
    KilnCMS.CMS.create_type_definition!(
      %{name: "#{String.downcase(label)}#{System.unique_integer([:positive])}", label: label},
      actor: admin
    )
  end

  defp unique_slug, do: "team-#{System.unique_integer([:positive])}"

  defp scope(record), do: {record.editable_types, record.readable_types, record.field_grants}

  # Grant rows post by position; the key rides in a hidden `grant_type` input.
  defp grant_index(html, form, key) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(#{form} input[type="hidden"][name*="[grant_type]"]))
    |> Enum.find_value(fn input ->
      if LazyHTML.attribute(input, "value") == [key] do
        [name] = LazyHTML.attribute(input, "name")
        [_, index] = Regex.run(~r/\[grant_type\]\[(\d+)\]$/, name)
        index
      end
    end) || flunk("no grant row for #{inspect(key)} in #{form}")
  end

  defp grant_types(html, form),
    do: values(html, ~s(#{form} input[type="hidden"][name*="[grant_type]"]))

  # #2142: each row leads with the tier that applies on this site now, as the
  # policies resolve it, and explains the grant that governs it.
  describe "role display" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "a member with a live grant reads as the granted tier, then what it returns to",
         %{conn: conn} do
      colleague = authed_user(:viewer)

      membership =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: colleague.id,
          organization_id: Accounts.default_org_id(),
          role: :viewer,
          granted_role: :editor,
          granted_role_expires_at: in_hours(5)
        })

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      row = "#member-#{membership.id}-role"

      assert badge_text(view, row) == "Editor"
      assert has_element?(view, row, "On this site:")
      assert has_element?(view, "#{row}-grant", "Editor is temporary: until")
      assert has_element?(view, "#{row}-grant", "then Viewer.")
    end

    test "ending a grant redraws the row with the standing tier", %{conn: conn} do
      colleague = authed_user(:viewer)

      membership =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: colleague.id,
          organization_id: Accounts.default_org_id(),
          role: :viewer,
          granted_role: :editor,
          granted_role_expires_at: in_hours(5)
        })

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      row = "#member-#{membership.id}-role"
      assert badge_text(view, row) == "Editor"

      render_click(view, "revoke_member_role", %{"id" => membership.id})

      assert badge_text(view, row) == "Viewer"
      refute has_element?(view, "#{row}-grant")
    end

    test "an expired grant leaves the standing tier and no explanation", %{conn: conn} do
      colleague = authed_user(:viewer)

      membership =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: colleague.id,
          organization_id: Accounts.default_org_id(),
          role: :viewer,
          granted_role: :editor,
          granted_role_expires_at: in_hours(-1)
        })

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      row = "#member-#{membership.id}-role"

      assert badge_text(view, row) == "Viewer"
      refute has_element?(view, "#{row}-grant")
    end

    test "a platform admin's membership row shows admin and the tier it overrides",
         %{conn: conn} do
      other_admin = authed_user(:admin)

      {:ok, membership} =
        Accounts.create_org_membership(
          %{user_id: other_admin.id, organization_id: Accounts.default_org_id(), role: :viewer},
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      row = "#member-#{membership.id}-role"

      assert badge_text(view, row) == "Admin"
      assert has_element?(view, row, "Site tier Viewer, overridden by the platform admin role.")
      assert has_element?(view, "#member-#{membership.id}", "Site admin")
    end

    # A temporary platform admin with no membership here reaches this site only
    # through the grant, so the row says the access ends with it.
    test "a temporary platform admin without a membership is explained", %{conn: conn} do
      temp = authed_user(:viewer)

      Ash.Seed.update!(temp, %{granted_role: :admin, granted_role_expires_at: in_hours(5)})

      {:ok, view, _html} = live(conn, ~p"/editor/team")
      row = "#site-admin-#{temp.id}-role"

      assert badge_text(view, row) == "Admin"
      assert has_element?(view, "#{row}-grant", "Admin is temporary: until")
      # No membership anywhere and this is the default org: the account role.
      assert has_element?(view, "#{row}-grant", "then Viewer.")
    end
  end

  defp values(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  defp in_hours(hours), do: DateTime.add(DateTime.utc_now(), hours, :hour)

  defp badge_text(view, selector) do
    view
    |> element("#{selector}-tier")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp reread_membership(membership) do
    Accounts.get_org_membership!(
      membership.user_id,
      membership.organization_id,
      authorize?: false
    )
  end
end
