defmodule KilnCMS.CMS.NestedReferenceMaskingTest do
  @moduledoc """
  The read-side safety net for reference and media snapshots that sit inside
  the items of a `:flexible` field (#2282, `docs/flexible-content-plan.md`
  section 6): a draft target named by a snapshot nested in an item, or two
  levels down, reaches no reader who could not read the target itself, through
  JSON:API, GraphQL, the Ash reads behind the public site, the fired `:json`
  artifact or a point-in-time replay; and the re-fire graph and the artifact's
  labels follow a nested snapshot as they follow a top-level one.

  The media and reference sub-field *types* are still locked in item
  definitions, so the stored items are built by hand (`Ash.Seed.update!/2`),
  which is also what a value written by a later release, or restored from a
  backup, looks like. A distinctive canary title is searched for in every
  serialized response; an editor must see it, so a broken fixture cannot make
  the absence vacuous.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Firing
  alias KilnCMS.Firing.{Engine, References}
  alias KilnCMS.Media.Snapshot

  @accept "application/vnd.api+json"
  @password "password123456"
  @canary "CANARY-draft-title-7f3a"
  @schema KilnCMSWeb.GraphqlSchema

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "nested-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => user.email, "password" => @password},
        []
      )

    signed_in.__metadata__.token
  end

  defp slug, do: "nested-#{System.unique_integer([:positive])}"

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)

  defp sub!(admin, parent, name, attrs \\ %{}),
    do: def!(admin, Map.merge(%{name: name, group_of_id: parent.id, field_type: :string}, attrs))

  defp item_type!(admin, flexible, name),
    do: def!(admin, %{name: name, field_type: :group, flex_of_id: flexible.id, label: name})

  defp page!(admin, title, publish?) do
    page = CMS.create_page!(%{title: title, slug: slug()}, actor: admin)
    if publish?, do: CMS.publish_page!(page, %{}, actor: admin), else: page
  end

  defp reference(page),
    do: %{"id" => page.id, "type" => "page", "slug" => page.slug, "title" => page.title}

  defp media! do
    Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
      filename: "pic-#{System.unique_integer([:positive])}.png",
      url: "/uploads/pic.png",
      alt: "Alt text",
      content_type: "image/png"
    })
  end

  # sections (1) > section.rows (2) > row. The hand-built tree puts a
  # reference and a media snapshot into a section and another pair into its
  # row.
  setup do
    admin = user(:admin)
    sections = def!(admin, %{content_type: :post, name: "sections", field_type: :flexible})
    section = item_type!(admin, sections, "section")
    sub!(admin, section, "title")
    rows = sub!(admin, section, "rows", %{field_type: :flexible, position: 1})
    row = item_type!(admin, rows, "row")
    sub!(admin, row, "label")

    live = page!(admin, "Live target", true)
    draft = page!(admin, @canary, false)
    media = media!()

    items = fn ref, deep_ref, media ->
      [
        %{
          "_id" => Ecto.UUID.generate(),
          "_type" => "section",
          "title" => "Intro",
          "cta" => ref,
          "pic" => Snapshot.of(media),
          "rows" => [
            %{
              "_id" => Ecto.UUID.generate(),
              "_type" => "row",
              "label" => "Row",
              "cta" => deep_ref,
              "pic" => Snapshot.of(media),
              "others" => [live |> reference(), deep_ref]
            }
          ]
        }
      ]
    end

    post =
      admin
      |> then(&CMS.create_post!(%{title: "Referrer", slug: slug()}, actor: &1))
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))

    stored = %{"sections" => items.(reference(draft), reference(draft), media)}
    post = Ash.Seed.update!(post, %{custom_fields: stored})

    %{
      admin: admin,
      editor: user(:editor),
      viewer: user(:viewer),
      post: post,
      live: live,
      draft: draft,
      media: media,
      items: items,
      org: KilnCMS.Accounts.default_org_id()
    }
  end

  defp read(post, actor), do: CMS.get_post!(post.id, actor: actor)

  # The first section, and the first row of its `rows`.
  defp section(fields), do: fields |> Map.fetch!("sections") |> hd()
  defp row(fields), do: fields |> section() |> Map.fetch!("rows") |> hd()

  defp api_get(path, token \\ nil) do
    conn = put_req_header(build_conn(), "accept", @accept)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    conn = get(conn, path)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp artifact(post, org) do
    {:ok, artifact} = Firing.get_artifact(:post, post.id, :json, authorize?: false, tenant: org)
    artifact.body
  end

  describe "an Ash read (the public site, the console)" do
    test "an anonymous reader and a viewer lose a draft target at both levels", ctx do
      for actor <- [nil, ctx.viewer] do
        fields = read(ctx.post, actor).custom_fields

        assert %{"cta" => nil, "title" => "Intro"} = section(fields)
        assert %{"cta" => nil, "label" => "Row"} = row(fields)
        refute inspect(fields) =~ @canary
        refute inspect(fields) =~ ctx.draft.id
        # A hidden snapshot is dropped from a list, the readable one stays.
        assert [%{"id" => id}] = row(fields)["others"]
        assert id == ctx.live.id
      end
    end

    test "an editor sees the stored value, a draft target included", ctx do
      fields = read(ctx.post, ctx.editor).custom_fields

      assert section(fields)["cta"]["title"] == @canary
      assert row(fields)["cta"]["title"] == @canary
    end

    test "the target reappears for everyone once it is published", ctx do
      assert section(read(ctx.post, nil).custom_fields)["cta"] == nil

      CMS.publish_page!(ctx.draft, %{}, actor: ctx.admin)

      fields = read(ctx.post, nil).custom_fields
      assert section(fields)["cta"]["id"] == ctx.draft.id
      assert row(fields)["cta"]["id"] == ctx.draft.id
    end

    test "a renamed target is served under its current name, nested too", ctx do
      CMS.update_page!(ctx.live, %{title: "Renamed live"}, actor: ctx.admin)

      stored =
        ctx.items.(reference(ctx.live), reference(ctx.live), ctx.media)

      post = Ash.Seed.update!(ctx.post, %{custom_fields: %{"sections" => stored}})
      fields = read(post, nil).custom_fields

      assert section(fields)["cta"]["title"] == "Renamed live"
      assert row(fields)["cta"]["title"] == "Renamed live"
      # The stored value is never rewritten.
      assert section(read(post, ctx.admin).custom_fields)["cta"]["title"] == "Live target"
    end

    test "an item whose sub-fields are named like a snapshot is not mistaken for one", ctx do
      lookalike = %{
        "_id" => Ecto.UUID.generate(),
        "_type" => "section",
        "id" => ctx.draft.id,
        "type" => "page",
        "slug" => "a-slug",
        "title" => "An ordinary string sub-field"
      }

      post = Ash.Seed.update!(ctx.post, %{custom_fields: %{"sections" => [lookalike]}})
      assert read(post, nil).custom_fields["sections"] == [lookalike]
    end

    test "a media snapshot nested in an item is untouched", ctx do
      fields = read(ctx.post, nil).custom_fields
      assert section(fields)["pic"]["id"] == ctx.media.id
      assert row(fields)["pic"]["url"] == "/uploads/pic.png"
    end
  end

  describe "JSON:API and GraphQL" do
    test "JSON:API leaves the draft out below editor and keeps it for an editor", ctx do
      path = "/api/json/posts/#{ctx.post.id}?fields[post]=custom_fields"

      assert {200, %{"data" => %{"attributes" => %{"custom_fields" => anonymous}}}} =
               api_get(path)

      assert section(anonymous)["cta"] == nil
      assert row(anonymous)["cta"] == nil
      refute inspect(anonymous) =~ @canary

      assert {200, %{"data" => %{"attributes" => %{"custom_fields" => viewer}}}} =
               api_get(path, token(ctx.viewer))

      refute inspect(viewer) =~ @canary

      assert {200, %{"data" => %{"attributes" => %{"custom_fields" => editor}}}} =
               api_get(path, token(ctx.editor))

      assert section(editor)["cta"]["title"] == @canary
      assert row(editor)["cta"]["title"] == @canary
    end

    test "GraphQL leaves the draft out below editor and keeps it for an editor", ctx do
      query = """
      query ($slug: String!) { postBySlug(slug: $slug, locale: "en") { customFields } }
      """

      run = fn actor ->
        {:ok, %{data: %{"postBySlug" => %{"customFields" => json}}}} =
          Absinthe.run(query, @schema,
            variables: %{"slug" => ctx.post.slug},
            context: %{actor: actor}
          )

        Jason.decode!(json)
      end

      for actor <- [nil, ctx.viewer] do
        fields = run.(actor)
        assert section(fields)["cta"] == nil
        assert row(fields)["cta"] == nil
        refute inspect(fields) =~ @canary
      end

      assert row(run.(ctx.editor))["cta"]["title"] == @canary
    end
  end

  describe "the fired :json artifact" do
    test "leaves a draft target out at both levels and keeps the stored value", ctx do
      {:ok, _} = Engine.fire(read(ctx.post, ctx.admin))
      fields = artifact(ctx.post, ctx.org)["custom_fields"]

      assert %{"cta" => nil, "title" => "Intro"} = section(fields)
      assert %{"cta" => nil, "label" => "Row"} = row(fields)
      refute inspect(fields) =~ @canary
      refute inspect(fields) =~ ctx.draft.id

      assert section(read(ctx.post, ctx.admin).custom_fields)["cta"]["title"] == @canary
    end

    test "a point-in-time fire (recompute off) masks too", ctx do
      {:ok, bodies} =
        Engine.fire(read(ctx.post, ctx.admin), mode: :preview, custom_fields: :as_stored)

      fields = bodies.json["custom_fields"]
      assert section(fields)["cta"] == nil
      assert row(fields)["cta"] == nil
      refute inspect(fields) =~ @canary
      # A readable target is still there, and a media snapshot is as stored.
      assert [%{"id" => id}] = row(fields)["others"]
      assert id == ctx.live.id
      assert section(fields)["pic"]["id"] == ctx.media.id
    end

    test "publishing the target re-fires the referrer and brings it back", ctx do
      {:ok, _} = Engine.fire(read(ctx.post, ctx.admin))
      assert section(artifact(ctx.post, ctx.org)["custom_fields"])["cta"] == nil

      # The edge exists although the only use of the target is inside an item.
      {:ok, edges} = Firing.edges_from(:post, ctx.post.id, authorize?: false)
      assert {:page, ctx.draft.id} in Enum.map(edges, &{&1.to_type, &1.to_id})

      CMS.publish_page!(ctx.draft, %{}, actor: ctx.admin)
      assert %{failure: 0} = KilnCMS.DataCase.drain_oban()

      fields = artifact(ctx.post, ctx.org)["custom_fields"]
      assert section(fields)["cta"]["id"] == ctx.draft.id
      assert row(fields)["cta"]["title"] == @canary
    end

    test "renaming a published target changes the title in the item", ctx do
      stored = ctx.items.(reference(ctx.live), reference(ctx.live), ctx.media)
      post = Ash.Seed.update!(ctx.post, %{custom_fields: %{"sections" => stored}})
      {:ok, _} = Engine.fire(read(post, ctx.admin))

      CMS.update_page!(ctx.live, %{title: "Brand new title"}, actor: ctx.admin)
      assert %{failure: 0} = KilnCMS.DataCase.drain_oban()

      fields = artifact(post, ctx.org)["custom_fields"]
      assert section(fields)["cta"]["title"] == "Brand new title"
      assert row(fields)["cta"]["title"] == "Brand new title"
    end

    test "unpublishing a target takes it out of the artifact again", ctx do
      stored = ctx.items.(reference(ctx.live), reference(ctx.live), ctx.media)
      post = Ash.Seed.update!(ctx.post, %{custom_fields: %{"sections" => stored}})
      {:ok, _} = Engine.fire(read(post, ctx.admin))
      assert section(artifact(post, ctx.org)["custom_fields"])["cta"]["id"] == ctx.live.id

      CMS.unpublish_page!(ctx.live, %{}, actor: ctx.admin)
      assert %{failure: 0} = KilnCMS.DataCase.drain_oban()

      assert section(artifact(post, ctx.org)["custom_fields"])["cta"] == nil
    end

    test "a media snapshot in an item is rebuilt from the library item", ctx do
      assert section(read(ctx.post, ctx.admin).custom_fields)["pic"]["variants"] == []

      Ash.Seed.update!(ctx.media, %{
        alt: "Fresh alt",
        width: 1600,
        height: 900,
        variants: %{
          "thumb" => %{"url" => "/uploads/thumb.png", "width" => 400, "height" => 225}
        }
      })

      {:ok, _} = Engine.fire(read(ctx.post, ctx.admin))
      fields = artifact(ctx.post, ctx.org)["custom_fields"]

      for pic <- [section(fields)["pic"], row(fields)["pic"]] do
        assert pic["alt"] == "Fresh alt"
        assert pic["width"] == 1600
        assert [%{"label" => "thumb"}] = pic["variants"]
      end

      # Not rewritten: a fire is not an edit.
      assert section(read(ctx.post, ctx.admin).custom_fields)["pic"]["variants"] == []
    end
  end

  describe "the re-fire graph and usage" do
    test "a media used only inside an item is an edge and counts as used", ctx do
      {:ok, _} = Engine.fire(read(ctx.post, ctx.admin))

      assert {:media, ctx.media.id} in References.document_refs(ctx.post)

      {:ok, edges} = Firing.edges_from(:post, ctx.post.id, authorize?: false)
      assert {:media, ctx.media.id} in Enum.map(edges, &{&1.to_type, &1.to_id})

      assert %{} = counts = References.usage_counts(ctx.org, [ctx.media.id], ctx.admin)
      assert counts[ctx.media.id] == 1
    end

    test "document_refs finds nested references once each and ignores look-alikes", ctx do
      assert References.document_refs(ctx.post)
             |> Enum.filter(&(elem(&1, 0) == :page))
             |> Enum.sort() ==
               Enum.sort([{:page, ctx.draft.id}, {:page, ctx.live.id}])

      lookalike = %{
        "_id" => Ecto.UUID.generate(),
        "_type" => "section",
        "id" => ctx.draft.id,
        "type" => "page",
        "slug" => "a-slug",
        "title" => "A string"
      }

      assert References.document_refs(%{
               blocks: [],
               featured_image_id: nil,
               custom_fields: %{"sections" => [lookalike]}
             }) == []
    end
  end
end
