defmodule KilnCMS.CMS.DynamicDefaultsTest do
  @moduledoc """
  Dynamic default values (#2286): the guards on a definition's
  `default_source` / `default_field`, and `Changes.ApplyCustomFields` applying
  them on create only — with conditional visibility and field grants.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "dd-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp name(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
  defp slug, do: "dd-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :post, label: "F", field_type: :string}, attrs),
      actor: admin
    )
  end

  defp create(actor, fields),
    do: CMS.create_post(%{title: "T", slug: slug(), custom_fields: fields}, actor: actor)

  defp create!(actor, fields), do: elem(create(actor, fields), 1)

  defp message(fun), do: Exception.message(assert_raise(Ash.Error.Invalid, fun))

  setup do
    %{admin: user(:admin)}
  end

  describe "the guards" do
    test "a source the type can't take is dropped, not refused", %{admin: admin} do
      f = field!(admin, %{name: name("n"), field_type: :integer, default_source: :today})
      assert f.default_source == nil
    end

    test "a source replaces the static default", %{admin: admin} do
      f =
        field!(admin, %{
          name: name("d"),
          field_type: :date,
          default: "2020-01-01",
          default_source: :today
        })

      assert f.default_source == :today
      assert f.default == nil
    end

    test "default_field is kept only for copy_of", %{admin: admin} do
      f =
        field!(admin, %{
          name: name("d"),
          field_type: :date,
          default_source: :today,
          default_field: "x"
        })

      assert f.default_field == nil
    end

    test "copy_of must name a sibling of the same type", %{admin: admin} do
      src = field!(admin, %{name: name("src"), field_type: :string})
      num = field!(admin, %{name: name("num"), field_type: :integer})

      assert message(fn ->
               field!(admin, %{name: name("c"), default_source: :copy_of})
             end) =~ "needs the field to copy"

      assert message(fn ->
               field!(admin, %{name: name("c"), default_source: :copy_of, default_field: "nope"})
             end) =~ "is not a field beside this one"

      assert message(fn ->
               field!(admin, %{name: name("c"), default_source: :copy_of, default_field: num.name})
             end) =~ "is not a single string field"

      ok = field!(admin, %{name: name("c"), default_source: :copy_of, default_field: src.name})
      assert ok.default_field == src.name

      assert message(fn ->
               field!(admin, %{name: name("c2"), default_source: :copy_of, default_field: ok.name})
             end) =~ "itself copies another field"
    end

    test "a public field can't copy a private one", %{admin: admin} do
      src = field!(admin, %{name: name("priv"), private: true})

      assert message(fn ->
               field!(admin, %{name: name("c"), default_source: :copy_of, default_field: src.name})
             end) =~ "is private"
    end
  end

  describe "on create" do
    test "today and now fill a blank or absent field; a supplied value wins", %{admin: admin} do
      day = field!(admin, %{name: name("day"), field_type: :date, default_source: :today})
      at = field!(admin, %{name: name("at"), field_type: :datetime, default_source: :now})

      post = create!(admin, %{})
      today = KilnCMS.CMS.Computed.Context.today() |> Date.to_iso8601()
      assert post.custom_fields[day.name] == today
      assert post.custom_fields[at.name]

      blank = create!(admin, %{day.name => ""})
      assert blank.custom_fields[day.name] == today

      set = create!(admin, %{day.name => "2020-02-02"})
      assert set.custom_fields[day.name] == "2020-02-02"
    end

    test "current_user is the writing person; no actor, no value", %{admin: admin} do
      f = field!(admin, %{name: name("owner"), field_type: :user, default_source: :current_user})

      assert create!(admin, %{}).custom_fields[f.name] == admin.id
    end

    test "site_locale fills a string, and a select only when it is an option", %{admin: admin} do
      locale = KilnCMS.I18n.default_locale()
      s = field!(admin, %{name: name("loc"), default_source: :site_locale})

      sel =
        field!(admin, %{
          name: name("sel"),
          field_type: :select,
          options: ["zz", "yy"],
          default_source: :site_locale
        })

      post = create!(admin, %{})
      assert post.custom_fields[s.name] == locale
      refute Map.has_key?(post.custom_fields, sel.name)
    end

    test "copy_of copies the supplied source, and a blank source copies nothing", %{admin: admin} do
      src = field!(admin, %{name: name("src")})
      copy = field!(admin, %{name: name("cp"), default_source: :copy_of, default_field: src.name})

      assert create!(admin, %{src.name => "hello"}).custom_fields[copy.name] == "hello"

      refute Map.has_key?(create!(admin, %{}).custom_fields, copy.name)

      assert create!(admin, %{src.name => "a", copy.name => "mine"}).custom_fields[copy.name] ==
               "mine"
    end

    test "copy_of of a source that has its own dynamic default copies that", %{admin: admin} do
      day = field!(admin, %{name: name("day"), field_type: :date, default_source: :today})

      copy =
        field!(admin, %{
          name: name("cp"),
          field_type: :date,
          default_source: :copy_of,
          default_field: day.name
        })

      post = create!(admin, %{})
      assert post.custom_fields[copy.name] == post.custom_fields[day.name]
    end
  end

  describe "not on later edits" do
    test "clearing a defaulted field on update leaves it empty", %{admin: admin} do
      f = field!(admin, %{name: name("day"), field_type: :date, default_source: :today})
      post = create!(admin, %{})
      assert post.custom_fields[f.name]

      {:ok, updated} = CMS.update_post(post, %{custom_fields: %{f.name => ""}}, actor: admin)
      refute Map.has_key?(updated.custom_fields, f.name)
    end

    test "a field defined after the record exists is not back-filled", %{admin: admin} do
      post = create!(admin, %{})
      f = field!(admin, %{name: name("day"), field_type: :date, default_source: :today})

      {:ok, updated} = CMS.update_post(post, %{title: "New"}, actor: admin)
      refute Map.has_key?(updated.custom_fields, f.name)

      {:ok, updated} = CMS.update_post(updated, %{custom_fields: %{}}, actor: admin)
      refute Map.has_key?(updated.custom_fields, f.name)
    end
  end

  describe "conditional visibility" do
    test "a field hidden on the new record is not defaulted", %{admin: admin} do
      kind = field!(admin, %{name: name("kind"), field_type: :select, options: ["a", "b"]})

      f =
        field!(admin, %{
          name: name("day"),
          field_type: :date,
          default_source: :today,
          visible_when: %{"field" => kind.name, "op" => "eq", "value" => "a"}
        })

      assert Map.has_key?(create!(admin, %{kind.name => "a"}).custom_fields, f.name)
      refute Map.has_key?(create!(admin, %{kind.name => "b"}).custom_fields, f.name)
    end
  end

  describe "field grants" do
    test "an ungranted field still receives its default on create; a supplied value is judged" do
      admin = user(:admin)
      granted = field!(admin, %{name: name("notes")})
      day = field!(admin, %{name: name("day"), field_type: :date, default_source: :today})
      src = field!(admin, %{name: name("src")})
      copy = field!(admin, %{name: name("cp"), default_source: :copy_of, default_field: src.name})

      editor =
        user(:editor, %{
          field_grants: %{
            "post" => ["custom_fields.#{granted.name}", "custom_fields.#{src.name}"]
          }
        })

      assert {:ok, post} =
               create(editor, %{granted.name => "ok", day.name => "", src.name => "s"})

      assert post.custom_fields[day.name] ==
               KilnCMS.CMS.Computed.Context.today() |> Date.to_iso8601()

      assert post.custom_fields[copy.name] == "s"

      assert {:error, %Ash.Error.Invalid{} = error} = create(editor, %{day.name => "2020-01-01"})
      assert Exception.message(error) =~ "field grant"
    end
  end
end
