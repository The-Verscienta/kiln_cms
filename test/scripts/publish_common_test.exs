Code.require_file("../../scripts/publish/common.exs", __DIR__)

defmodule KilnCMS.Scripts.PublishCommonTest do
  @moduledoc """
  The parts of `scripts/publish/common.exs` that are not covered through
  `scripts/publish/releases.exs`: the guide-level search description the docs
  publisher sends as `seo_description` (#1876), and the schema probe the
  release publisher uses to decide on the index's sign-up (#1870).
  """
  use ExUnit.Case, async: true

  alias KilnPublish.{API, Markdown}

  describe "seo_description/1" do
    test "reads the comment, collapsing its line breaks" do
      markdown = """
      # Kiln vs Ghost

      <!-- seo-description: How Kiln compares with Ghost,
           with sources. -->

      Body.
      """

      assert Markdown.seo_description(markdown) == "How Kiln compares with Ghost, with sources."
    end

    test "is nil without one, or with an empty one" do
      assert Markdown.seo_description("# Title\n\nBody.\n") == nil
      assert Markdown.seo_description("<!-- seo-description:   -->\n") == nil
    end

    test "an ordinary comment is not a description" do
      assert Markdown.seo_description("<!-- a maintainer note -->\n") == nil
    end

    test "the comment never reaches the published body" do
      html =
        "<!-- seo-description: Hidden. -->\n\nVisible.\n"
        |> Markdown.parse("test.md")
        |> Markdown.render()

      refute html =~ "Hidden"
      assert html =~ "Visible."
    end
  end

  describe "schema/1" do
    # The client's base URL is `/api/json` and it sends JSON:API's media type;
    # the schema lives at `/api/schema` on the `:api` pipeline, which accepts
    # plain JSON only.
    test "reads /api/schema as plain JSON" do
      req =
        API.client("https://site.test/", "key")
        |> Req.merge(
          plug: fn conn ->
            send(self(), {:request, conn.request_path, Plug.Conn.get_req_header(conn, "accept")})
            Plug.Conn.send_resp(conn, 200, ~s({"$defs":{"block_heading":{}}}))
          end
        )

      assert {:ok, %{"$defs" => %{"block_heading" => %{}}}} = API.schema(req)
      assert_received {:request, "/api/schema", ["application/json"]}
    end
  end
end
