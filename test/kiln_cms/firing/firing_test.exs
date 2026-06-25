defmodule KilnCMS.Firing.FiringTest do
  @moduledoc "Phase D — firing into immutable per-surface artifacts (decision D9)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.{CMS, Firing}
  alias KilnCMS.Firing.{Cache, Engine}

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fire-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "fire-#{System.unique_integer([:positive])}"

  defp published_page(actor) do
    page =
      CMS.create_page!(
        %{
          title: "Fired",
          slug: slug(),
          blocks: [
            %{type: :heading, content: "Welcome", data: %{"level" => 1}, order: 0},
            %{type: :rich_text, content: "<p>Body</p>", order: 1}
          ]
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
  end

  describe "firing on publish" do
    test "fires all three surfaces with format_version 1" do
      actor = admin()
      page = published_page(actor)

      {:ok, artifacts} = Firing.artifacts_for(:page, page.id, authorize?: false)
      surfaces = artifacts |> Enum.map(& &1.surface) |> Enum.sort()

      assert surfaces == [:json, :json_ld, :web]
      assert Enum.all?(artifacts, &(&1.format_version == 1))
    end

    test "the web artifact is pre-rendered HTML from the typed serializers" do
      page = published_page(admin())
      {:ok, %{"html" => html}} = Engine.read(:page, page.id, :web)

      assert html =~ "<h1>Welcome</h1>"
      assert html =~ "<p>Body</p>"
    end

    test "the json artifact carries structured intent" do
      page = published_page(admin())
      {:ok, json} = Engine.read(:page, page.id, :json)

      assert json["type"] == "page"
      assert json["title"] == "Fired"
      assert [%{"_type" => "heading"} | _] = json["blocks"]
    end

    test "the json_ld artifact is a schema.org graph derived from the blocks (Phase J)" do
      actor = admin()

      page =
        CMS.create_page!(
          %{
            title: "Graphed",
            slug: slug(),
            blocks: [
              %{type: :heading, content: "T", order: 0},
              %{type: :image, data: %{"url" => "/p.png", "alt" => "pic"}, order: 1}
            ]
          },
          actor: actor
        )

      page = CMS.publish_page!(page, actor: actor)
      {:ok, ld} = Engine.read(:page, page.id, :json_ld)

      assert ld["@context"] == "https://schema.org"
      types = Enum.map(ld["@graph"], & &1["@type"])
      assert "Article" in types
      assert "ImageObject" in types
    end
  end

  describe "reads never touch the live tree" do
    test "editing the live document after publish does not change the fired artifact" do
      actor = admin()
      page = published_page(actor)

      # Mutate the live draft AFTER publishing; do not re-publish.
      CMS.update_page!(page, %{title: "Changed Live"}, actor: actor)

      {:ok, json} = Engine.read(:page, page.id, :json)
      # Still the fired snapshot, not the live edit.
      assert json["title"] == "Fired"
    end
  end

  describe "unpublish" do
    test "removes artifacts and evicts the cache" do
      actor = admin()
      page = published_page(actor)
      assert {:ok, _} = Engine.read(:page, page.id, :web)

      CMS.unpublish_page!(page, actor: actor)

      assert {:ok, []} = Firing.artifacts_for(:page, page.id, authorize?: false)
      assert :miss = Cache.get(:page, page.id, :web)
      assert :error = Engine.read(:page, page.id, :web)
    end
  end

  describe "preview mode" do
    test "compiles to memory without persisting artifacts" do
      actor = admin()

      page =
        CMS.create_page!(
          %{title: "Draft", slug: slug(), blocks: [%{type: :heading, content: "Hi", order: 0}]},
          actor: actor
        )

      {:ok, artifacts} = Engine.fire(page, mode: :preview)

      assert artifacts.web["html"] =~ "<h2>Hi</h2>"
      assert {:ok, []} = Firing.artifacts_for(:page, page.id, authorize?: false)
    end
  end
end
