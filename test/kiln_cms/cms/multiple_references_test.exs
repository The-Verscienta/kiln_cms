defmodule KilnCMS.CMS.MultipleReferencesTest do
  @moduledoc """
  Workstream R1 of `docs/relationships-plan.md`: a `:reference` custom field
  with `multiple: true` holds an ordered list of the same
  `%{"id", "type", "slug", "title"}` snapshots a single reference stores, with
  optional `min_items` / `max_items` bounds. Covers the write-time cast, the
  definition rules, the single ↔ list reshape, the `ContentLink` edges, the
  `custom_filter` meaning of `eq`/`in` on a list, and the schema export.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentLink
  alias KilnCMS.SchemaExport

  require Ash.Query

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mref-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "mref-#{System.unique_integer([:positive])}"

  defp page!(admin, title), do: CMS.create_page!(%{title: title, slug: slug()}, actor: admin)

  defp field_name, do: "related_#{System.unique_integer([:positive])}"

  defp list_field!(admin, name, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: name,
          label: "Related",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        attrs
      ),
      actor: admin
    )
  end

  defp post!(admin, fields) do
    CMS.create_post!(%{title: "Referrer", slug: slug(), custom_fields: fields}, actor: admin)
  end

  defp update_post(post, fields, admin),
    do: CMS.update_post(post, %{custom_fields: fields}, actor: admin)

  defp snapshot(page),
    do: %{"id" => page.id, "type" => "page", "slug" => page.slug, "title" => page.title}

  defp ids(value), do: Enum.map(value, & &1["id"])

  defp error_message!(fun) do
    error = assert_raise(Ash.Error.Invalid, fun)
    Exception.message(error)
  end

  # Every edge in the table for `source`, bypassing policy, in field order.
  defp edges(source) do
    ContentLink
    |> Ash.Query.filter(source_id == ^source.id and kind == :reference)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.target_id, &1.position})
  end

  setup do
    admin = admin()
    name = field_name()
    field = list_field!(admin, name)
    %{admin: admin, name: name, field: field}
  end

  describe "the write-time cast" do
    test "a list of ids is snapshotted in order; blanks drop out", %{admin: admin, name: name} do
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)

      post = post!(admin, %{name => ["", c.id, a.id, b.id]})
      assert post.custom_fields[name] == [snapshot(c), snapshot(a), snapshot(b)]

      # The stored list round-trips; snapshots are accepted as input too.
      {:ok, post} = update_post(post, post.custom_fields, admin)
      assert ids(post.custom_fields[name]) == [c.id, a.id, b.id]

      # A lone id (a writer that predates the flag) is a one-item list.
      {:ok, post} = update_post(post, %{name => a.id}, admin)
      assert post.custom_fields[name] == [snapshot(a)]

      # The editor's leading blank alone is an emptied list: the key clears.
      {:ok, post} = update_post(post, %{name => [""]}, admin)
      refute Map.has_key?(post.custom_fields, name)
    end

    test "a target named twice is refused, naming it", %{admin: admin, name: name} do
      a = page!(admin, "A")
      b = page!(admin, "B")

      message = error_message!(fn -> post!(admin, %{name => [a.id, b.id, a.id]}) end)
      assert message =~ "lists #{a.id} more than once"

      # A snapshot and a bare id for the same record are still the same target.
      message = error_message!(fn -> post!(admin, %{name => [snapshot(b), b.id]}) end)
      assert message =~ "lists #{b.id} more than once"
    end

    test "an id that does not resolve fails the field and is named", %{admin: admin, name: name} do
      a = page!(admin, "A")
      gone = Ash.UUID.generate()

      message = error_message!(fn -> post!(admin, %{name => [a.id, gone]}) end)
      assert message =~ "item 2 (#{gone}) is not an existing page record"

      message = error_message!(fn -> post!(admin, %{name => [a.id, "not-a-uuid"]}) end)
      assert message =~ "item 2 (not-a-uuid) is not an existing page record"
    end

    test "a trashed target does not resolve", %{admin: admin, name: name} do
      a = page!(admin, "A")
      CMS.destroy_page!(a, actor: admin)

      assert error_message!(fn -> post!(admin, %{name => [a.id]}) end) =~
               "item 1 (#{a.id}) is not an existing page record"
    end

    test "min_items and max_items bound a list that holds items", %{
      admin: admin,
      name: name,
      field: field
    } do
      [a, b, c, d] = for t <- ~w(A B C D), do: page!(admin, t)
      CMS.update_field_definition!(field, %{min_items: 2, max_items: 3}, actor: admin)

      assert error_message!(fn -> post!(admin, %{name => [a.id]}) end) =~
               "must hold at least 2 items (has 1)"

      assert error_message!(fn -> post!(admin, %{name => [a.id, b.id, c.id, d.id]}) end) =~
               "may hold at most 3 items (has 4)"

      assert ids(post!(admin, %{name => [a.id, b.id]}).custom_fields[name]) == [a.id, b.id]
      assert ids(post!(admin, %{name => [a.id, b.id, c.id]}).custom_fields[name]) |> length() == 3

      # An empty optional list is still allowed: `required` asks for one.
      refute Map.has_key?(post!(admin, %{name => [""]}).custom_fields, name)
    end

    test "a required list refuses an empty list", %{admin: admin, name: name, field: field} do
      CMS.update_field_definition!(field, %{required: true}, actor: admin)
      assert error_message!(fn -> post!(admin, %{name => [""]}) end) =~ "is required"
    end

    test "a single reference keeps its single snapshot, and keeps the first of a list", %{
      admin: admin
    } do
      a = page!(admin, "A")
      b = page!(admin, "B")
      single = field_name()
      list_field!(admin, single, %{multiple: false})

      assert post!(admin, %{single => a.id}).custom_fields[single] == snapshot(a)

      # A value stored while the field was a list — a working copy, a
      # version, an API round-trip — still writes, as the narrowing would.
      assert post!(admin, %{single => ["", a.id, b.id]}).custom_fields[single] == snapshot(a)
    end
  end

  describe "the definition" do
    test "min_items may not exceed max_items", %{admin: admin, field: field} do
      assert {:error, error} =
               CMS.update_field_definition(field, %{min_items: 4, max_items: 2}, actor: admin)

      assert Exception.message(error) =~ "must not be more than the maximum (2)"

      assert {:error, _} = CMS.update_field_definition(field, %{max_items: 0}, actor: admin)
      assert {:error, _} = CMS.update_field_definition(field, %{min_items: -1}, actor: admin)
    end

    test "bounds drop with the flag, and the flag drops off a type that can't hold a list", %{
      admin: admin,
      field: field
    } do
      field = CMS.update_field_definition!(field, %{min_items: 1, max_items: 5}, actor: admin)
      assert {field.min_items, field.max_items} == {1, 5}

      single = CMS.update_field_definition!(field, %{multiple: false}, actor: admin)
      assert {single.min_items, single.max_items} == {nil, nil}

      retyped =
        admin
        |> list_field!(field_name(), %{max_items: 3})
        |> CMS.update_field_definition!(%{field_type: :string, target_type: nil}, actor: admin)

      refute retyped.multiple
      assert retyped.max_items == nil
    end
  end

  describe "flipping single <-> multiple" do
    test "reshapes stored values and their edges", %{admin: admin, name: name, field: field} do
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)
      listed = post!(admin, %{name => [a.id, b.id, c.id]})
      empty = post!(admin, %{})

      assert edges(listed) == [{a.id, 0}, {b.id, 1}, {c.id, 2}]

      # List -> single keeps the first reference, and only its edge.
      field = CMS.update_field_definition!(field, %{multiple: false}, actor: admin)
      assert CMS.get_post!(listed.id, actor: admin).custom_fields[name] == snapshot(a)
      assert CMS.get_post!(empty.id, actor: admin).custom_fields == %{}
      assert edges(listed) == [{a.id, 0}]

      # Single -> list wraps it, losslessly; the edge stays at position 0.
      CMS.update_field_definition!(field, %{multiple: true}, actor: admin)
      assert CMS.get_post!(listed.id, actor: admin).custom_fields[name] == [snapshot(a)]
      assert edges(listed) == [{a.id, 0}]
    end

    test "an emptied list narrows to no value", %{admin: admin, name: name, field: field} do
      a = page!(admin, "A")
      post = post!(admin, %{name => [a.id]})

      # A stored empty list (written outside the editor) clears on narrowing.
      KilnCMS.Repo.query!(
        "UPDATE posts SET custom_fields = jsonb_set(custom_fields, ARRAY[$1::text], '[]') WHERE id = $2",
        [name, Ecto.UUID.dump!(post.id)]
      )

      CMS.update_field_definition!(field, %{multiple: false}, actor: admin)
      refute Map.has_key?(CMS.get_post!(post.id, actor: admin).custom_fields, name)
    end
  end

  describe "edges" do
    test "one per item, at its position; reordering rewrites positions", %{
      admin: admin,
      name: name
    } do
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)
      post = post!(admin, %{name => [a.id, b.id, c.id]})

      assert edges(post) == [{a.id, 0}, {b.id, 1}, {c.id, 2}]

      {:ok, post} = update_post(post, %{name => [c.id, a.id, b.id]}, admin)
      assert edges(post) == [{c.id, 0}, {a.id, 1}, {b.id, 2}]
    end

    test "removing an item drops its edge and shifts the rest", %{admin: admin, name: name} do
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)
      post = post!(admin, %{name => [a.id, b.id, c.id]})

      {:ok, post} = update_post(post, %{name => [a.id, c.id]}, admin)
      assert edges(post) == [{a.id, 0}, {c.id, 1}]

      {:ok, post} = update_post(post, %{name => [""]}, admin)
      assert edges(post) == []
    end

    test "every item is backlinked from its target", %{admin: admin, name: name} do
      a = page!(admin, "A")
      b = page!(admin, "B")
      post = post!(admin, %{name => [a.id, b.id]})

      for target <- [a, b] do
        assert [%{source: %{id: id}}] = CMS.ContentLinks.backlinks(target, actor: admin)
        assert id == post.id
      end
    end
  end

  describe "custom_filter" do
    test "eq means contains, not_eq does not, in contains any", %{admin: admin, name: name} do
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)
      ab = post!(admin, %{name => [a.id, b.id]})
      bc = post!(admin, %{name => [b.id, c.id]})

      list = fn filter ->
        %{custom_filter: %{name => filter}}
        |> CMS.list_posts!(actor: admin)
        |> Enum.map(& &1.id)
        |> Enum.sort()
      end

      assert list.(a.id) == [ab.id]
      assert list.(%{"eq" => b.id}) == Enum.sort([ab.id, bc.id])
      assert list.(%{"in" => [a.id, c.id]}) == Enum.sort([ab.id, bc.id])
      assert list.(%{"in" => []}) == []
      assert list.(%{"not_eq" => c.id, "null" => false}) == [ab.id]
    end

    test "range operators are refused with the list named", %{admin: admin, name: name} do
      assert {:error, error} =
               CMS.list_posts(%{custom_filter: %{name => %{"gt" => "x"}}}, actor: admin)

      assert Exception.message(error) =~ "(list of references) only supports eq/not_eq/in/null"
    end

    test "a single reference keeps matching on its one id", %{admin: admin} do
      a = page!(admin, "A")
      single = field_name()
      list_field!(admin, single, %{multiple: false})
      post = post!(admin, %{single => a.id})
      _other = post!(admin, %{single => page!(admin, "B").id})

      assert %{custom_filter: %{single => a.id}}
             |> CMS.list_posts!(actor: admin)
             |> Enum.map(& &1.id) == [post.id]

      assert %{custom_filter: %{single => %{"in" => [a.id]}}}
             |> CMS.list_posts!(actor: admin)
             |> Enum.map(& &1.id) == [post.id]
    end
  end

  describe "schema export" do
    test "a list of references is an array of snapshots, with its bounds", %{
      admin: admin,
      name: name,
      field: field
    } do
      CMS.update_field_definition!(field, %{min_items: 1, max_items: 4}, actor: admin)
      single = field_name()
      list_field!(admin, single, %{multiple: false})

      properties =
        SchemaExport.json_schema()["$defs"]["content_post"]["properties"]["custom_fields"][
          "properties"
        ]

      list = properties[name]
      assert list["type"] == ["array", "null"]
      assert list["items"]["required"] == ["id", "type"]
      assert Map.keys(list["items"]["properties"]) |> Enum.sort() == ~w(id slug title type)
      assert {list["x-kiln-min-items"], list["x-kiln-max-items"]} == {1, 4}

      # Bounds are annotations, not assertions: a value stored before a bound
      # was tightened would otherwise fail validation.
      refute Map.has_key?(list, "minItems")
      refute Map.has_key?(list, "maxItems")

      # A single reference keeps its 1.0 shape.
      assert properties[single]["type"] == ["object", "null"]
      refute Map.has_key?(properties[single], "x-kiln-max-items")
    end

    test "the TypeScript export types a list of references as an array", %{name: name} do
      ts = SchemaExport.TypeScript.emit(SchemaExport.json_schema())

      assert ts =~
               "#{name}?: Array<{ id: string; slug?: string | null; title?: string | null; type: string }> | null"
    end
  end
end
