defmodule KilnCMS.CMS.ScalarListFieldsTest do
  @moduledoc """
  A record-level scalar field that holds a list (#2289): numbers, dates,
  times, links, addresses, phone numbers, colours and slugs
  (`KilnCMS.CMS.ScalarLists`). The definition rules (`Changes.ClearMultiple`),
  the write path (`Changes.ApplyCustomFields`), reshaping on a flip
  (`Changes.SyncFieldValues`), and the conditions guard on a list
  (`Validations.FieldCondition`).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ScalarLists

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sl-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(attrs, actor) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: "f#{System.unique_integer([:positive])}", label: "F"},
        attrs
      ),
      actor: actor
    )
  end

  defp list!(type, admin, attrs \\ %{}),
    do: define!(Map.merge(%{field_type: type, multiple: true, label: "List"}, attrs), admin)

  defp slug, do: "sl-#{System.unique_integer([:positive])}"

  defp page!(fields, actor),
    do: CMS.create_page!(%{title: "P", slug: slug(), custom_fields: fields}, actor: actor)

  defp page(fields, actor),
    do: CMS.create_page(%{title: "P", slug: slug(), custom_fields: fields}, actor: actor)

  defp stored(page, field, admin),
    do: CMS.get_page!(page.id, actor: admin).custom_fields[field.name]

  describe "ScalarLists" do
    test "typed lists are every scalar list type but phrases and terms" do
      assert ScalarLists.typed() == ScalarLists.types() -- [:string, :select]
      refute ScalarLists.distinct?(:integer)
      refute ScalarLists.distinct?(:float)
      assert ScalarLists.distinct?(:date)
      refute ScalarLists.distinct?(:boolean)
      assert ScalarLists.ordered?(:time)
      refute ScalarLists.ordered?(:url)
      assert ScalarLists.text?(:email)
      refute ScalarLists.text?(:color)
    end
  end

  describe "the definition" do
    test "keeps multiple and its bounds on every typed list at record level" do
      admin = admin()

      for type <- ScalarLists.typed() do
        field = list!(type, admin, %{min_items: 1, max_items: 4})

        assert {type, true, 1, 4} == {type, field.multiple, field.min_items, field.max_items}
      end
    end

    test "is cleared on a link field and a group sub-field" do
      admin = admin()

      parent =
        define!(
          %{field_type: :reference, target_type: "page", multiple: true, label: "Links"},
          admin
        )

      group = define!(%{field_type: :group, multiple: true, label: "Rows"}, admin)

      for {type, position} <- Enum.with_index([:integer, :date, :url]) do
        link =
          CMS.create_field_definition!(
            %{
              link_of_id: parent.id,
              position: position,
              name: "l#{type}",
              label: "L",
              field_type: type,
              multiple: true,
              max_items: 3
            },
            actor: admin
          )

        sub =
          CMS.create_field_definition!(
            %{
              group_of_id: group.id,
              name: "s#{type}",
              label: "S",
              field_type: type,
              multiple: true,
              max_items: 3
            },
            actor: admin
          )

        refute link.multiple
        refute sub.multiple
        assert is_nil(link.max_items) and is_nil(sub.max_items)
      end
    end

    test "is cleared on a type that cannot hold a list" do
      admin = admin()

      for {type, extra} <- [
            boolean: %{},
            text: %{},
            json: %{},
            range: %{},
            geolocation: %{},
            recurrence: %{},
            computed: %{compute: "{{ title }}"}
          ] do
        field = list!(type, admin, Map.put(extra, :max_items, 3))

        assert {type, false, nil} == {type, field.multiple, field.max_items}
      end
    end

    test "bounds are cleared when the field is not multiple" do
      field = define!(%{field_type: :integer, min_items: 1, max_items: 3}, admin())

      refute field.multiple
      assert is_nil(field.min_items) and is_nil(field.max_items)
    end

    test "unique is still refused on a list" do
      assert {:error, error} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "u#{System.unique_integer([:positive])}",
                   label: "U",
                   field_type: :integer,
                   multiple: true,
                   validation: %{"unique" => true}
                 },
                 actor: admin()
               )

      assert Exception.message(error) =~ "holds several values"
    end
  end

  describe "writes" do
    test "an integer list keeps repeats and order, from strings or numbers" do
      admin = admin()
      field = list!(:integer, admin)

      assert page!(%{field.name => ["", "3", 3, " 7 "]}, admin).custom_fields[field.name] ==
               [3, 3, 7]
    end

    test "a float list keeps repeats" do
      admin = admin()
      field = list!(:float, admin)

      assert page!(%{field.name => ["1.5", 1.5, 2]}, admin).custom_fields[field.name] ==
               [1.5, 1.5, 2.0]
    end

    test "dates, datetimes, links, addresses and colours are normalised, then deduped" do
      admin = admin()

      for {type, given, expected} <- [
            {:date, ["2026-03-01", "2026-03-01", "2026-01-05"], ["2026-03-01", "2026-01-05"]},
            {:datetime, ["2026-03-01T10:00", "2026-03-01T10:00:00"], ["2026-03-01T10:00:00"]},
            {:url, [" https://a.example ", "https://a.example"], ["https://a.example"]},
            {:email, ["Ann@Example.COM", "Ann@example.com"], ["Ann@example.com"]},
            {:color, ["#FFF", "#ffffff", "#000000"], ["#ffffff", "#000000"]},
            {:time, ["9:30", "09:30:00", "17:00"], ["09:30", "17:00"]}
          ] do
        field = list!(type, admin)

        assert {type, page!(%{field.name => given}, admin).custom_fields[field.name]} ==
                 {type, expected}
      end
    end

    test "an invalid item is refused and named by its position" do
      admin = admin()
      field = list!(:date, admin)

      assert {:error, error} = page(%{field.name => ["2026-03-01", "soon"]}, admin)
      assert Exception.message(error) =~ "item 2 must be a date (YYYY-MM-DD)"

      email = list!(:email, admin)
      assert {:error, error} = page(%{email.name => ["a@b.example", "nope"]}, admin)
      assert Exception.message(error) =~ "item 2 must be"
    end

    test "refuses a JSON-encoded list and an item that is not a value" do
      admin = admin()
      field = list!(:integer, admin)

      assert {:error, error} = page(%{field.name => ~s([1, 2])}, admin)
      assert Exception.message(error) =~ "JSON-encoded list"

      assert {:error, error} = page(%{field.name => [%{"value" => 1}]}, admin)
      assert Exception.message(error) =~ "must be a list of values"

      assert {:error, error} = page(%{field.name => [1, false]}, admin)
      assert Exception.message(error) =~ "must be a list of values"
    end

    test "a bare value is a one-item list; a multi-line item is one item per line" do
      admin = admin()
      field = list!(:integer, admin)

      assert page!(%{field.name => 7}, admin).custom_fields[field.name] == [7]
      assert page!(%{field.name => "7"}, admin).custom_fields[field.name] == [7]

      urls = list!(:url, admin)

      assert page!(%{urls.name => ["https://a.example\nhttps://b.example\r\n"]}, admin).custom_fields[
               urls.name
             ] == ["https://a.example", "https://b.example"]
    end

    test "an emptied list (the lone sentinel) stores nothing" do
      admin = admin()
      field = list!(:date, admin)

      refute Map.has_key?(page!(%{field.name => [""]}, admin).custom_fields, field.name)
    end

    test "required asks for at least one item" do
      admin = admin()
      field = list!(:integer, admin, %{required: true})

      assert {:error, error} = page(%{field.name => [""]}, admin)
      assert Exception.message(error) =~ "is required"
    end

    test "holds the item bounds" do
      admin = admin()
      field = list!(:integer, admin, %{min_items: 2, max_items: 3})

      assert {:error, error} = page(%{field.name => [1]}, admin)
      assert Exception.message(error) =~ "needs at least 2 items"

      assert {:error, error} = page(%{field.name => [1, 2, 3, 4]}, admin)
      assert Exception.message(error) =~ "at most 3 items"
    end

    test "value constraints apply to each item, named by its index" do
      admin = admin()
      field = list!(:integer, admin, %{label: "Scores", validation: %{"max" => 10}})

      assert {:error, error} = page(%{field.name => [3, 11]}, admin)
      assert Exception.message(error) =~ "(#{field.name}[1]) must be at most 10"
    end

    test "an item already stored is not re-checked when a constraint tightens" do
      admin = admin()
      field = list!(:integer, admin, %{label: "Scores", validation: %{"max" => 10}})
      page = page!(%{field.name => [5, 8]}, admin)

      CMS.update_field_definition!(field, %{validation: %{"max" => 6}}, actor: admin)

      assert {:ok, page} =
               CMS.update_page(page, %{custom_fields: %{field.name => [5, 8, 3]}}, actor: admin)

      assert page.custom_fields[field.name] == [5, 8, 3]

      # A new item is still checked.
      assert {:error, error} =
               CMS.update_page(page, %{custom_fields: %{field.name => [5, 8, 3, 9]}},
                 actor: admin
               )

      assert Exception.message(error) =~ "(#{field.name}[3]) must be at most 6"
    end

    test "a default is coerced to a one-item list" do
      admin = admin()
      field = list!(:integer, admin, %{default: "5"})

      assert page!(%{}, admin).custom_fields[field.name] == [5]
    end
  end

  describe "a single field handed a list" do
    test "keeps the first item, from a write or a value stored while it was a list" do
      admin = admin()

      for {type, given, expected} <- [
            {:integer, ["", "3", "4"], 3},
            {:date, ["2026-03-01", "2026-04-01"], "2026-03-01"},
            {:email, ["a@Example.com", "b@example.com"], "a@example.com"},
            {:url, ["https://a.example", "https://b.example"], "https://a.example"}
          ] do
        field = define!(%{field_type: type}, admin)

        assert {type, page!(%{field.name => given}, admin).custom_fields[field.name]} ==
                 {type, expected}
      end
    end

    test "refuses a map item rather than raising" do
      admin = admin()
      field = define!(%{field_type: :integer}, admin)

      assert {:error, error} = page(%{field.name => [%{"value" => 1}]}, admin)
      assert Exception.message(error) =~ "must be a single value"
    end
  end

  describe "flipping between one value and a list" do
    test "single → list wraps each stored number; list → single keeps the first" do
      admin = admin()
      field = define!(%{field_type: :integer}, admin)
      one = page!(%{field.name => 4}, admin)

      field = CMS.update_field_definition!(field, %{multiple: true}, actor: admin)
      assert stored(one, field, admin) == [4]

      two = page!(%{field.name => [9, 2]}, admin)

      CMS.update_field_definition!(field, %{multiple: false}, actor: admin)
      assert stored(two, field, admin) == 9
      assert stored(one, field, admin) == 4
    end

    test "single → list wraps a stored date" do
      admin = admin()
      field = define!(%{field_type: :date}, admin)
      page = page!(%{field.name => "2026-03-01"}, admin)

      CMS.update_field_definition!(field, %{multiple: true}, actor: admin)
      assert stored(page, field, admin) == ["2026-03-01"]
    end

    test "retyping a string into a list of dates leaves its values for the converter" do
      admin = admin()
      field = define!(%{field_type: :string}, admin)
      page = page!(%{field.name => "2026-03-01"}, admin)

      CMS.update_field_definition!(field, %{field_type: :date, multiple: true}, actor: admin)
      assert stored(page, field, admin) == "2026-03-01"
    end
  end

  describe "conditions on a list" do
    defp rule(field, op, value), do: %{"field" => field.name, "op" => op, "value" => value}

    test "greater/less than is refused on a list" do
      admin = admin()
      scores = list!(:integer, admin)

      assert {:error, error} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "n#{System.unique_integer([:positive])}",
                   label: "N",
                   field_type: :string,
                   visible_when: rule(scores, "gt", 1)
                 },
                 actor: admin
               )

      assert Exception.message(error) =~ "it holds a list"

      # Equality still reads a list (contains).
      assert %{visible_when: %{"op" => "eq"}} =
               define!(%{field_type: :string, visible_when: rule(scores, "eq", 1)}, admin)
    end

    test "making a field a list is refused while a rule orders on it" do
      admin = admin()
      count = define!(%{field_type: :integer, label: "Count"}, admin)

      define!(
        %{field_type: :string, label: "Note", required_when: rule(count, "gt", 2)},
        admin
      )

      assert {:error, error} =
               CMS.update_field_definition(count, %{multiple: true}, actor: admin)

      assert Exception.message(error) =~ "Note reads this field in its condition"
      assert Exception.message(error) =~ "it holds a list"

      # An edit that leaves it single is fine.
      assert %{label: "Total"} =
               CMS.update_field_definition!(count, %{label: "Total"}, actor: admin)
    end

    test "making a field a list is fine when the rules only test equality" do
      admin = admin()
      count = define!(%{field_type: :integer, label: "Count"}, admin)
      define!(%{field_type: :string, visible_when: rule(count, "eq", 2)}, admin)

      assert %{multiple: true} =
               CMS.update_field_definition!(count, %{multiple: true}, actor: admin)
    end
  end
end
