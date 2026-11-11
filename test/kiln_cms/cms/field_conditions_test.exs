defmodule KilnCMS.CMS.FieldConditionsTest do
  @moduledoc """
  Conditional custom fields (#2277) end to end on the server: the guards on a
  definition's `visible_when` / `required_when`, their enforcement by
  `Changes.ApplyCustomFields` (top level and per group row), and how a rename,
  a delete and a retype of a field other rules read are handled.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cond-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp name(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
  defp slug, do: "cond-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs) do
    CMS.create_field_definition!(Map.merge(%{content_type: :post, label: "F"}, attrs),
      actor: admin
    )
  end

  defp eq(field, value), do: %{"field" => field, "op" => "eq", "value" => value}

  defp error_message!(fun) do
    error = assert_raise(Ash.Error.Invalid, fun)
    Exception.message(error)
  end

  defp post!(admin, fields),
    do: CMS.create_post!(%{title: "T", slug: slug(), custom_fields: fields}, actor: admin)

  defp post(admin, fields),
    do: CMS.create_post(%{title: "T", slug: slug(), custom_fields: fields}, actor: admin)

  setup do
    admin = user(:admin)
    kind = field!(admin, %{name: name("kind"), field_type: :select, options: ["a", "other"]})
    %{admin: admin, kind: kind}
  end

  describe "the guards" do
    test "a rule that names a sibling is accepted and stored", %{admin: admin, kind: kind} do
      rule = eq(kind.name, "other")
      note = field!(admin, %{name: name("note"), visible_when: rule, required_when: rule})

      assert note.visible_when == rule
      assert note.required_when == rule
    end

    test "a bad shape is refused", %{admin: admin} do
      assert error_message!(fn ->
               field!(admin, %{name: name("n"), visible_when: %{"field" => "x", "op" => "like"}})
             end) =~ "not a valid condition"
    end

    test "an unknown field is refused", %{admin: admin} do
      assert error_message!(fn ->
               field!(admin, %{name: name("n"), required_when: eq("nope", "x")})
             end) =~ "which is not a field beside this one"
    end

    test "a field can't depend on itself", %{admin: admin} do
      own = name("self")

      assert error_message!(fn ->
               field!(admin, %{name: own, visible_when: eq(own, "x")})
             end) =~ "itself"
    end

    test "a cycle through other fields is refused", %{admin: admin, kind: kind} do
      a = field!(admin, %{name: name("a"), visible_when: eq(kind.name, "other")})
      b = field!(admin, %{name: name("b"), visible_when: eq(a.name, "x")})

      assert error_message!(fn ->
               CMS.update_field_definition!(a, %{visible_when: eq(b.name, "x")}, actor: admin)
             end) =~ "depend on itself"
    end

    test "private and non-scalar fields can't be read", %{admin: admin} do
      secret = field!(admin, %{name: name("secret"), private: true})
      media = field!(admin, %{name: name("pic"), field_type: :media})

      assert error_message!(fn ->
               field!(admin, %{name: name("n"), visible_when: eq(secret.name, "x")})
             end) =~ "private field"

      assert error_message!(fn ->
               field!(admin, %{name: name("n"), visible_when: eq(media.name, "x")})
             end) =~ "no simple value to test"
    end

    test "greater/less than needs a number or a date", %{admin: admin, kind: kind} do
      rule = %{"field" => kind.name, "op" => "gt", "value" => 1}

      assert error_message!(fn ->
               field!(admin, %{name: name("n"), required_when: rule})
             end) =~ "greater/less than"

      count = field!(admin, %{name: name("count"), field_type: :integer})
      rule = %{"field" => count.name, "op" => "gt", "value" => 1}
      assert %{required_when: ^rule} = field!(admin, %{name: name("n"), required_when: rule})
    end

    test "link, computed and group fields carry no conditions", %{admin: admin, kind: kind} do
      rule = eq(kind.name, "other")

      assert error_message!(fn ->
               field!(admin, %{
                 name: name("c"),
                 field_type: :computed,
                 compute: "{{ title }}",
                 visible_when: rule
               })
             end) =~ "not available for a computed field"

      assert error_message!(fn ->
               field!(admin, %{name: name("g"), field_type: :group, visible_when: rule})
             end) =~ "not available for a group field"

      ref = field!(admin, %{name: name("r"), field_type: :reference, target_type: "page"})

      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{link_of_id: ref.id, name: "qty", label: "Qty", visible_when: rule},
                 actor: admin
               )
             end) =~ "not available for a link field"
    end

    test "an editor can't write a condition", %{kind: kind} do
      editor = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_field_definition(
                 %{
                   content_type: :post,
                   name: name("n"),
                   label: "N",
                   visible_when: eq(kind.name, "other")
                 },
                 actor: editor
               )
    end
  end

  describe "visible_when" do
    setup %{admin: admin, kind: kind} do
      note =
        field!(admin, %{
          name: name("note"),
          required: true,
          visible_when: eq(kind.name, "other")
        })

      %{note: note}
    end

    test "a hidden field is not required", %{admin: admin, kind: kind, note: note} do
      assert post!(admin, %{kind.name => "a"}).custom_fields |> Map.has_key?(note.name) == false
    end

    test "a shown field is", %{admin: admin, kind: kind, note: note} do
      assert error_message!(fn -> post!(admin, %{kind.name => "other"}) end) =~ "is required"

      post = post!(admin, %{kind.name => "other", note.name => "why"})
      assert post.custom_fields[note.name] == "why"
    end

    test "hiding keeps the stored value", %{admin: admin, kind: kind, note: note} do
      post = post!(admin, %{kind.name => "other", note.name => "kept"})
      post = CMS.update_post!(post, %{custom_fields: %{kind.name => "a"}}, actor: admin)

      assert post.custom_fields[note.name] == "kept"
      assert post.custom_fields[kind.name] == "a"
    end

    test "a value supplied for a hidden field is still validated", %{admin: admin, kind: kind} do
      count =
        field!(admin, %{
          name: name("count"),
          field_type: :integer,
          visible_when: eq(kind.name, "other")
        })

      assert {:error, _} = post(admin, %{kind.name => "a", count.name => "not a number"})
      assert {:ok, _} = post(admin, %{kind.name => "a", count.name => "3"})
    end
  end

  describe "required_when" do
    setup %{admin: admin, kind: kind} do
      why = field!(admin, %{name: name("why"), required_when: eq(kind.name, "other")})
      %{why: why}
    end

    test "blocks a write while the rule holds", %{admin: admin, kind: kind, why: why} do
      assert error_message!(fn -> post!(admin, %{kind.name => "other"}) end) =~ "is required"
      assert {:ok, _} = post(admin, %{kind.name => "a"})
      assert {:ok, _} = post(admin, %{kind.name => "other", why.name => "because"})
    end

    test "reads the stored value of a field an update leaves out", %{
      admin: admin,
      kind: kind,
      why: why
    } do
      post = post!(admin, %{kind.name => "a"})

      # `kind` is stored as "a"; only `why` is sent, and the rule still sees "a".
      assert {:ok, _} = CMS.update_post(post, %{custom_fields: %{why.name => ""}}, actor: admin)

      assert {:error, _} =
               CMS.update_post(post, %{custom_fields: %{kind.name => "other"}}, actor: admin)
    end

    test "a copy that drops unknown keys skips required_when", %{admin: admin, kind: kind} do
      assert {:ok, _} =
               CMS.create_post(
                 %{title: "T", slug: slug(), custom_fields: %{kind.name => "other"}},
                 actor: admin,
                 context: %{custom_fields: :drop}
               )
    end

    test "a record saved before the rule is not rechecked by an unrelated write", %{
      admin: admin,
      kind: kind
    } do
      # Saved while no rule existed: simulate by seeding the stored value.
      post = post!(admin, %{kind.name => "a"})
      post = Ash.Seed.update!(post, %{custom_fields: %{kind.name => "other"}})

      assert {:ok, _} = CMS.update_post(post, %{title: "Renamed"}, actor: admin)
    end
  end

  describe "group sub-fields" do
    setup %{admin: admin} do
      group = field!(admin, %{name: name("doses"), field_type: :group, multiple: true})

      unit =
        field!(admin, %{
          content_type: nil,
          group_of_id: group.id,
          name: "unit",
          field_type: :select,
          options: ["g", "drop"]
        })

      per =
        field!(admin, %{
          content_type: nil,
          group_of_id: group.id,
          name: "per",
          field_type: :string,
          required_when: eq("unit", "drop")
        })

      %{group: group, unit: unit, per: per}
    end

    test "required_when is judged per row", %{admin: admin, group: group} do
      ok = [%{"unit" => "g"}, %{"unit" => "drop", "per" => "day"}]
      assert {:ok, _} = post(admin, %{group.name => ok})

      message =
        error_message!(fn ->
          post!(admin, %{group.name => [%{"unit" => "g"}, %{"unit" => "drop"}]})
        end)

      assert message =~ "#{group.name}[1].per"
    end

    test "a sub-field may read only its group's siblings", %{
      admin: admin,
      kind: kind,
      group: group
    } do
      assert error_message!(fn ->
               field!(admin, %{
                 content_type: nil,
                 group_of_id: group.id,
                 name: "other",
                 field_type: :string,
                 visible_when: eq(kind.name, "x")
               })
             end) =~ "which is not a field beside this one"
    end

    test "a top-level field can't read a sub-field", %{admin: admin, group: group} do
      assert error_message!(fn ->
               field!(admin, %{name: name("n"), visible_when: eq("unit", "g")})
             end) =~ "not a field beside this one"

      assert group.id
    end
  end

  describe "rename, delete and retype of a field other rules read" do
    setup %{admin: admin, kind: kind} do
      note =
        field!(admin, %{
          name: name("note"),
          visible_when: eq(kind.name, "other"),
          required_when: %{
            "all" => [eq(kind.name, "other"), %{"field" => kind.name, "op" => "not_empty"}]
          }
        })

      %{note: note}
    end

    test "rename rewrites the rules that read it", %{admin: admin, kind: kind, note: note} do
      renamed = name("renamed")
      CMS.update_field_definition!(kind, %{name: renamed}, actor: admin)

      reloaded =
        :post |> CMS.field_definitions_for!(actor: admin) |> Enum.find(&(&1.id == note.id))

      assert reloaded.visible_when == eq(renamed, "other")

      assert reloaded.required_when ==
               %{"all" => [eq(renamed, "other"), %{"field" => renamed, "op" => "not_empty"}]}
    end

    test "deleting a field that is read is refused, naming the readers", %{
      admin: admin,
      kind: kind,
      note: note
    } do
      assert error_message!(fn -> CMS.destroy_field_definition!(kind, actor: admin) end) =~
               "used in the conditions of F"

      CMS.destroy_field_definition!(note, actor: admin)
      assert :ok = CMS.destroy_field_definition(kind, actor: admin)
    end

    test "retyping it to something a rule can't read is refused", %{admin: admin, kind: kind} do
      assert error_message!(fn ->
               CMS.update_field_definition!(kind, %{field_type: :media}, actor: admin)
             end) =~ "reads this field in its condition"

      assert error_message!(fn ->
               CMS.update_field_definition!(kind, %{private: true}, actor: admin)
             end) =~ "private field"

      # A retype that keeps every rule valid is fine.
      assert %{field_type: :string} =
               CMS.update_field_definition!(kind, %{field_type: :string}, actor: admin)
    end
  end
end
