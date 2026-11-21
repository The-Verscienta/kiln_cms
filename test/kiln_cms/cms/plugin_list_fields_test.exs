defmodule KilnCMS.CMS.PluginListFieldsTest do
  @moduledoc """
  A plugin field type that takes lists (#2680, `c:Kiln.FieldType.multiple?/0`):
  the dependency fixture's `:stars` (repeats kept), the fixture plugin's `:tag`
  (`unique_items?/0`) and `:shapeshifter` (whose `cast/2` can answer a map).
  The definition rules (`Changes.ClearMultiple`), the write path
  (`Changes.ApplyCustomFields`) through the code interface, JSON:API and
  GraphQL, reshaping on a flip (`Changes.SyncFieldValues`), search text, and
  a field sync import of a type that does not take lists.
  """
  # async: false — the GraphQL write goes through the shared schema and
  # sandbox, as in the other GraphQL custom-field tests.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "plf-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(attrs, actor) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: "p#{System.unique_integer([:positive])}", label: "F"},
        attrs
      ),
      actor: actor
    )
  end

  defp list!(type, admin, attrs \\ %{}),
    do: define!(Map.merge(%{field_type: type, multiple: true, label: "List"}, attrs), admin)

  defp slug, do: "plf-#{System.unique_integer([:positive])}"

  defp page!(fields, actor),
    do: CMS.create_page!(%{title: "P", slug: slug(), custom_fields: fields}, actor: actor)

  defp page(fields, actor),
    do: CMS.create_page(%{title: "P", slug: slug(), custom_fields: fields}, actor: actor)

  defp stored(page, field, admin),
    do: CMS.get_page!(page.id, actor: admin).custom_fields[field.name]

  defp error!(result) do
    assert {:error, %Ash.Error.Invalid{} = error} = result
    Exception.message(error)
  end

  defp key(actor) do
    actor.id
    |> Accounts.mint_api_key!(
      "plugin-lists",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: actor
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp patch_json(page, attrs, key) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> patch(
        "/api/json/pages/#{page.id}",
        Jason.encode!(%{data: %{type: "page", id: page.id, attributes: attrs}})
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp gql_update(page, custom_fields, key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post(
      "/gql",
      Jason.encode!(%{
        query: """
        mutation ($id: ID!, $input: UpdatePageInput!) {
          updatePage(id: $id, input: $input) { result { id } errors { message } }
        }
        """,
        variables: %{id: page.id, input: %{customFields: Jason.encode!(custom_fields)}}
      })
    )
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  describe "the definition" do
    test "keeps multiple and its bounds on an opting plugin type at record level" do
      admin = admin()

      for type <- [:stars, :tag, :shapeshifter] do
        field = list!(type, admin, %{min_items: 1, max_items: 3})
        assert {type, true, 1, 3} == {type, field.multiple, field.min_items, field.max_items}
      end
    end

    test "is cleared on a plugin type that does not opt in, and on a built-in composite" do
      admin = admin()

      for type <- [:rating, :geolocation, :tokenless] do
        field = list!(type, admin, %{min_items: 1})
        assert {type, false, nil} == {type, field.multiple, field.min_items}
      end
    end

    # A plugin type cannot be a group sub-field or a link field at all
    # (`Validations.GroupField`, `Validations.LinkField`), so a list of one is
    # only ever a record-level field.
    test "an opting type is still refused as a group sub-field or a link field" do
      admin = admin()
      group = define!(%{field_type: :group, multiple: true, label: "Rows"}, admin)

      parent =
        define!(%{field_type: :reference, target_type: "page", multiple: true}, admin)

      for parent_key <- [group_of_id: group.id, link_of_id: parent.id] do
        {key, id} = parent_key

        assert {:error, %Ash.Error.Invalid{}} =
                 CMS.create_field_definition(
                   %{key => id, name: "tags", label: "T", field_type: :tag, multiple: true},
                   actor: admin
                 )
      end
    end
  end

  describe "writes" do
    test "each item goes through the type's cast/2; stars keep repeats and order" do
      admin = admin()
      scores = list!(:stars, admin)

      page = page!(%{scores.name => ["3", 4, " 3 "]}, admin)
      assert stored(page, scores, admin) == [3, 4, 3]
    end

    test "a type with unique_items?/0 drops repeats after cast, keeping the first" do
      admin = admin()
      tags = list!(:tag, admin)

      page = page!(%{tags.name => ["Red", "red ", "Blue"]}, admin)
      assert stored(page, tags, admin) == ["red", "blue"]
    end

    test "an item holding several lines is one item per line" do
      admin = admin()
      tags = list!(:tag, admin)

      page = page!(%{tags.name => "Alpha\nBeta\n\nalpha"}, admin)
      assert stored(page, tags, admin) == ["alpha", "beta"]
    end

    test "an item the type refuses is named by its position" do
      admin = admin()
      scores = list!(:stars, admin)

      message = error!(page(%{scores.name => ["3", "9"]}, admin))
      assert message =~ "item 2 must be a whole number from 1 to 5"
    end

    test "a map or a list item, and a JSON-encoded list, are refused" do
      admin = admin()
      tags = list!(:tag, admin)

      assert error!(page(%{tags.name => ["a", %{"x" => 1}]}, admin)) =~
               "must be a list of values"

      assert error!(page(%{tags.name => [["a"]]}, admin)) =~ "must be a list of values"

      assert error!(page(%{tags.name => [~s(["a","b"])]}, admin)) =~
               "holds a JSON-encoded list"
    end

    test "a cast/2 answering a map for an item refuses the write, storing nothing" do
      admin = admin()
      shapes = list!(:shapeshifter, admin)

      message = error!(page(%{shapes.name => ["ok", "{x"]}, admin))
      assert message =~ ~s(item 2 must be one value: the field type returned %{"raw" => "{x"})

      page = page!(%{shapes.name => ["ok"]}, admin)
      assert stored(page, shapes, admin) == ["ok"]

      assert {:error, _} =
               CMS.update_page(page, %{custom_fields: %{shapes.name => ["ok", "{y"]}},
                 actor: admin
               )

      assert stored(page, shapes, admin) == ["ok"]
    end

    test "the item bounds hold" do
      admin = admin()
      scores = list!(:stars, admin, %{min_items: 2, max_items: 3})

      assert error!(page(%{scores.name => ["1"]}, admin)) =~ "at least 2"
      assert error!(page(%{scores.name => ~w(1 2 3 4)}, admin)) =~ "at most 3"
      assert stored(page!(%{scores.name => ~w(1 2)}, admin), scores, admin) == [1, 2]
    end

    test "a single field of an opting type handed a list keeps its first item" do
      admin = admin()
      tag = define!(%{field_type: :tag}, admin)

      page = page!(%{tag.name => ["First", "second"]}, admin)
      assert stored(page, tag, admin) == "first"
    end

    test "a searchable list's items are in the search text" do
      admin = admin()
      tags = list!(:tag, admin, %{searchable: true})

      page = page!(%{tags.name => ["Saffron", "Cardamom"]}, admin)

      text = CMS.get_page!(page.id, actor: admin).search_text
      assert text =~ "saffron"
      assert text =~ "cardamom"
    end
  end

  describe "flipping between one value and a list" do
    test "single → list wraps the stored value; list → single keeps the first" do
      admin = admin()
      score = define!(%{field_type: :stars}, admin)

      page = page!(%{score.name => "4"}, admin)
      assert stored(page, score, admin) == 4

      score = CMS.update_field_definition!(score, %{multiple: true}, actor: admin)
      assert stored(page, score, admin) == [4]

      CMS.update_page!(
        CMS.get_page!(page.id, actor: admin),
        %{
          custom_fields: %{score.name => [4, 2]}
        },
        actor: admin
      )

      CMS.update_field_definition!(score, %{multiple: false}, actor: admin)
      assert stored(page, score, admin) == 4
    end
  end

  describe "over the APIs" do
    test "a JSON:API PATCH writes the list through cast/2 and refuses a bad item" do
      admin = admin()
      scores = list!(:stars, admin)
      page = page!(%{}, admin)
      key = key(admin)

      assert {200, _} = patch_json(page, %{custom_fields: %{scores.name => ["2", 2, "5"]}}, key)
      assert stored(page, scores, admin) == [2, 2, 5]

      assert {400, %{"errors" => [error | _]}} =
               patch_json(page, %{custom_fields: %{scores.name => ["2", "7"]}}, key)

      assert error["detail"] =~ "item 2 must be a whole number from 1 to 5"
      assert stored(page, scores, admin) == [2, 2, 5]
    end

    test "a GraphQL updatePage writes the list and refuses a bad item" do
      admin = admin()
      tags = list!(:tag, admin)
      page = page!(%{}, admin)
      key = key(admin)

      body = gql_update(page, %{tags.name => ["One", "two", "ONE"]}, key)
      assert body["data"]["updatePage"]["errors"] == []
      assert stored(page, tags, admin) == ["one", "two"]

      body = gql_update(page, %{tags.name => ["ok", "   "]}, key)
      assert stored(page, tags, admin) == ["ok"]
      assert body["data"]["updatePage"]["errors"] == []

      body = gql_update(page, %{tags.name => ["ok", String.duplicate("x", 41)]}, key)
      assert [error] = body["data"]["updatePage"]["errors"]
      assert error["message"] =~ "item 2 must be at most 40 characters"
      assert stored(page, tags, admin) == ["ok"]
    end
  end

  describe "a field sync import" do
    test "a file making a plugin type that does not take lists a list leaves it single" do
      admin = admin()
      rated = define!(%{field_type: :rating, label: "Rated"}, admin)

      {:ok, doc} = CMS.FieldSync.export(actor: admin)

      doc =
        update_in(
          doc,
          ["owners", Access.all(), "fields", Access.filter(&(&1["name"] == rated.name))],
          &Map.put(&1, "multiple", true)
        )

      assert {:ok, _report} = CMS.FieldSync.import_doc(doc, actor: admin, apply?: true)

      field = CMS.get_field_definition!(rated.id, actor: admin)
      assert field.field_type == :rating
      refute field.multiple
    end
  end
end
