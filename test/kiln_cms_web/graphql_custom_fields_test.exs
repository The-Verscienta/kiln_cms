defmodule KilnCMSWeb.GraphqlCustomFieldsTest do
  @moduledoc """
  The typed readers of admin-defined custom fields (#2290): `customString` /
  `customInt` / `customFloat` / `customBoolean` / `customDate` /
  `customDateTime` (`name:`) and `fields(names:)` on every content type.

  Every document selects **only** the accessors, never `customFields`, so
  `custom_fields`, `type_definition_id` and `org_id` are not loaded on the
  parent and the resolver has to fetch them (as the request's actor) itself.
  """
  # async: false — the read-count tests listen to the repo's telemetry, which
  # is global (`KilnCMS.Test.QueryCounting`), and the org tests go through the
  # endpoint.
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS
  alias KilnCMS.Test.QueryCounting
  alias KilnCMSWeb.Tenant

  @schema KilnCMSWeb.GraphqlSchema

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gcf-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "gcf-#{System.unique_integer([:positive])}"

  defp run(query, variables, actor),
    do: Absinthe.run(query, @schema, variables: variables, context: %{actor: actor})

  defp run!(query, variables \\ %{}, actor \\ nil) do
    assert {:ok, result} = run(query, variables, actor)
    refute Map.has_key?(result, :errors), inspect(result[:errors])
    result.data
  end

  defp define!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :post, label: "Field"}, attrs),
      actor: admin
    )
  end

  defp post!(admin, custom_fields, attrs \\ %{}) do
    %{title: "Post #{System.unique_integer([:positive])}", slug: slug()}
    |> Map.merge(attrs)
    |> Map.put(:custom_fields, custom_fields)
    |> CMS.create_post!(actor: admin)
    |> then(&CMS.publish_post!(&1, %{}, actor: admin))
  end

  @one """
  query ($slug: String!, $names: [String!]!) {
    postBySlug(slug: $slug, locale: "en") {
      s: customString(name: "title_text")
      i: customInt(name: "count")
      f: customFloat(name: "price")
      b: customBoolean(name: "featured")
      d: customDate(name: "on")
      t: customDateTime(name: "at")
      fields(names: $names) {
        __typename
        name
        ... on StringValue { value }
        ... on IntValue { value }
        ... on FloatValue { value }
        ... on BooleanValue { value }
        ... on DateValue { value }
        ... on DateTimeValue { value }
        ... on ListValue { items { __typename ... on StringValue { value } } }
        ... on GroupValue { fields { __typename name ... on FloatValue { value } ... on StringValue { value } } }
        ... on ReferenceValue { ids }
        ... on MediaValue { id url alt }
        ... on GeolocationValue { lat lng label zoom }
        ... on JsonValue { value }
      }
    }
  }
  """

  defp one(post, names, actor \\ nil),
    do: run!(@one, %{"slug" => post.slug, "names" => names}, actor)["postBySlug"]

  setup do
    admin = user(:admin)

    for {name, type} <- [
          {"title_text", :string},
          {"count", :integer},
          {"price", :float},
          {"featured", :boolean},
          {"on", :date},
          {"at", :datetime}
        ] do
      define!(admin, %{name: name, field_type: type})
    end

    %{admin: admin}
  end

  describe "the accessors" do
    test "each kind is typed, selecting only accessors", %{admin: admin} do
      post =
        post!(admin, %{
          "title_text" => "hello",
          "count" => 3,
          "price" => 9,
          "featured" => true,
          "on" => "2026-11-05",
          "at" => "2026-11-05T10:30:00Z"
        })

      assert %{
               "s" => "hello",
               "i" => 3,
               "f" => 9.0,
               "b" => true,
               "d" => "2026-11-05",
               "t" => "2026-11-05T10:30:00Z"
             } = one(post, [])
    end

    test "an accessor of the wrong kind, or an unknown name, is null, never an error", %{
      admin: admin
    } do
      post = post!(admin, %{"title_text" => "hello", "count" => 3})

      query = """
      query ($slug: String!) {
        postBySlug(slug: $slug, locale: "en") {
          a: customInt(name: "title_text")
          b: customString(name: "count")
          c: customFloat(name: "nope")
          d: customString(name: "")
          e: customBoolean(name: "price")
        }
      }
      """

      assert %{"postBySlug" => row} = run!(query, %{"slug" => post.slug})
      assert row == %{"a" => nil, "b" => nil, "c" => nil, "d" => nil, "e" => nil}
    end

    test "a legacy value that no longer fits its definition is null", %{admin: admin} do
      post = post!(admin, %{"price" => 1.5, "on" => "2026-11-05"})

      # The stored map is rewritten behind the definitions' back, as an older
      # release or a retyped field would have left it.
      Ash.Seed.update!(post, %{custom_fields: %{"price" => "n/a", "on" => "not a date"}})

      assert %{"f" => nil, "d" => nil, "fields" => []} = one(post, ["price", "on"])
    end

    test "a renamed or deleted field reads as unknown under the old name", %{admin: admin} do
      price =
        CMS.get_field_definition!(define!(admin, %{name: "old", field_type: :float}).id,
          actor: admin
        )

      post = post!(admin, %{"old" => 2.5})

      query = fn name ->
        ~s|query ($slug: String!) { postBySlug(slug: $slug, locale: "en") { v: customFloat(name: "#{name}") } }|
      end

      assert %{"postBySlug" => %{"v" => 2.5}} = run!(query.("old"), %{"slug" => post.slug})

      CMS.update_field_definition!(price, %{name: "renamed"}, actor: admin)

      assert %{"postBySlug" => %{"v" => nil}} = run!(query.("old"), %{"slug" => post.slug})
      assert %{"postBySlug" => %{"v" => 2.5}} = run!(query.("renamed"), %{"slug" => post.slug})

      renamed = CMS.get_field_definition!(price.id, actor: admin)
      CMS.destroy_field_definition!(renamed, actor: admin)

      assert %{"postBySlug" => %{"v" => nil}} = run!(query.("renamed"), %{"slug" => post.slug})
    end
  end

  describe "fields(names:)" do
    test "lists each named field as its own kind, leaving out unknown names", %{admin: admin} do
      define!(admin, %{name: "tags_list", field_type: :string, multiple: true})
      define!(admin, %{name: "place", field_type: :geolocation})

      post =
        post!(admin, %{
          "title_text" => "hello",
          "count" => 3,
          "price" => 1.25,
          "featured" => false,
          "on" => "2026-11-05",
          "at" => "2026-11-05T10:30:00Z",
          "tags_list" => ["a", "b"],
          "place" => %{"lat" => 51.5, "lng" => -0.12}
        })

      names =
        ~w(title_text count price featured on at tags_list place missing) ++ ["", "title_text"]

      assert %{"fields" => fields} = one(post, names)

      by_name = Map.new(fields, &{&1["name"], &1})

      assert Enum.map(fields, & &1["name"]) |> Enum.sort() ==
               Enum.sort(~w(title_text count price featured on at tags_list place))

      assert %{"__typename" => "StringValue", "value" => "hello"} = by_name["title_text"]
      assert %{"__typename" => "IntValue", "value" => 3} = by_name["count"]
      assert %{"__typename" => "FloatValue", "value" => 1.25} = by_name["price"]
      assert %{"__typename" => "BooleanValue", "value" => false} = by_name["featured"]
      assert %{"__typename" => "DateValue", "value" => "2026-11-05"} = by_name["on"]
      assert %{"__typename" => "DateTimeValue"} = by_name["at"]

      assert %{
               "__typename" => "ListValue",
               "items" => [%{"__typename" => "StringValue", "value" => "a"}, %{"value" => "b"}]
             } = by_name["tags_list"]

      assert %{
               "__typename" => "GeolocationValue",
               "lat" => 51.5,
               "lng" => -0.12,
               "label" => nil,
               "zoom" => nil
             } = by_name["place"]
    end

    test "a geolocation serves its label and zoom; a legacy shape is left out", %{admin: admin} do
      define!(admin, %{name: "place", field_type: :geolocation})

      post =
        post!(admin, %{
          "place" => %{"lat" => "51.5074", "lng" => "-0.1278", "label" => "London", "zoom" => 12}
        })

      assert %{"fields" => [place]} = one(post, ["place"])

      assert %{
               "__typename" => "GeolocationValue",
               "lat" => 51.5074,
               "lng" => -0.1278,
               "label" => "London",
               "zoom" => 12
             } = place

      # The column is plain jsonb: write shapes `cast/2` would refuse straight to it.
      for legacy <- [
            %{"lat" => "north", "lng" => 1.0},
            %{"lat" => 91.0, "lng" => 1.0},
            %{"lat" => 1.0},
            "51.5,-0.1",
            [1, 2]
          ] do
        Ash.Seed.update!(post, %{custom_fields: %{"place" => legacy}})

        assert %{"fields" => []} = one(post, ["place"])
      end
    end

    test "range, key_value and link are served as the generic JSON value (#2278)",
         %{admin: admin} do
      define!(admin, %{name: "band", field_type: :range})
      define!(admin, %{name: "specs", field_type: :key_value})
      define!(admin, %{name: "source", field_type: :link})

      post =
        post!(admin, %{
          "band" => %{"min" => "1", "max" => "9"},
          "specs" => "Weight=2 kg",
          "source" => %{"url" => "https://example.com", "label" => "Example"}
        })

      assert %{"fields" => fields} = one(post, ["band", "specs", "source"])
      assert Enum.map(fields, & &1["name"]) == ["band", "specs", "source"]
      for field <- fields, do: assert(field["__typename"] =~ "Json")
    end

    test "the format types: strings through customString, json as the generic value (#2278)",
         %{admin: admin} do
      define!(admin, %{name: "contact", field_type: :email})
      define!(admin, %{name: "extra", field_type: :json})

      post = post!(admin, %{"contact" => "Ann@Example.COM", "extra" => ~s({"a": [1]})})

      assert %{"fields" => fields} = one(post, ["contact", "extra"])
      by_name = Map.new(fields, &{&1["name"], &1})

      assert %{"__typename" => "StringValue", "value" => "Ann@example.com"} = by_name["contact"]
      assert %{"__typename" => typename} = by_name["extra"]
      assert typename =~ "Json"
    end

    test "a group nests its sub-fields", %{admin: admin} do
      group = define!(admin, %{name: "dose", field_type: :group, multiple: true})

      define!(admin, %{
        name: "amount",
        field_type: :float,
        group_of_id: group.id,
        content_type: nil
      })

      define!(admin, %{
        name: "unit",
        field_type: :string,
        group_of_id: group.id,
        content_type: nil
      })

      post = post!(admin, %{"dose" => [%{"amount" => 2, "unit" => "g"}, %{"amount" => 5}]})

      assert %{"fields" => [%{"__typename" => "ListValue", "items" => items}]} =
               one(post, ["dose"])

      assert [%{"__typename" => "GroupValue"}, %{"__typename" => "GroupValue"}] = items

      query = """
      query ($slug: String!) {
        postBySlug(slug: $slug, locale: "en") {
          fields(names: ["dose"]) {
            ... on ListValue { items { ... on GroupValue { fields { name ... on FloatValue { value } ... on StringValue { value } } } } }
          }
        }
      }
      """

      assert %{"postBySlug" => %{"fields" => [%{"items" => [first, second]}]}} =
               run!(query, %{"slug" => post.slug})

      assert Enum.sort_by(first["fields"], & &1["name"]) == [
               %{"name" => "amount", "value" => 2.0},
               %{"name" => "unit", "value" => "g"}
             ]

      assert second["fields"] == [%{"name" => "amount", "value" => 5.0}]
    end

    test "a reference serves ids, and media serves the snapshot shape", %{admin: admin} do
      define!(admin, %{name: "friend", field_type: :reference, target_type: "post"})
      define!(admin, %{name: "hero", field_type: :media})
      other = post!(admin, %{})

      item =
        CMS.create_media_item!(%{filename: "hero-#{System.unique_integer([:positive])}.jpg"},
          actor: admin
        )

      post =
        post!(admin, %{
          "friend" => %{"id" => other.id, "type" => "post"},
          "hero" => %{"id" => item.id}
        })

      assert %{"fields" => fields} = one(post, ["friend", "hero"])
      by_name = Map.new(fields, &{&1["name"], &1})

      assert %{"__typename" => "ReferenceValue", "ids" => [id]} = by_name["friend"]
      assert id == other.id
      assert %{"__typename" => "MediaValue", "id" => media_id} = by_name["hero"]
      assert media_id == item.id
    end

    test "more than 50 names is refused", %{admin: admin} do
      post = post!(admin, %{})
      names = for n <- 1..51, do: "f#{n}"

      assert {:ok, %{errors: [%{message: message}]}} =
               run(@one, %{"slug" => post.slug, "names" => names}, nil)

      assert message =~ "at most 50"
    end
  end

  describe "every content type" do
    test "a dynamic Entry serves its own type's fields, per type", %{admin: admin} do
      types =
        for n <- 1..2 do
          type =
            CMS.create_type_definition!(
              %{name: "gcf_type_#{n}_#{System.unique_integer([:positive])}", label: "T#{n}"},
              actor: admin
            )

          CMS.create_field_definition!(
            %{type_definition_id: type.id, name: "price", label: "Price", field_type: :float},
            actor: admin
          )

          entry =
            %{
              title: "E#{n}",
              slug: slug(),
              type_definition_id: type.id,
              custom_fields: %{"price" => n * 10}
            }
            |> CMS.create_entry!(actor: admin)
            |> CMS.publish_entry!(%{}, actor: admin)

          {type, entry}
        end

      query = """
      { publishedEntries(limit: 25) { results { slug p: customFloat(name: "price") fields(names: ["price"]) { name ... on FloatValue { value } } } } }
      """

      %{"publishedEntries" => %{"results" => results}} = run!(query)
      by_slug = Map.new(results, &{&1["slug"], &1})

      for {{_type, entry}, n} <- Enum.with_index(types, 1) do
        row = by_slug[entry.slug]
        assert row["p"] == n * 10.0
        assert row["fields"] == [%{"name" => "price", "value" => n * 10.0}]
      end
    end

    test "the interface reaches the accessors through a reference's target", %{admin: admin} do
      define!(admin, %{
        name: "friend",
        field_type: :reference,
        target_type: "post",
        multiple: true
      })

      target = post!(admin, %{"price" => 4.5})
      source = post!(admin, %{"friend" => [%{"id" => target.id, "type" => "post"}]})

      query = """
      query ($slug: String!) {
        postBySlug(slug: $slug, locale: "en") {
          references(field: "friend") { target { id customFloat(name: "price") } }
        }
      }
      """

      assert %{"postBySlug" => %{"references" => [%{"target" => %{"customFloat" => 4.5}}]}} =
               run!(query, %{"slug" => source.slug})
    end

    test "a page and a category-less type compile the same accessors", %{admin: admin} do
      define!(admin, %{name: "subtitle", field_type: :string, content_type: :page})

      page =
        %{title: "P", slug: slug(), custom_fields: %{"subtitle" => "sub"}}
        |> CMS.create_page!(actor: admin)
        |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      query =
        ~s|query ($slug: String!) { pageBySlug(slug: $slug, locale: "en") { customString(name: "subtitle") } }|

      assert %{"pageBySlug" => %{"customString" => "sub"}} = run!(query, %{"slug" => page.slug})
    end
  end

  describe "private fields" do
    setup %{admin: admin} do
      define!(admin, %{name: "secret", field_type: :string, private: true})
      post = post!(admin, %{"secret" => "classified", "title_text" => "open"})
      %{post: post}
    end

    @private """
    query ($slug: String!) {
      postBySlug(slug: $slug, locale: "en") {
        open: customString(name: "title_text")
        secret: customString(name: "secret")
        fields(names: ["secret", "title_text"]) { name ... on StringValue { value } }
      }
    }
    """

    test "invisible to an anonymous reader and a viewer, visible to an editor", %{post: post} do
      for actor <- [nil, user(:viewer)] do
        assert %{"postBySlug" => row} = run!(@private, %{"slug" => post.slug}, actor)

        assert row == %{
                 "open" => "open",
                 "secret" => nil,
                 "fields" => [%{"name" => "title_text", "value" => "open"}]
               }
      end

      for actor <- [user(:editor), user(:admin)] do
        assert %{"postBySlug" => row} = run!(@private, %{"slug" => post.slug}, actor)
        assert row["secret"] == "classified"

        assert Enum.sort_by(row["fields"], & &1["name"]) == [
                 %{"name" => "secret", "value" => "classified"},
                 %{"name" => "title_text", "value" => "open"}
               ]
      end
    end

    test "a page of records is masked per record, in one document", %{admin: admin, post: post} do
      query =
        ~s|{ publishedPosts(limit: 25) { results { slug secret: customString(name: "secret") } } }|

      assert %{"publishedPosts" => %{"results" => rows}} = run!(query)
      assert Enum.any?(rows, &(&1["slug"] == post.slug))
      assert Enum.all?(rows, &is_nil(&1["secret"]))

      assert %{"publishedPosts" => %{"results" => rows}} = run!(query, %{}, admin)
      assert Enum.find(rows, &(&1["slug"] == post.slug))["secret"] == "classified"
    end

    test "custom_fields_plain does not leak a private :text field marked deliver_plain", %{
      admin: admin
    } do
      # The definition validation refuses this combination, so the row is
      # seeded: what an older release, or a bug, could have left behind.
      Ash.Seed.seed!(KilnCMS.CMS.FieldDefinition, %{
        content_type: :post,
        name: "diary",
        label: "Diary",
        field_type: :text,
        private: true,
        deliver_plain: true,
        org_id: KilnCMS.Accounts.default_org_id()
      })

      post = post!(admin, %{"diary" => "dear diary"})

      query =
        ~s|query ($slug: String!) { postBySlug(slug: $slug, locale: "en") { customFieldsPlain } }|

      for actor <- [nil, user(:viewer)] do
        {:ok, result} = run(query, %{"slug" => post.slug}, actor)
        refute inspect(result) =~ "dear diary"
      end

      # The control: an editor does get the plain text, so the refusal above
      # is the mask and not an empty projection.
      {:ok, result} = run(query, %{"slug" => post.slug}, admin)
      assert inspect(result) =~ "dear diary"
    end
  end

  describe "tenancy" do
    test "a site's definitions and values never reach another site's host", %{admin: admin} do
      a = org("gcf-a")
      b = org("gcf-b")
      shared = slug()

      for {org, value} <- [{a, 1.0}, {b, 2.0}] do
        opts = [actor: admin, tenant: org]

        CMS.create_field_definition!(
          %{content_type: :post, name: "price", label: "Price", field_type: :float},
          opts
        )

        %{title: "T", slug: shared, custom_fields: %{"price" => value}}
        |> CMS.create_post!(opts)
        |> CMS.publish_post!(%{}, opts)
      end

      query = ~s|{ publishedPosts(limit: 25) { results { p: customFloat(name: "price") } } }|

      for {org, value} <- [{a, 1.0}, {b, 2.0}] do
        body =
          %{build_conn() | host: "#{org.slug}.#{Tenant.base_host()}"}
          |> put_req_header("content-type", "application/json")
          |> post("/gql", Jason.encode!(%{query: query}))
          |> json_response(200)

        assert %{"data" => %{"publishedPosts" => %{"results" => [%{"p" => ^value}]}}} = body
      end
    end
  end

  describe "locale" do
    test "a :fallback field does not inherit along the locale chain", %{admin: admin} do
      define!(admin, %{name: "blurb", field_type: :string, localization: :fallback})
      en = post!(admin, %{"blurb" => "english"}, %{locale: "en"})
      fr = KilnCMS.CMS.Translations.create_translation!(:post, en, "fr", actor: admin)
      fr = CMS.update_post!(fr, %{custom_fields: %{"blurb" => ""}}, actor: admin)
      fr = CMS.publish_post!(fr, %{}, actor: admin)

      # The control: the delivery surfaces do fill this field from English.
      assert {filled, _inherited} = KilnCMS.I18n.FieldFallback.fill(fr)
      assert filled.custom_fields["blurb"] == "english"

      query =
        ~s|query ($slug: String!) { postBySlug(slug: $slug, locale: "fr") { b: customString(name: "blurb") fields(names: ["blurb"]) { name ... on StringValue { value } } } }|

      assert %{"postBySlug" => %{"b" => b, "fields" => fields}} =
               run!(query, %{"slug" => fr.slug})

      assert b in [nil, ""]
      refute Enum.any?(fields, &(&1["value"] == "english"))
    end
  end

  describe "reads" do
    test "a page of 25 reads the definitions and the records once, not once per row", %{
      admin: admin
    } do
      for _n <- 1..25, do: post!(admin, %{"price" => 1.5})

      query =
        ~s|{ publishedPosts(limit: 25) { results { id p: customFloat(name: "price") q: customString(name: "title_text") fields(names: ["price"]) { name } } } }|

      count = fn limit ->
        q = String.replace(query, "limit: 25", "limit: #{limit}")
        run!(q, %{}, admin)
        {definitions, records} = counted(fn -> run!(q, %{}, admin) end)
        {definitions, records}
      end

      {one_defs, one_records} = count.(1)
      {many_defs, many_records} = count.(25)

      assert one_defs > 0
      assert many_defs == one_defs
      assert many_records == one_records
    end
  end

  # {field_definitions queries, posts queries} fired on this test's behalf
  # while `fun` runs.
  defp counted(fun) do
    {_result, queries} = QueryCounting.queries(fun)
    sqls = Enum.map(queries, & &1.sql)

    {Enum.count(sqls, &(&1 =~ ~s(FROM "field_definitions"))),
     Enum.count(sqls, &(&1 =~ ~s(FROM "posts")))}
  end
end
