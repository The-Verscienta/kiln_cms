defmodule KilnCMS.Portability.WXRTest do
  @moduledoc """
  Reading a WordPress export (#487). Pure parsing — no database, no network.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Portability.WXR
  alias KilnCMS.WXRFixture

  setup do
    {:ok, parsed} = WXR.parse(WXRFixture.wxr())
    %{parsed: parsed, records: parsed.records}
  end

  defp record(records, slug), do: Enum.find(records, &(&1.slug == slug))

  describe "channel" do
    test "reads the source site", %{parsed: parsed} do
      assert parsed.site.title == "Old Blog"
      assert parsed.site.url == "https://old.example.com"
    end

    test "reads authors", %{parsed: parsed} do
      assert [%{login: "jo", email: "jo@old.example.com", name: "Jo Example"}] = parsed.authors
    end
  end

  describe "post type filtering" do
    test "imports posts and pages, and nothing else", %{records: records} do
      assert Enum.map(records, & &1.slug) |> Enum.sort() == ["about", "hello-world", "soon"]
    end

    test "a nav_menu_item is not content", %{records: records} do
      refute Enum.any?(records, &(&1.title == "Main menu"))
    end

    test "attachments are read separately from content", %{parsed: parsed, records: records} do
      refute Enum.any?(records, &(&1.title == "pic.jpg"))

      assert [%{source_id: "99", alt: "Alt from the library"}] = parsed.attachments
    end

    test "post vs page is carried through", %{records: records} do
      assert record(records, "hello-world").kind == :post
      assert record(records, "about").kind == :page
    end
  end

  describe "body conversion" do
    test "classic un-wrapped paragraphs become separate blocks", %{records: records} do
      body =
        records
        |> record("hello-world")
        |> Map.fetch!(:blocks)
        |> Enum.find(&(&1["type"] == "rich_text"))
        |> get_in(["value", "body"])

      assert length(body) == 2
      assert PortableText.to_plain_text(body) =~ "First paragraph with bold."
      assert PortableText.to_plain_text(body) =~ "Second paragraph."
    end

    test "an image in the body becomes an image block and is listed for sideloading", %{
      records: records
    } do
      post = record(records, "hello-world")

      assert Enum.any?(post.blocks, &(&1["type"] == "image"))
      assert post.image_urls == ["https://old.example.com/wp-content/pic.jpg"]
    end
  end

  describe "taxonomy" do
    test "categories and tags are told apart by domain, not position", %{records: records} do
      post = record(records, "hello-world")

      assert [%{name: "News", slug: "news"}] = post.categories
      assert Enum.map(post.tags, & &1.slug) |> Enum.sort() == ["beginner", "how-to"]
    end

    test "a record with no terms gets empty lists, not nil", %{records: records} do
      assert record(records, "about").categories == []
      assert record(records, "about").tags == []
    end
  end

  describe "state and dates" do
    test "only publish means published", %{records: records} do
      assert record(records, "hello-world").state == :published
      assert record(records, "about").state == :draft
    end

    # A `future` post's date has not arrived. Importing it as published would
    # put it live early — the one state where guessing costs more than asking.
    test "a scheduled (future) post lands as a draft with its date intact", %{records: records} do
      soon = record(records, "soon")

      assert soon.state == :draft
      assert soon.published_at == ~U[2030-01-01 00:00:00Z]
    end

    test "0000-00-00 is read as no date, not as year zero", %{records: records} do
      assert record(records, "about").published_at == nil
    end

    test "a real GMT date is parsed as UTC", %{records: records} do
      assert record(records, "hello-world").published_at == ~U[2024-03-01 09:15:00Z]
    end
  end

  describe "permalinks and featured images" do
    test "the old permalink is kept for redirect building", %{records: records} do
      assert record(records, "hello-world").source_url ==
               "https://old.example.com/2024/03/hello-world/"
    end

    test "_thumbnail_id points at an attachment's post id", %{records: records} do
      assert record(records, "hello-world").featured_source_id == "99"
    end
  end

  describe "robustness" do
    test "a non-WXR XML document is refused" do
      assert {:error, :not_a_wxr_file} = WXR.parse("<html><body>hi</body></html>")
    end

    test "malformed XML is an error, not a crash" do
      assert {:error, {:malformed_xml, _}} = WXR.parse("<rss><channel>")
    end

    test "a missing file is an error" do
      assert {:error, {:unreadable_file, :enoent}} = WXR.parse_file("/nope/missing.xml")
    end

    test "a percent-encoded slug is decoded" do
      xml =
        String.replace(
          WXRFixture.wxr(),
          "<wp:post_name><![CDATA[about]]></wp:post_name>",
          "<wp:post_name><![CDATA[%D0%BF%D1%80%D0%B8]]></wp:post_name>"
        )

      {:ok, parsed} = WXR.parse(xml)
      assert Enum.any?(parsed.records, &(&1.slug == "при"))
    end
  end
end
