Code.require_file("../../scripts/publish/releases.exs", __DIR__)

defmodule KilnCMS.Scripts.PublishReleasesTest do
  @moduledoc """
  `scripts/publish_releases.exs` publishes each release's notes to kilncms.dev
  (#1870). It runs in CI without the application compiled, so its logic lives
  in `scripts/publish/releases.exs` and is loaded here directly: the parsing,
  slug and payload building, none of which needs a site or the network.
  """
  use ExUnit.Case, async: true

  alias KilnPublish.Markdown

  @changelog """
  # Changelog

  ## [Unreleased]

  ### Added

  - **Something not yet released.**
    ([#9](https://example.test/9))

  ## [1.2.0] - 2026-11-01

  Long form: [docs/changelog/v1.2.0.md](docs/changelog/v1.2.0.md)

  ### Upgrade notes

  - **Run `mix kiln.thing` before
    upgrading.**
    ([#1](https://example.test/1))

  ### Fixed

  - **A fix is not a highlight.**
    ([#2](https://example.test/2))

  ### Added

  - **A new &amp; shiny feature.**
    ([#3](https://example.test/3))

  - **Another one.** With trailing prose.

  ### Breaking

  - **Removed the old API.**

  ## [1.1.0] - 2026-10-20

  ### Added

  - **Older.**

  ## [0.1.0]

  ### Upgrade notes

  - **Undated.**
  """

  describe "parse_version/1" do
    test "takes a tag with or without its v" do
      assert {:ok, %{tag: "v1.0.0", version: "1.0.0", prerelease?: false}} =
               PublishReleases.parse_version("v1.0.0")

      assert {:ok, %{tag: "v1.0.0", version: "1.0.0"}} = PublishReleases.parse_version("1.0.0")
    end

    test "marks a release candidate as a pre-release" do
      assert {:ok, %{tag: "v1.1.0-rc.1", prerelease?: true}} =
               PublishReleases.parse_version("v1.1.0-rc.1")
    end

    test "refuses anything that is not a version" do
      for input <- ["", "v1", "v1.0", "latest", "v1.0.0+build.1", "vv1.0.0"] do
        assert {:error, _} = PublishReleases.parse_version(input), input
      end
    end
  end

  describe "slug/1" do
    test "turns every dot into a hyphen, so the slug passes content slug validation" do
      assert PublishReleases.slug("v1.0.0") == "v1-0-0"
      assert PublishReleases.slug("v0.12.1") == "v0-12-1"
      assert PublishReleases.slug("v1.1.0-rc.1") == "v1-1-0-rc-1"

      for tag <- ~w(v1.0.0 v0.12.1 v1.1.0-rc.1 v2.0.0-beta.10) do
        assert PublishReleases.slug(tag) =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
      end
    end
  end

  describe "changelog_section/2" do
    test "returns a release's heading date and only its own section" do
      {:ok, parsed} = PublishReleases.parse_version("v1.2.0")
      assert {"2026-11-01", section} = PublishReleases.changelog_section(@changelog, parsed)
      assert section =~ "Removed the old API"
      refute section =~ "Older."
      refute section =~ "Something not yet released"
    end

    test "an undated heading has no date" do
      {:ok, parsed} = PublishReleases.parse_version("v0.1.0")
      assert {nil, section} = PublishReleases.changelog_section(@changelog, parsed)
      assert section =~ "Undated."
    end

    test "a pre-release reads the Unreleased section" do
      {:ok, parsed} = PublishReleases.parse_version("v1.3.0-rc.1")
      assert {nil, section} = PublishReleases.changelog_section(@changelog, parsed)
      assert section =~ "Something not yet released"
      refute section =~ "Removed the old API"
    end

    test "a version CHANGELOG.md doesn't name has no section" do
      {:ok, parsed} = PublishReleases.parse_version("v9.9.9")
      assert PublishReleases.changelog_section(@changelog, parsed) == nil
    end

    test "1.2.0 does not match a 1.2.0-something heading or 11.2.0" do
      changelog = "## [11.2.0] - 2026-01-01\n\n## [1.2.0-rc.1]\n"
      {:ok, parsed} = PublishReleases.parse_version("v1.2.0")
      assert PublishReleases.changelog_section(changelog, parsed) == nil
    end
  end

  describe "highlights/1" do
    test "the bold leads of Upgrade notes, Breaking and Added, in that order, one per line" do
      {:ok, parsed} = PublishReleases.parse_version("v1.2.0")
      {_date, section} = PublishReleases.changelog_section(@changelog, parsed)

      assert PublishReleases.highlights(section) ==
               Enum.join(
                 [
                   "Run mix kiln.thing before upgrading.",
                   "Removed the old API.",
                   "A new & shiny feature.",
                   "Another one."
                 ],
                 "\n"
               )
    end

    test "no section, no highlights" do
      assert PublishReleases.highlights(nil) == ""
      assert PublishReleases.highlights("### Fixed\n\n- **Only a fix.**\n") == ""
    end

    test "stops at whole lines within 4000 characters" do
      line = String.duplicate("x", 990) <> "."
      section = "### Added\n\n" <> Enum.map_join(1..6, "\n", &"- **#{&1}#{line}**\n")
      highlights = PublishReleases.highlights(section)

      assert String.length(highlights) <= 4000
      assert highlights |> String.split("\n") |> length() == 4
      assert Enum.all?(String.split(highlights, "\n"), &String.ends_with?(&1, "."))
    end
  end

  describe "render/3" do
    @notes """
    # KilnCMS 1.2.0 — full release notes

    The long-form entries behind the 1.2.0 section of
    [CHANGELOG.md](../../CHANGELOG.md), as they were written.

    ## Added

    <a id="an-anchor"></a>

    - **A feature.** See [the guide](../deploy.md#tls), [the
      changelog](../../CHANGELOG.md) and [the web](https://example.test/x).

    <script>alert(1)</script>
    """

    test "drops the H1 and the repo-reader paragraph, and pins relative links to the tag" do
      html = PublishReleases.render(@notes, "docs/changelog/v1.2.0.md", "v1.2.0")

      refute html =~ "<h1>"
      refute html =~ "long-form entries behind"
      assert html =~ "<h2>Added</h2>"

      assert html =~
               ~s(href="https://github.com/The-Verscienta/kiln_cms/blob/v1.2.0/docs/deploy.md#tls")

      assert html =~
               ~s(href="https://github.com/The-Verscienta/kiln_cms/blob/v1.2.0/CHANGELOG.md")

      assert html =~ ~s(href="https://example.test/x")
      refute html =~ "an-anchor"
      refute html =~ "<script"
      refute html =~ "alert(1)"
    end

    test "keeps a first paragraph that is the release's own prose" do
      html =
        PublishReleases.render(
          "# T\n\nFirst tagged release.\n",
          "docs/changelog/v0.1.0.md",
          "v0.1.0"
        )

      assert html == "<p>First tagged release.</p>"
    end
  end

  describe "the shared renderer" do
    test "drops unsafe link schemes but keeps the text" do
      html = "[click](javascript:alert(1))" |> Markdown.parse("t") |> Markdown.render()
      assert html == "<p>click</p>"
    end

    test "escapes text and code" do
      html = "a <b> & `<i>`" |> Markdown.parse("t") |> Markdown.render()
      assert html == "<p>a &lt;b&gt; &amp; <code>&lt;i&gt;</code></p>"
    end
  end

  describe "entry_attrs/1" do
    test "the shape a release entry is written in; version and date are machine-readable" do
      release = %{
        title: "KilnCMS 1.2.0",
        html: "<p>Body</p>",
        version: "1.2.0",
        date: "2026-11-01",
        release_url: PublishReleases.release_url("v1.2.0"),
        highlights: "One.\nTwo."
      }

      assert PublishReleases.entry_attrs(release) == %{
               "title" => "KilnCMS 1.2.0",
               "block_tree" => [%{"_type" => "rich_text", "legacy_html" => "<p>Body</p>"}],
               "custom_fields" => %{
                 "version" => "1.2.0",
                 "released_on" => "2026-11-01",
                 "release_url" =>
                   "https://github.com/The-Verscienta/kiln_cms/releases/tag/v1.2.0",
                 "highlights" => "One.\nTwo."
               }
             }
    end

    test "every custom field it writes is one the type check requires" do
      written =
        %{title: "", html: "", version: "", date: "", release_url: "", highlights: ""}
        |> PublishReleases.entry_attrs()
        |> Map.fetch!("custom_fields")
        |> Map.keys()
        |> Enum.sort()

      assert written == PublishReleases.fields() |> Enum.map(& &1.name) |> Enum.sort()
    end
  end

  describe "check_type/2" do
    defp type_body(fields) do
      %{
        "data" => %{"id" => "type-id", "attributes" => %{"path_segment" => "releases"}},
        "included" =>
          for {name, type} <- fields do
            %{
              "type" => "field_definition",
              "attributes" => %{"name" => to_string(name), "field_type" => type}
            }
          end
      }
    end

    test "accepts a type with every field" do
      body =
        type_body(
          version: "string",
          released_on: "date",
          release_url: "url",
          highlights: "text",
          extra: "boolean"
        )

      assert PublishReleases.check_type(body, "release") ==
               {:ok, %{id: "type-id", path_segment: "releases"}}
    end

    test "names every missing or mistyped field" do
      body = type_body(version: "string", released_on: "string")
      assert {:error, message} = PublishReleases.check_type(body, "release")

      assert message =~ "`released_on` is a string field; make it date"
      assert message =~ "`release_url` is missing"
      assert message =~ "`highlights` is missing"
      refute message =~ "`version`"
    end
  end

  describe "against the repo's own notes" do
    test "the catalogue is every final release, newest first, without unreleased.md" do
      tags = Enum.map(PublishReleases.catalogue(), & &1.tag)

      assert "v1.0.0" in tags
      assert "v0.12.1" in tags
      refute Enum.any?(tags, &String.contains?(&1, "unreleased"))

      assert tags ==
               Enum.sort_by(
                 tags,
                 &String.trim_leading(&1, "v"),
                 &(Version.compare(&1, &2) == :gt)
               )
    end

    test "1.0.0 builds with its CHANGELOG.md date and highlights" do
      {:ok, parsed} = PublishReleases.parse_version("v1.0.0")
      assert {:ok, release} = PublishReleases.build(parsed)

      assert release.slug == "v1-0-0"
      assert release.date == "2026-10-02"
      assert release.source == "docs/changelog/v1.0.0.md"
      assert release.highlights =~ "1.0 is a major version"
      refute release.html =~ "full release notes"
    end

    test "a release without notes is an error, not an empty entry" do
      {:ok, parsed} = PublishReleases.parse_version("v9.9.9")
      assert {:error, message} = PublishReleases.build(parsed, date: "2030-01-01")
      assert message =~ "docs/changelog/v9.9.9.md"
    end

    test "the index lists each release under the type's path segment" do
      html =
        PublishReleases.index_html(
          [%{version: "1.0.0", slug: "v1-0-0", date: "2026-10-02"}],
          "releases"
        )

      assert html =~ ~s(<a href="/releases/v1-0-0">KilnCMS 1.0.0</a> — 2026-10-02)
    end
  end

  describe "the index page's newsletter sign-up" do
    @index [%{version: "1.0.0", slug: "v1-0-0", date: "2026-10-02"}]

    test "follows the list when the site has the block" do
      assert %{"title" => "Release notes", "block_tree" => [list, signup]} =
               PublishReleases.index_page(@index, "releases", true)

      assert list["_type"] == "rich_text"
      assert list["legacy_html"] =~ "/releases/v1-0-0"
      assert signup["_type"] == "newsletter_signup"
    end

    test "is left out when it doesn't, so the list still publishes" do
      assert %{"block_tree" => [%{"_type" => "rich_text"}]} =
               PublishReleases.index_page(@index, "releases", false)
    end

    # The publisher can't compile against the app, so nothing else ties the
    # map it sends to the block's real fields: a renamed field would be
    # silently dropped by the site.
    test "is a block the app reads back with its heading and intro" do
      %{"block_tree" => [_list, signup]} = PublishReleases.index_page(@index, "releases", true)

      assert [%KilnCMS.Blocks.NewsletterSignup{heading: heading, intro: intro}] =
               KilnCMS.CMS.TypedBlocks.to_typed([signup])

      assert heading == signup["heading"]
      assert intro == signup["intro"]
    end

    test "is supported exactly when the site's schema names the block" do
      assert PublishReleases.signup_supported?(%{
               "$defs" => %{"block_newsletter_signup" => %{}, "block_heading" => %{}}
             })

      refute PublishReleases.signup_supported?(%{"$defs" => %{"block_heading" => %{}}})
      refute PublishReleases.signup_supported?(%{"errors" => []})
    end
  end
end
