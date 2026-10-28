defmodule KilnCMS.CMS.SelectAndTextFieldsTest do
  @moduledoc """
  A `:select` that holds several terms (`multiple`, with an open vocabulary
  under `allow_custom`) and a `:text` field's `format` (rich HTML, sanitized
  on write, or plain): the definition rules, the write path
  (`Changes.ApplyCustomFields`), reshaping on a flip (`SyncFieldValues`),
  filtering, and the picker's terms in use (`SelectTerms`).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SelectTerms
  alias KilnCMS.CMS.TextFormat

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "st-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(attrs, actor) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, name: "f#{System.unique_integer([:positive])}"}, attrs),
      actor: actor
    )
  end

  defp slug, do: "st-#{System.unique_integer([:positive])}"

  defp page!(fields, actor),
    do: CMS.create_page!(%{title: "P", slug: slug(), custom_fields: fields}, actor: actor)

  defp page(fields, actor),
    do: CMS.create_page(%{title: "P", slug: slug(), custom_fields: fields}, actor: actor)

  defp terms_field!(admin, attrs \\ %{}) do
    define!(
      Map.merge(
        %{
          label: "Properties",
          field_type: :select,
          multiple: true,
          options: ~w(adaptogen tonic stimulant)
        },
        attrs
      ),
      admin
    )
  end

  describe "a select holding several terms — the definition" do
    test "keeps multiple and its bounds on a select" do
      field = terms_field!(admin(), %{min_items: 1, max_items: 3})

      assert field.multiple
      assert field.min_items == 1
      assert field.max_items == 3
    end

    test "allow_custom survives only on a multiple select" do
      admin = admin()

      assert terms_field!(admin, %{allow_custom: true}).allow_custom

      single =
        define!(
          %{label: "Grade", field_type: :select, options: ~w(a b), allow_custom: true},
          admin
        )

      refute single.allow_custom

      text = define!(%{label: "Notes", field_type: :text, allow_custom: true}, admin)
      refute text.allow_custom
    end

    test "an open vocabulary may start with no options; a fixed one may not" do
      admin = admin()

      assert terms_field!(admin, %{options: [], allow_custom: true}).options == []

      assert {:error, error} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "fixed#{System.unique_integer([:positive])}",
                   label: "Fixed",
                   field_type: :select,
                   multiple: true,
                   options: []
                 },
                 actor: admin
               )

      assert Exception.message(error) =~ "at least one option"

      # A single select cannot open its vocabulary, so it still needs options.
      assert {:error, _} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "single#{System.unique_integer([:positive])}",
                   label: "Single",
                   field_type: :select,
                   options: [],
                   allow_custom: true
                 },
                 actor: admin
               )
    end

    test "a group's select sub-field holds one value" do
      admin = admin()
      group = define!(%{label: "Dosages", field_type: :group, multiple: true}, admin)

      sub =
        CMS.create_field_definition!(
          %{
            group_of_id: group.id,
            name: "unit",
            label: "Unit",
            field_type: :select,
            options: ~w(g mg),
            multiple: true,
            allow_custom: true
          },
          actor: admin
        )

      refute sub.multiple
      refute sub.allow_custom
    end
  end

  describe "a select holding several terms — writes" do
    test "stores the terms as a list: trimmed, blanks and repeats dropped, order kept" do
      admin = admin()
      field = terms_field!(admin)

      page = page!(%{field.name => ["", " tonic ", "adaptogen", "tonic"]}, admin)

      assert page.custom_fields[field.name] == ["tonic", "adaptogen"]
    end

    test "a single string is a one-term list" do
      admin = admin()
      field = terms_field!(admin)

      assert page!(%{field.name => "tonic"}, admin).custom_fields[field.name] == ["tonic"]
    end

    test "an emptied list (the picker's lone sentinel) stores nothing" do
      admin = admin()
      field = terms_field!(admin)

      page = page!(%{field.name => [""]}, admin)

      refute Map.has_key?(page.custom_fields, field.name)
    end

    test "refuses a term outside a fixed vocabulary, naming it" do
      admin = admin()
      field = terms_field!(admin)

      assert {:error, error} = page(%{field.name => ["tonic", "nervine"]}, admin)
      assert Exception.message(error) =~ "not allowed options: nervine"
    end

    test "an open vocabulary takes new terms" do
      admin = admin()
      field = terms_field!(admin, %{allow_custom: true})

      page = page!(%{field.name => ["tonic", "nervine"]}, admin)

      assert page.custom_fields[field.name] == ["tonic", "nervine"]
    end

    test "refuses the JSON-string form this type replaces, even on an open vocabulary" do
      admin = admin()
      field = terms_field!(admin, %{allow_custom: true})

      assert {:error, error} = page(%{field.name => ~s(["tonic","adaptogen"])}, admin)
      assert Exception.message(error) =~ "JSON-encoded list"
    end

    test "refuses an item that is not a term" do
      admin = admin()
      field = terms_field!(admin, %{allow_custom: true})

      assert {:error, error} = page(%{field.name => [%{"value" => "tonic"}]}, admin)
      assert Exception.message(error) =~ "must be a list of terms"
    end

    test "holds the item bounds" do
      admin = admin()
      field = terms_field!(admin, %{min_items: 2, max_items: 2})

      assert {:error, error} = page(%{field.name => ["tonic"]}, admin)
      assert Exception.message(error) =~ "needs at least 2 items"

      assert {:error, error} = page(%{field.name => ~w(tonic adaptogen stimulant)}, admin)
      assert Exception.message(error) =~ "at most 2 items"
    end
  end

  describe "flipping a select between one choice and several" do
    test "single → several wraps each stored choice; several → single keeps the first" do
      admin = admin()

      field =
        define!(%{label: "Taste", field_type: :select, options: ~w(sweet bitter sour)}, admin)

      one = page!(%{field.name => "bitter"}, admin)

      field = CMS.update_field_definition!(field, %{multiple: true}, actor: admin)
      assert CMS.get_page!(one.id, actor: admin).custom_fields[field.name] == ["bitter"]

      two = page!(%{field.name => ["sour", "sweet"]}, admin)

      CMS.update_field_definition!(field, %{multiple: false}, actor: admin)
      assert CMS.get_page!(two.id, actor: admin).custom_fields[field.name] == "sour"
    end

    test "retyping a text field into several terms leaves its JSON strings for the converter" do
      admin = admin()
      field = define!(%{label: "Properties", field_type: :text, format: :plain}, admin)
      page = page!(%{field.name => ~s(["tonic"])}, admin)

      CMS.update_field_definition!(
        field,
        %{field_type: :select, multiple: true, allow_custom: true},
        actor: admin
      )

      assert CMS.get_page!(page.id, actor: admin).custom_fields[field.name] == ~s(["tonic"])
    end
  end

  describe "filtering on a select holding several terms" do
    test "eq / not_eq / in ask whether the list contains the term(s)" do
      admin = admin()
      field = terms_field!(admin)

      a = page!(%{field.name => ~w(tonic adaptogen)}, admin)
      b = page!(%{field.name => ~w(stimulant)}, admin)
      _none = page!(%{}, admin)

      ids = fn filter ->
        %{custom_filter: %{field.name => filter}}
        |> CMS.list_pages!(actor: admin)
        |> Enum.map(& &1.id)
        |> Enum.sort()
      end

      assert ids.("tonic") == [a.id]
      assert ids.(%{"in" => ["adaptogen", "stimulant"]}) == Enum.sort([a.id, b.id])
      assert b.id in ids.(%{"not_eq" => "tonic"})
      refute a.id in ids.(%{"not_eq" => "tonic"})
    end

    test "is not sortable" do
      admin = admin()
      field = terms_field!(admin)

      assert {:error, error} = CMS.list_pages(%{custom_sort: field.name}, actor: admin)
      assert Exception.message(error) =~ "is not sortable"
    end
  end

  describe "SelectTerms.used/1" do
    test "lists the terms in use on an open vocabulary, most used first" do
      admin = admin()
      field = terms_field!(admin, %{allow_custom: true})
      fixed = terms_field!(admin)

      page!(%{field.name => ["nervine", "tonic"], fixed.name => ["tonic"]}, admin)
      page!(%{field.name => ["tonic"]}, admin)

      assert %{} = used = SelectTerms.used([field, fixed])
      assert used[field.name] == ["tonic", "nervine"]
      refute Map.has_key?(used, fixed.name)
    end
  end

  describe "a list of phrases (multiple :string)" do
    defp list_field!(admin, attrs \\ %{}) do
      define!(Map.merge(%{label: "Symptoms", field_type: :string, multiple: true}, attrs), admin)
    end

    test "keeps multiple on a record-level string, not on a group sub-field" do
      admin = admin()
      assert list_field!(admin, %{max_items: 5}).multiple

      group = define!(%{label: "Doses", field_type: :group, multiple: true}, admin)

      sub =
        CMS.create_field_definition!(
          %{
            group_of_id: group.id,
            name: "note",
            label: "Note",
            field_type: :string,
            multiple: true
          },
          actor: admin
        )

      refute sub.multiple
    end

    test "stores the items as a list; a multi-line item is one item per line" do
      admin = admin()
      field = list_field!(admin)

      page =
        page!(
          %{field.name => ["", " fatigue ", "night sweats\nfatigue\r\ndry, hacking cough"]},
          admin
        )

      assert page.custom_fields[field.name] == ["fatigue", "night sweats", "dry, hacking cough"]
      assert page!(%{field.name => "fatigue"}, admin).custom_fields[field.name] == ["fatigue"]
    end

    test "refuses a JSON-encoded list and an item that is not text; holds the bounds" do
      admin = admin()
      field = list_field!(admin, %{max_items: 1})

      assert {:error, error} = page(%{field.name => ~s(["a","b"])}, admin)
      assert Exception.message(error) =~ "JSON-encoded list"

      assert {:error, error} = page(%{field.name => [%{"value" => "a"}]}, admin)
      assert Exception.message(error) =~ "must be a list of terms"

      assert {:error, error} = page(%{field.name => ["a", "b"]}, admin)
      assert Exception.message(error) =~ "at most 1 items"
    end

    test "filters by containment, and flipping reshapes like a select" do
      admin = admin()
      field = list_field!(admin)
      a = page!(%{field.name => ["fatigue", "cough"]}, admin)
      _b = page!(%{field.name => ["fever"]}, admin)

      assert %{custom_filter: %{field.name => "cough"}}
             |> CMS.list_pages!(actor: admin)
             |> Enum.map(& &1.id) == [a.id]

      CMS.update_field_definition!(field, %{multiple: false}, actor: admin)
      assert CMS.get_page!(a.id, actor: admin).custom_fields[field.name] == "fatigue"
    end

    test "retyping a text field into a list leaves its JSON strings for the converter" do
      admin = admin()
      field = define!(%{label: "Old", field_type: :text, format: :plain}, admin)
      page = page!(%{field.name => ~s(["a"])}, admin)

      CMS.update_field_definition!(field, %{field_type: :string, multiple: true}, actor: admin)

      assert CMS.get_page!(page.id, actor: admin).custom_fields[field.name] == ~s(["a"])
    end
  end

  describe "a rich :text field" do
    test "is the default format" do
      assert define!(%{label: "Uses", field_type: :text}, admin()).format == :rich
    end

    test "sanitizes markup on write to the rich-text block's allow-list" do
      admin = admin()
      field = define!(%{label: "Uses", field_type: :text}, admin)

      html =
        ~s{<p onclick="x()">Ren Shen <strong>tonifies</strong> <a href="javascript:alert(1)">qi</a></p>} <>
          "<script>alert(1)</script><ul><li>one</li></ul>"

      stored = page!(%{field.name => html}, admin).custom_fields[field.name]

      assert stored =~ "<strong>tonifies</strong>"
      assert stored =~ "<ul><li>one</li></ul>"
      refute stored =~ "onclick"
      refute stored =~ "javascript:"
      refute stored =~ "<script"
    end

    test "leaves text with no markup, and JSON data, exactly as written" do
      admin = admin()
      field = define!(%{label: "Uses", field_type: :text}, admin)

      plain = ~s(Salt & pepper, "to taste")
      assert page!(%{field.name => plain}, admin).custom_fields[field.name] == plain

      json = ~s([{"note":"<b>bold</b> & more"}])
      assert page!(%{field.name => json}, admin).custom_fields[field.name] == json
    end

    test "keeps safe markup byte for byte rather than as the sanitizer would rewrite it" do
      admin = admin()
      field = define!(%{label: "Uses", field_type: :text}, admin)
      html = ~s(<p>One &mdash; <a href='/two'>two</a></p>)

      assert page!(%{field.name => html}, admin).custom_fields[field.name] == html
    end

    test "a plain field stores markup as typed" do
      admin = admin()
      field = define!(%{label: "Code", field_type: :text, format: :plain}, admin)

      assert page!(%{field.name => "<x-code>1</x-code>"}, admin).custom_fields[field.name] ==
               "<x-code>1</x-code>"
    end
  end

  describe "TextFormat.json_data?/1" do
    test "is true for a JSON list or object stored as text, false otherwise" do
      assert TextFormat.json_data?(~s(["a","b"]))
      assert TextFormat.json_data?(~s(  {"a": 1}))
      refute TextFormat.json_data?("[not json")
      refute TextFormat.json_data?("<p>[1]</p>")
      refute TextFormat.json_data?(~s("a string"))
      refute TextFormat.json_data?(nil)
    end
  end
end
