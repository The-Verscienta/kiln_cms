defmodule KilnCMS.Firing.BylinesTest do
  @moduledoc """
  Public bylines (#2044, `docs/author-profiles.md`): a `:reference` field
  whose definition names a `schema_org_property` puts one `Person` per
  readable target under `author` / `contributor` — on the fired `:json_ld`
  artifact, in the JSON-LD inlined in Kiln's own pages, and in their "By"
  line, which all name the same people.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Bylines

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "byline-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "byline-#{uniq()}"

  # A dynamic person type, as the guide builds it.
  defp person_type!(admin, attrs \\ %{}) do
    n = uniq()

    CMS.create_type_definition!(
      Map.merge(
        %{
          name: "person#{n}",
          label: "Person",
          path_segment: "people-#{n}",
          schema_org_type: "ProfilePage"
        },
        attrs
      ),
      actor: admin
    )
  end

  defp person!(admin, type, title, publish? \\ true) do
    entry =
      CMS.create_entry!(%{title: title, slug: slug(), type_definition_id: type.id},
        actor: admin
      )

    if publish?, do: CMS.publish_entry!(entry, actor: admin), else: entry
  end

  defp byline_field!(admin, type, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "people_#{uniq()}",
          label: "People",
          field_type: :reference,
          target_type: type.name,
          multiple: true
        },
        attrs
      ),
      actor: admin
    )
  end

  defp post!(admin, custom_fields, attrs \\ %{}) do
    admin
    |> then(
      &CMS.create_post!(
        Map.merge(%{title: "Story #{uniq()}", slug: slug(), custom_fields: custom_fields}, attrs),
        actor: &1
      )
    )
    |> CMS.publish_post!(actor: admin)
  end

  defp json_ld(conn, post) do
    conn
    |> get("/api/content/post/#{post.slug}?surface=json_ld")
    |> json_response(200)
    |> Map.fetch!("@graph")
    |> hd()
  end

  defp ref(record), do: %{"id" => record.id}

  defp names(nodes), do: Enum.map(nodes, & &1["name"])

  setup do
    admin = user(:admin)
    type = person_type!(admin)
    %{admin: admin, type: type}
  end

  describe "the field setting" do
    test "is kept on a reference and cleared on any other field", %{admin: admin, type: type} do
      field = byline_field!(admin, type, %{schema_org_property: :author})
      assert field.schema_org_property == :author

      plain =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "plain_#{uniq()}",
            label: "Plain",
            field_type: :string,
            schema_org_property: :author
          },
          actor: admin
        )

      assert plain.schema_org_property == nil

      # Retyping a byline away from a reference drops the meaning with it.
      retyped = CMS.update_field_definition!(field, %{field_type: :string}, actor: admin)
      assert retyped.schema_org_property == nil
    end

    test "accepts only author and contributor", %{admin: admin, type: type} do
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_field_definition(
                 %{
                   content_type: :post,
                   name: "people_#{uniq()}",
                   label: "People",
                   field_type: :reference,
                   target_type: type.name,
                   schema_org_property: :editor
                 },
                 actor: admin
               )
    end
  end

  describe "the fired :json_ld artifact" do
    test "names authors and contributors in field order, with profile urls",
         %{conn: conn, admin: admin, type: type} do
      authors = byline_field!(admin, type, %{schema_org_property: :author, position: 0})
      helpers = byline_field!(admin, type, %{schema_org_property: :contributor, position: 1})

      ada = person!(admin, type, "Ada Lovelace")
      grace = person!(admin, type, "Grace Hopper")
      alan = person!(admin, type, "Alan Turing")

      post =
        post!(admin, %{
          authors.name => [ref(grace), ref(ada)],
          helpers.name => [ref(alan)]
        })

      KilnCMS.DataCase.drain_oban()
      node = json_ld(conn, post)

      assert names(node["author"]) == ["Grace Hopper", "Ada Lovelace"]
      assert names(node["contributor"]) == ["Alan Turing"]
      assert Enum.all?(node["author"] ++ node["contributor"], &(&1["@type"] == "Person"))

      base = KilnCMSWeb.Tenant.base_url(post.org_id)
      assert hd(node["author"])["url"] == "#{base}/#{type.path_segment}/#{grace.slug}"
    end

    test "leaves out a draft person, and follows a rename", %{
      conn: conn,
      admin: admin,
      type: type
    } do
      authors = byline_field!(admin, type, %{schema_org_property: :author})
      ada = person!(admin, type, "Ada Lovelace")
      draft = person!(admin, type, "Not Yet", false)

      post = post!(admin, %{authors.name => [ref(draft), ref(ada)]})
      KilnCMS.DataCase.drain_oban()

      assert names(json_ld(conn, post)["author"]) == ["Ada Lovelace"]

      # Editing the published person re-fires the post (D13).
      CMS.update_entry!(ada, %{title: "Ada King"}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert names(json_ld(build_conn(), post)["author"]) == ["Ada King"]
    end

    test "a reference with no setting adds nothing", %{conn: conn, admin: admin, type: type} do
      plain = byline_field!(admin, type, %{})
      post = post!(admin, %{plain.name => [ref(person!(admin, type, "Ada Lovelace"))]})
      KilnCMS.DataCase.drain_oban()

      node = json_ld(conn, post)
      refute Map.has_key?(node, "author")
      refute Map.has_key?(node, "contributor")
    end

    test "setting the meaning on an existing field re-fires its type's documents",
         %{conn: conn, admin: admin, type: type} do
      field = byline_field!(admin, type, %{})
      post = post!(admin, %{field.name => [ref(person!(admin, type, "Ada Lovelace"))]})
      KilnCMS.DataCase.drain_oban()
      refute Map.has_key?(json_ld(conn, post), "author")

      CMS.update_field_definition!(field, %{schema_org_property: :author}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert names(json_ld(build_conn(), post)["author"]) == ["Ada Lovelace"]
    end

    test "an Event carries no byline", %{admin: admin, type: type} do
      gig =
        CMS.create_type_definition!(
          %{name: "gig#{uniq()}", label: "Gig", schema_org_type: "MusicEvent"},
          actor: admin
        )

      field =
        CMS.create_field_definition!(
          %{
            type_definition_id: gig.id,
            name: "performers",
            label: "Performers",
            field_type: :reference,
            target_type: type.name,
            multiple: true,
            schema_org_property: :contributor
          },
          actor: admin
        )

      entry =
        CMS.create_entry!(
          %{
            title: "Live",
            slug: slug(),
            type_definition_id: gig.id,
            custom_fields: %{field.name => [ref(person!(admin, type, "Ada Lovelace"))]}
          },
          actor: admin
        )

      {:ok, %{json_ld: %{"@graph" => [node | _]}}} =
        KilnCMS.Firing.Engine.fire(entry, mode: :preview)

      assert node["@type"] == "MusicEvent"
      refute Map.has_key?(node, "contributor")
    end
  end

  describe "a ProfilePage" do
    test "is an allowed type, and its main entity is the person", %{admin: admin, type: type} do
      ada = person!(admin, type, "Ada Lovelace")

      {:ok, %{json_ld: %{"@graph" => [node | _]}}} =
        KilnCMS.Firing.Engine.fire(ada, mode: :preview)

      assert node["@type"] == "ProfilePage"
      assert node["mainEntity"] == %{"@type" => "Person", "name" => "Ada Lovelace"}
    end
  end

  describe "Kiln's own pages" do
    test "the post page's By line and JSON-LD name the byline", %{
      conn: conn,
      admin: admin,
      type: type
    } do
      authors = byline_field!(admin, type, %{schema_org_property: :author})
      ada = person!(admin, type, "Ada Lovelace")
      grace = person!(admin, type, "Grace Hopper")

      writer = user(:admin, %{name: "Console Person"})
      post = post!(writer, %{authors.name => [ref(ada), ref(grace)]})

      html = conn |> get("/blog/#{post.slug}") |> html_response(200)
      doc = LazyHTML.from_document(html)

      byline = doc |> LazyHTML.query(".public-byline") |> LazyHTML.text()
      assert byline =~ ~r/By\s+Ada Lovelace\s+and\s+Grace Hopper/
      refute html =~ "Console Person"

      assert doc |> LazyHTML.query(".public-byline a") |> LazyHTML.attribute("href") ==
               Enum.map([ada, grace], fn p ->
                 "#{KilnCMSWeb.Tenant.base_url(post.org_id)}/#{type.path_segment}/#{p.slug}"
               end)

      [main | _] =
        doc
        |> LazyHTML.query(~s(script[type="application/ld+json"]))
        |> LazyHTML.text()
        |> Jason.decode!()

      assert names(main["author"]) == ["Ada Lovelace", "Grace Hopper"]
    end

    test "with no byline the console user is still the author", %{conn: conn} do
      writer = user(:admin, %{name: "Console Person"})
      post = post!(writer, %{})

      html = conn |> get("/blog/#{post.slug}") |> html_response(200)
      assert html =~ "By Console Person"
      assert html =~ ~s("author":{"@type":"Person","name":"Console Person"})
    end

    test "for_document/1 is empty without a flagged field",
         %{admin: admin} do
      post = post!(admin, %{})
      assert Bylines.for_document(post) == %{}
    end
  end
end
