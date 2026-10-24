defmodule KilnCMS.Firing.LiveBlogTest do
  @moduledoc """
  `LiveBlogPosting` in the fired `:json_ld` surface (#2046), composed the way
  verscienta-news composes it: a `LiveStory` type, and a `LiveUpdate` type whose
  `story` reference has another side ("Updates").
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.{Engine, LiveBlog, SchemaOrg}

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "live-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    n = System.unique_integer([:positive])

    story_type =
      CMS.create_type_definition!(
        %{name: "story#{n}", label: "Live story", schema_org_type: "LiveBlogPosting"},
        actor: admin
      )

    CMS.create_field_definition!(
      %{
        type_definition_id: story_type.id,
        name: "coverage",
        label: "Coverage",
        field_type: "datetime_range"
      },
      actor: admin
    )

    update_type =
      CMS.create_type_definition!(%{name: "update#{n}", label: "Live update"}, actor: admin)

    CMS.create_field_definition!(
      %{
        type_definition_id: update_type.id,
        name: "story",
        label: "Story",
        field_type: :reference,
        target_type: story_type.name,
        inverse_label: "Updates"
      },
      actor: admin
    )

    %{
      admin: admin,
      org: KilnCMS.Accounts.default_org_id(),
      story_type: story_type.name,
      update_type: update_type.name
    }
  end

  defp slug, do: "live-#{System.unique_integer([:positive])}"

  defp published!(type, attrs, admin) do
    record = ContentTypes.create!(type, Map.put_new(attrs, :slug, slug()), actor: admin)
    {:ok, record} = ContentTypes.transition(type, "publish", record, actor: admin)
    record
  end

  defp story!(ctx, custom_fields \\ %{}),
    do:
      published!(
        ctx.story_type,
        %{title: "Election night", custom_fields: custom_fields},
        ctx.admin
      )

  defp update!(ctx, story, title, attrs \\ %{}) do
    published!(
      ctx.update_type,
      Map.merge(%{title: title, custom_fields: %{"story" => story.id}}, attrs),
      ctx.admin
    )
  end

  defp fired_node(ctx, story) do
    Engine.fire(story)
    KilnCMS.DataCase.drain_oban()
    {:ok, ld} = Engine.read(ctx.org, :entry, story.id, :json_ld)
    hd(ld["@graph"])
  end

  test "LiveBlogPosting is an allowlisted Article-family type" do
    assert "LiveBlogPosting" in SchemaOrg.types()
    assert SchemaOrg.article_type?("LiveBlogPosting")
    assert SchemaOrg.live_blog_type?("LiveBlogPosting")
    refute SchemaOrg.live_blog_type?("BlogPosting")
  end

  test "fires coverage times and its published updates, newest first", ctx do
    story =
      story!(ctx, %{
        "coverage" => %{
          "start" => "2026-11-03T18:00",
          "end" => "2026-11-04T06:00",
          "time_zone" => "Etc/UTC"
        }
      })

    update!(ctx, story, "Polls open")
    update!(ctx, story, "First results")

    node = fired_node(ctx, story)

    assert node["@type"] == "LiveBlogPosting"
    assert node["headline"] == "Election night"
    assert Map.has_key?(node, "articleBody")
    assert node["coverageStartTime"] == "2026-11-03T18:00:00Z"
    assert node["coverageEndTime"] == "2026-11-04T06:00:00Z"

    assert [first, second] = node["liveBlogUpdate"]
    assert %{"@type" => "BlogPosting", "headline" => "First results"} = first
    assert second["headline"] == "Polls open"
    assert is_binary(first["datePublished"])
  end

  test "an unpublished update drops out on re-fire", ctx do
    story = story!(ctx)
    kept = update!(ctx, story, "Kept")
    dropped = update!(ctx, story, "Retracted")

    assert ctx |> fired_node(story) |> Map.get("liveBlogUpdate") |> length() == 2

    {:ok, _} = ContentTypes.transition(ctx.update_type, "unpublish", dropped, actor: ctx.admin)

    assert [%{"headline" => headline}] = fired_node(ctx, story)["liveBlogUpdate"]
    assert headline == kept.title
  end

  test "drafts, members-only updates and other stories' updates are left out", ctx do
    story = story!(ctx)
    other = story!(ctx)

    update!(ctx, story, "Public")
    update!(ctx, other, "Elsewhere")

    ContentTypes.create!(
      ctx.update_type,
      %{title: "Draft", slug: slug(), custom_fields: %{"story" => story.id}},
      actor: ctx.admin
    )

    update!(ctx, story, "Members", %{audience: :member})

    assert Enum.map(LiveBlog.updates(story), & &1.title) == ["Public"]
  end

  test "the update list is capped, keeping the newest", ctx do
    story = story!(ctx)
    for i <- 1..3, do: update!(ctx, story, "Update #{i}")

    Application.put_env(:kiln_cms, LiveBlog, max_updates: 2)
    on_exit(fn -> Application.delete_env(:kiln_cms, LiveBlog) end)

    assert Enum.map(LiveBlog.updates(story), & &1.title) == ["Update 3", "Update 2"]
  end

  test "with no coverage range, coverage starts at publication and is open-ended", ctx do
    story = story!(ctx)

    props = LiveBlog.properties(story)

    assert props["coverageStartTime"] == DateTime.to_iso8601(story.published_at)
    refute Map.has_key?(props, "coverageEndTime")
    assert props["liveBlogUpdate"] == []
  end

  test "the served page's inline JSON-LD carries the same updates", ctx do
    story = story!(ctx)
    update!(ctx, story, "On the page too")

    ct = ContentTypes.get(ctx.story_type, ctx.org)
    node = KilnCMSWeb.StructuredData.build(story, ct, ctx.org)

    assert node["@type"] == "LiveBlogPosting"
    assert [%{"headline" => "On the page too"}] = node["liveBlogUpdate"]
    assert node["coverageStartTime"] == fired_node(ctx, story)["coverageStartTime"]
  end
end
