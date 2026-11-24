defmodule KilnCMSWeb.BlockViewsTest do
  @moduledoc """
  `KilnCMSWeb.BlockViews.document_view_blocks/3`: a document's blocks as view
  maps with fragments inlined (#2767). Every preview renders through it, so a
  tree without a fragment must cost nothing beyond `view_blocks/1`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Test.QueryCounting
  alias KilnCMSWeb.BlockViews

  # A dynamic-type document: working out its public type is a definition read.
  defp dynamic_document(org) do
    %{
      id: Ash.UUID.generate(),
      org_id: org.id,
      locale: "en",
      audience: :public,
      type_definition_id: Ash.UUID.generate()
    }
  end

  test "a tree with no fragment renders without a single query" do
    document = dynamic_document(KilnCMS.OrgFixtures.org("bv-none"))

    blocks = [
      %{"_type" => "heading", "text" => "Plain"},
      %{
        "_type" => "columns",
        "columns" => [%{"blocks" => [%{"_type" => "video", "media_id" => Ash.UUID.generate()}]}]
      }
    ]

    {views, queries} =
      QueryCounting.queries(fn -> BlockViews.document_view_blocks(blocks, document) end)

    assert [%{type: "heading", content: "Plain"}, %{type: "columns"}] = views
    assert queries == []
  end

  test "a fragment, even one nested in columns, is resolved and inlined" do
    org = KilnCMS.OrgFixtures.org("bv-nested")

    shared =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Shared",
        slug: "bv-#{System.unique_integer([:positive])}",
        state: :published,
        org_id: org.id,
        blocks: [%{"_type" => "heading", "text" => "From the fragment"}]
      })

    fragment = %{"_type" => "fragment", "ref" => %{"type" => "page", "id" => shared.id}}
    blocks = [%{"_type" => "columns", "columns" => [%{"blocks" => [fragment]}]}]

    {views, queries} =
      QueryCounting.queries(fn ->
        BlockViews.document_view_blocks(blocks, dynamic_document(org))
      end)

    assert [%{type: "columns", columns: [%{blocks: [inlined]}]}] = views
    assert %{type: "heading", content: "From the fragment"} = inlined
    # The host's type is looked up only now that there is a fragment to seed
    # the cycle guard with.
    assert Enum.any?(queries, &(&1.source == "type_definitions"))
  end
end
