defmodule KilnCMS.Blocks.FileTest do
  @moduledoc """
  The document-attachment block (#481): the download link is always built
  from `media_id` alone (never a stored URL — a gated item has none to
  store), the title falls back to `filename`, and every rendered value is
  escaped.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.File, as: FileBlock

  defp file(attrs), do: struct(%FileBlock{_type: "file"}, attrs)
  defp web(block), do: block |> Blocks.render(:web) |> IO.iodata_to_binary()

  describe "an empty (just-inserted) block" do
    test "renders an empty placeholder, not a broken link" do
      assert web(file(%{})) == "<div class=\"kiln-file\"></div>"
    end

    test "the :json surface carries no download_url either" do
      assert Blocks.render(file(%{}), :json) == %{"_type" => "file"}
    end
  end

  describe "a filled block" do
    test "the href is built from media_id alone, not from a stored url" do
      html = web(file(%{media_id: "abc-123", filename: "brochure.pdf"}))
      assert html =~ ~s(href="/media/abc-123/download")
    end

    test "download links carry a `download` attribute" do
      html = web(file(%{media_id: "abc-123", filename: "brochure.pdf"}))
      assert html =~ "download>"
    end

    test "the title falls back to the filename when blank" do
      html = web(file(%{media_id: "id", filename: "annual-report.pdf", title: nil}))
      assert html =~ ">annual-report.pdf<"
    end

    test "an explicit title overrides the filename" do
      html = web(file(%{media_id: "id", filename: "annual-report.pdf", title: "2026 Report"}))
      assert html =~ ">2026 Report<"
      refute html =~ "annual-report.pdf"
    end

    test "byte_size renders as a human-readable badge" do
      html = web(file(%{media_id: "id", filename: "f.pdf", byte_size: 2_097_152}))
      assert html =~ "2.0 MB"
    end

    test "no badge when byte_size is unknown" do
      html = web(file(%{media_id: "id", filename: "f.pdf", byte_size: nil}))
      refute html =~ "kiln-file-size"
    end

    test "a description renders as its own paragraph" do
      html = web(file(%{media_id: "id", filename: "f.pdf", description: "Read this first"}))
      assert html =~ "<p class=\"kiln-file-description\">Read this first</p>"
    end
  end

  describe "escaping" do
    test "a title with markup is escaped, not injected raw" do
      html = web(file(%{media_id: "id", filename: "f.pdf", title: "<script>alert(1)</script>"}))
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "a description with markup is escaped" do
      html =
        web(
          file(%{media_id: "id", filename: "f.pdf", description: "<img src=x onerror=alert(1)>"})
        )

      refute html =~ "<img src=x onerror=alert(1)>"
      assert html =~ "&lt;img"
    end
  end

  describe ":json surface" do
    test "carries a download_url built the same way the :web href is" do
      json = Blocks.render(file(%{media_id: "abc", filename: "f.pdf", byte_size: 10}), :json)

      assert json["_type"] == "file"
      assert json["media_id"] == "abc"
      assert json["download_url"] == "/media/abc/download"
      assert json["filename"] == "f.pdf"
      assert json["byte_size"] == 10
    end
  end

  describe ":json_ld surface" do
    test "contributes nothing — a download link isn't a discrete indexable entity" do
      assert Blocks.render(file(%{media_id: "abc", filename: "f.pdf"}), :json_ld) == nil
    end
  end

  describe "search_text/1" do
    test "combines title and description" do
      block =
        file(%{media_id: "id", filename: "f.pdf", title: "Report", description: "Q4 numbers"})

      assert Blocks.search_text(block) == "Report Q4 numbers"
    end

    test "an empty block has no search text" do
      assert Blocks.search_text(file(%{})) == ""
    end
  end

  describe "to_markdown/1 (the :llm surface)" do
    test "a filled block is a real Markdown link" do
      block = file(%{media_id: "abc", filename: "f.pdf", title: "Report"})
      assert FileBlock.to_markdown(block) == "[Report](/media/abc/download)"
    end

    test "an empty block has no markdown" do
      assert FileBlock.to_markdown(file(%{})) == ""
    end
  end
end
