defmodule KilnCMS.Accounts.ContentListColumnsTest do
  @moduledoc """
  `User.content_list_columns`: the custom-field columns the content list shows,
  remembered per site and content type. Self-only, merged (never replaced) on
  write, and checked against the site's field definitions.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ListFields
  alias KilnCMS.OrgFixtures

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp define!(admin, org_id, name, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: name, label: name, field_type: :string},
        attrs
      ),
      actor: admin,
      tenant: org_id
    )
  end

  setup do
    org = Accounts.default_org_id()
    admin = user(:admin)
    editor = user(:editor)

    for name <- ~w(price sku color weight stock vendor origin), do: define!(admin, org, name)
    define!(admin, org, "secret_cost", %{field_type: :float, private: true})
    define!(admin, org, "shape", %{field_type: :group})

    %{org: org, admin: admin, editor: editor}
  end

  defp set(user, org, type, names, actor \\ nil),
    do: Accounts.set_content_list_columns(user, org, type, names, actor: actor || user)

  test "an editor remembers columns for a type, and the reader returns them", %{
    org: org,
    editor: editor
  } do
    assert {:ok, saved} = set(editor, org, "page", ["price", "sku"])

    assert saved.content_list_columns == %{org => %{"page" => ["price", "sku"]}}
    assert ListFields.stored_columns(saved, org, "page") == ["price", "sku"]

    assert ListFields.stored_columns(Accounts.get_user!(editor.id, actor: editor), org, "page") ==
             ["price", "sku"]
  end

  test "nothing stored reads as no columns", %{org: org, editor: editor} do
    fresh = Accounts.get_user!(editor.id, actor: editor)

    assert fresh.content_list_columns == nil
    assert ListFields.stored_columns(fresh, org, "page") == []
  end

  test "a second type, and a rewrite of the first, keep the rest", %{
    org: org,
    editor: editor,
    admin: admin
  } do
    define!(admin, org, "sku", %{content_type: :post})

    {:ok, _} = set(editor, org, "page", ["price"])
    {:ok, saved} = set(editor, org, "post", ["sku"])
    {:ok, saved} = set(saved, org, "page", ["color", "price"])

    assert saved.content_list_columns == %{
             org => %{"page" => ["color", "price"], "post" => ["sku"]}
           }

    assert {:ok, cleared} = set(saved, org, "page", [])
    assert cleared.content_list_columns[org] == %{"page" => [], "post" => ["sku"]}
  end

  test "a stale copy of the user and a second site do not clobber each other", %{
    admin: admin,
    org: org
  } do
    other = OrgFixtures.org("cols")
    define!(admin, other.id, "price")

    me = user(:admin)
    stale = Accounts.get_user!(me.id, actor: me)

    {:ok, _} = set(me, org, "page", ["price"])
    # `stale` was read before the first write and carries no map at all.
    assert stale.content_list_columns == nil
    {:ok, saved} = set(stale, other.id, "page", ["price"])

    assert saved.content_list_columns == %{
             org => %{"page" => ["price"]},
             other.id => %{"page" => ["price"]}
           }

    assert Accounts.get_user!(me.id, actor: me).content_list_columns ==
             saved.content_list_columns
  end

  describe "refused writes" do
    test "an unknown field", %{org: org, editor: editor} do
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "page", ["nope"])
      assert Accounts.get_user!(editor.id, actor: editor).content_list_columns == nil
    end

    test "a field the picker does not offer", %{org: org, editor: editor} do
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "page", ["shape"])
    end

    test "a repeated field", %{org: org, editor: editor} do
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "page", ["price", "price"])
    end

    test "more than six fields", %{org: org, editor: editor} do
      names = ~w(price sku color weight stock vendor origin)
      assert length(names) == 7
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "page", names)
      assert {:ok, _} = set(editor, org, "page", Enum.take(names, 6))
    end

    test "names that are not strings", %{org: org, editor: editor} do
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "page", [1, 2])
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "page", [nil])
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "page", [""])
    end

    test "a type the site does not have", %{org: org, editor: editor} do
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "nonesuch", ["price"])
      assert {:error, %Ash.Error.Invalid{}} = set(editor, org, "all", ["price"])
    end

    test "a private field is allowed for an editor (the list is editor-only)", %{
      org: org,
      editor: editor
    } do
      assert {:ok, _} = set(editor, org, "page", ["secret_cost"])
    end

    test "a viewer is refused the private field and every other", %{org: org} do
      viewer = user(:viewer)
      assert {:error, %Ash.Error.Invalid{}} = set(viewer, org, "page", ["price"])
    end

    test "a site the actor does not belong to answers like an unknown field", %{editor: editor} do
      foreign = OrgFixtures.org("foreign")
      assert {:error, %Ash.Error.Invalid{}} = set(editor, foreign.id, "page", ["price"])
    end
  end

  describe "who may write" do
    test "another account is refused", %{org: org, editor: editor} do
      other = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} = set(editor, org, "page", ["price"], other)
      assert Accounts.get_user!(editor.id, actor: editor).content_list_columns == nil
    end

    test "a platform admin may set another account's, like every other action", %{
      org: org,
      editor: editor,
      admin: admin
    } do
      # The resource's admin bypass admits platform admins on every action.
      assert {:ok, _} = set(editor, org, "page", ["price"], admin)
    end

    test "no actor is refused", %{org: org, editor: editor} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.set_content_list_columns(editor, org, "page", ["price"], actor: nil)
    end
  end

  test "the column is behind the self-or-platform-admin field policy", %{} do
    # Row policies already show a non-admin only their own row, so the field
    # policy is the second line (for any future broadened read, e.g. a byline
    # load): it must list the column beside email and role, not leave it to
    # the open `:*` catch-all.
    guarded =
      User
      |> Ash.Policy.Info.field_policies()
      |> Enum.filter(&(:content_list_columns in List.wrap(&1.fields)))

    # (The authentication-interaction bypass lists every field too.)
    assert Enum.any?(guarded, &(not &1.bypass? and :email in &1.fields))
  end
end
