defmodule KilnCMSWeb.TeamLiveFieldGrantsTest do
  @moduledoc """
  The roles UI for per-custom-field grants (#2281): nested custom-field
  checkboxes under a type's "Only these fields" picker (write keys), the
  "Custom fields they can read" picker (private fields only), and the guards
  that keep a read grant naming only private fields.
  """
  # async: false — field definitions are created on the shared default org and
  # `PrivateFields.all/1` is cached per org in a global cache.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp seed(role) do
    email = "team-fg-#{System.unique_integer([:positive])}@example.com"

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

  defp field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :post, label: "Field", field_type: :string}, attrs),
      actor: admin
    )
  end

  defp create_role!(attrs),
    do:
      Accounts.create_role!(Map.put(attrs, :org_id, Accounts.default_org_id()), authorize?: false)

  defp get_role(role), do: Accounts.get_role!(role.id, authorize?: false)

  defp list_roles,
    do: Accounts.list_roles_for_org!(Accounts.default_org_id(), authorize?: false)

  setup %{conn: conn} do
    admin = seed(:admin)

    field!(admin, %{name: "notes", label: "Notes"})
    secret = field!(admin, %{name: "secret", label: "Secret", private: true})

    group =
      field!(admin, %{name: "dosages", label: "Dosages", field_type: :group, multiple: true})

    for {name, type} <- [{"amount", :float}, {"unit", :string}] do
      field!(admin, %{
        name: name,
        label: String.capitalize(name),
        field_type: type,
        group_of_id: group.id,
        content_type: nil
      })
    end

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    %{conn: conn, admin: admin, secret: secret}
  end

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

  defp values(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  test "lists the custom fields as nested checkboxes, groups indented", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/editor/team")
    post = grant_index(html, "#new-role-form", "post")

    html =
      view
      |> form("#new-role-form", %{"role" => %{"grant_mode" => %{post => "only"}}})
      |> render_change()

    write = ~s(#new-role-form input[name="role[grant_fields][#{post}][]"])

    assert values(html, write)
           |> Enum.sort()
           |> Enum.filter(&String.starts_with?(&1, "custom_fields")) ==
             Enum.sort([
               "custom_fields",
               "custom_fields.dosages",
               "custom_fields.dosages.amount",
               "custom_fields.dosages.unit",
               "custom_fields.notes",
               "custom_fields.secret"
             ])

    # Labelled by the definition's label, a group's sub-fields indented.
    assert has_element?(view, "li.ml-6 input[value='custom_fields.dosages.unit']")
    refute has_element?(view, "li.ml-6 input[value='custom_fields.notes']")
    assert html =~ "Dosages"
    assert html =~ "Custom fields (all of them)"
  end

  test "ticked custom-field keys round-trip into field_grants", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/editor/team")
    post = grant_index(html, "#new-role-form", "post")
    modes = %{"grant_mode" => %{post => "only"}}

    view |> form("#new-role-form", %{"role" => modes}) |> render_change()

    keys = ["custom_fields.notes", "custom_fields.dosages.unit", "custom_fields.dosages"]

    view
    |> form("#new-role-form", %{
      "role" => Map.merge(modes, %{"name" => "Notes only", "grant_fields" => %{post => keys}})
    })
    |> render_submit()

    [role] = list_roles()
    assert role.field_grants == %{"post" => keys}

    # And the edit form shows them ticked.
    html = view |> element("#role-#{role.id} button", "Edit") |> render_click()
    index = grant_index(html, "#edit-role-#{role.id}", "post")

    checked =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(
        ~s(#edit-role-#{role.id} input[name$="[grant_fields][#{index}][]"][checked])
      )
      |> LazyHTML.attribute("value")

    assert Enum.sort(checked) == Enum.sort(keys)
  end

  test "a stale custom-field name is shown as not found and survives an untouched save",
       %{conn: conn} do
    role =
      create_role!(%{
        name: "Stale",
        field_grants: %{"post" => ["custom_fields.notes", "custom_fields.gone"]}
      })

    {:ok, view, _html} = live(conn, ~p"/editor/team")
    html = view |> element("#role-#{role.id} button", "Edit") |> render_click()

    assert html =~ "custom_fields.gone (not found)"
    refute html =~ "custom_fields.notes (not found)"

    assert view |> form("#edit-role-#{role.id}") |> render_submit() =~ "No changes."
    assert get_role(role).field_grants == role.field_grants
  end

  test "the read picker offers only private fields and saves field_read_grants",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/editor/team")
    post = grant_index(html, "#new-role-form", "post")

    html =
      view
      |> form("#new-role-form", %{"role" => %{"grant_read_mode" => %{post => "only"}}})
      |> render_change()

    assert html =~ "Custom fields they can read"

    offered =
      values(html, ~s(#new-role-form input[name="role[grant_read_fields][#{post}][]"]))
      |> Enum.reject(&(&1 == ""))

    assert Enum.sort(offered) == ["custom_fields", "custom_fields.secret"]

    view
    |> form("#new-role-form", %{
      "role" => %{
        "name" => "No secrets",
        "grant_read_mode" => %{post => "only"},
        "grant_read_fields" => %{post => ["custom_fields.secret"]}
      }
    })
    |> render_submit()

    [role] = list_roles()
    assert role.field_read_grants == %{"post" => ["custom_fields.secret"]}
    assert role.field_grants == %{}
  end

  test "None of them stores [], and All removes the key", %{conn: conn} do
    role = create_role!(%{name: "Read", field_read_grants: %{"post" => ["custom_fields.secret"]}})

    {:ok, view, _html} = live(conn, ~p"/editor/team")
    html = view |> element("#role-#{role.id} button", "Edit") |> render_click()
    post = grant_index(html, "#edit-role-#{role.id}", "post")

    view
    |> form("#edit-role-#{role.id}", %{"role" => %{"grant_read_mode" => %{post => "none"}}})
    |> render_submit()

    assert get_role(role).field_read_grants == %{"post" => []}

    view |> element("#role-#{role.id} button", "Edit") |> render_click()

    view
    |> form("#edit-role-#{role.id}", %{"role" => %{"grant_read_mode" => %{post => "any"}}})
    |> render_submit()

    assert get_role(role).field_read_grants == %{}
  end

  test "Only these private fields with nothing ticked is refused", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/editor/team")
    post = grant_index(html, "#new-role-form", "post")
    params = %{"grant_read_mode" => %{post => "only"}}

    view |> form("#new-role-form", %{"role" => params}) |> render_change()

    html =
      view
      |> form("#new-role-form", %{"role" => Map.put(params, "name", "Broken")})
      |> render_submit()

    assert html =~ "Pick at least one field, or choose None of them."
    assert list_roles() == []
  end

  test "a read grant survives an unrelated save, stale names included", %{conn: conn} do
    stored = %{"post" => ["custom_fields.secret", "custom_fields.gone"]}
    role = create_role!(%{name: "Keeps", field_read_grants: stored})

    {:ok, view, _html} = live(conn, ~p"/editor/team")
    html = view |> element("#role-#{role.id} button", "Edit") |> render_click()
    assert html =~ "custom_fields.gone (not found)"
    assert view |> form("#edit-role-#{role.id}") |> render_submit() =~ "No changes."

    view |> element("#role-#{role.id} button", "Edit") |> render_click()

    view
    |> form("#edit-role-#{role.id}", %{"role" => %{"name" => "Renamed"}})
    |> render_submit()

    assert %{name: "Renamed", field_read_grants: ^stored} = get_role(role)
  end

  describe "the guards" do
    test "a read grant naming a non-private field is refused; a stale name is not" do
      attrs = %{name: "Bad", org_id: Accounts.default_org_id()}

      assert {:error, error} =
               Accounts.create_role(
                 Map.put(attrs, :field_read_grants, %{"post" => ["custom_fields.notes"]}),
                 authorize?: false
               )

      assert Exception.message(error) =~ "not a private custom field"

      assert {:ok, _} =
               Accounts.create_role(
                 Map.put(attrs, :field_read_grants, %{
                   "post" => ["custom_fields.secret", "custom_fields.gone", "custom_fields"]
                 }),
                 authorize?: false
               )
    end

    test "a field named in a read grant cannot stop being private",
         %{admin: admin, secret: secret} do
      role =
        create_role!(%{name: "Holds", field_read_grants: %{"post" => ["custom_fields.secret"]}})

      assert {:error, error} =
               CMS.update_field_definition(secret, %{private: false}, actor: admin)

      assert Exception.message(error) =~ "read grant"

      # Other edits to it are fine, and once the grant is gone so is the guard.
      assert {:ok, secret} =
               CMS.update_field_definition(secret, %{label: "Renamed"}, actor: admin)

      Accounts.update_role!(role, %{field_read_grants: %{}}, authorize?: false)

      assert {:ok, %{private: false}} =
               CMS.update_field_definition(secret, %{private: false}, actor: admin)
    end
  end
end
