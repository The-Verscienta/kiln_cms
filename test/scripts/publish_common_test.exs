Code.require_file("../../scripts/publish/common.exs", __DIR__)

defmodule KilnCMS.Scripts.PublishCommonTest do
  @moduledoc """
  The parts of `scripts/publish/common.exs` that are not covered through
  `scripts/publish/releases.exs`: the guide-level search description the docs
  publisher sends as `seo_description` (#1876).
  """
  use ExUnit.Case, async: true

  alias KilnPublish.Markdown

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
end
