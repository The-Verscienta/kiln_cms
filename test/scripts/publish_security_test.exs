Code.require_file("../../scripts/publish/security.exs", __DIR__)

defmodule KilnCMS.Scripts.PublishSecurityTest do
  @moduledoc """
  `scripts/publish_security.exs` publishes the disclosure policy and a
  security notice per GitHub advisory to kilncms.dev (#1873). It runs in CI
  without the application compiled, so its logic lives in
  `scripts/publish/security.exs` and is loaded here directly: the advisory
  reading and the payload building, none of which needs a site or the
  network.
  """
  use ExUnit.Case, async: true

  # The shape `GET /repos/:repo/security-advisories` returns, trimmed to what
  # the script reads (GitHub's description comes with CRLF line ends).
  @advisory %{
    "ghsa_id" => "GHSA-6983-jfq8-485w",
    "cve_id" => "CVE-2026-56811",
    "html_url" =>
      "https://github.com/The-Verscienta/kiln_cms/security/advisories/GHSA-6983-jfq8-485w",
    "summary" => "  Preview tokens\nleak across tenants ",
    "description" =>
      "### Impact\r\n\r\nA <script>alert(1)</script> preview token [leaks](docs/threat-model.md).\r\n",
    "severity" => "high",
    "state" => "published",
    "published_at" => "2026-10-20T13:03:19Z",
    "withdrawn_at" => nil,
    "vulnerabilities" => [
      %{
        "package" => %{"ecosystem" => "erlang", "name" => "kiln_cms"},
        "vulnerable_version_range" => ">= 1.3.0, < 1.3.2",
        "patched_versions" => "1.3.2"
      },
      %{
        "package" => %{"ecosystem" => "erlang", "name" => "kiln_cms"},
        "vulnerable_version_range" => ">= 1.2.0, < 1.2.4",
        "patched_versions" => "1.2.4"
      }
    ]
  }

  describe "notice/1" do
    test "reads an advisory into a notice" do
      assert {:ok, notice} = PublishSecurity.notice(@advisory)

      assert notice.slug == "ghsa-6983-jfq8-485w"
      assert notice.advisory_id == "GHSA-6983-jfq8-485w"
      assert notice.cve_id == "CVE-2026-56811"
      assert notice.title == "Preview tokens leak across tenants"
      assert notice.severity == "high"
      assert notice.package == "kiln_cms"
      assert notice.affected_versions == ">= 1.3.0, < 1.3.2; >= 1.2.0, < 1.2.4"
      assert notice.patched_versions == "1.3.2; 1.2.4"
      assert notice.published_on == "2026-10-20"
      assert notice.advisory_url == @advisory["html_url"]
    end

    test "renders the description with inline markup as text, links resolved against the repo" do
      {:ok, notice} = PublishSecurity.notice(@advisory)

      assert notice.html ==
               "<h3>Impact</h3><p>A &lt;script&gt;alert(1)&lt;/script&gt; preview token " <>
                 ~s(<a href="https://github.com/The-Verscienta/kiln_cms/blob/main/docs/threat-model.md">leaks</a>.</p>)
    end

    test "a withdrawn advisory is not published" do
      assert PublishSecurity.notice(%{@advisory | "withdrawn_at" => "2026-10-21T00:00:00Z"}) ==
               :withdrawn
    end

    test "an advisory naming no package is the core's; no CVE is nil" do
      advisory = %{@advisory | "vulnerabilities" => [], "cve_id" => nil}
      assert {:ok, notice} = PublishSecurity.notice(advisory)

      assert notice.package == "kiln_cms"
      assert notice.affected_versions == "unknown"
      assert notice.patched_versions == "unknown"
      assert notice.cve_id == nil
    end

    test "severity is the repository API's vocabulary; anything else is unknown" do
      for {given, expected} <- [
            {"critical", "critical"},
            {"medium", "medium"},
            {"moderate", "medium"},
            {nil, "unknown"},
            {"severe", "unknown"}
          ] do
        assert {:ok, %{severity: ^expected}} =
                 PublishSecurity.notice(%{@advisory | "severity" => given})
      end
    end

    test "an empty summary falls back to the advisory id" do
      assert {:ok, %{title: "GHSA-6983-jfq8-485w"}} =
               PublishSecurity.notice(%{@advisory | "summary" => " "})
    end

    test "an advisory it cannot date is an error, not a notice dated today" do
      assert {:error, message} = PublishSecurity.notice(%{@advisory | "published_at" => nil})
      assert message =~ "GHSA-6983-jfq8-485w"
    end
  end

  describe "entry_attrs/1" do
    test "the shape a notice is written in" do
      {:ok, notice} = PublishSecurity.notice(@advisory)

      assert %{
               "title" => "Preview tokens leak across tenants",
               "block_tree" => [%{"_type" => "rich_text", "legacy_html" => html}],
               "custom_fields" => %{
                 "package" => "kiln_cms",
                 "affected_versions" => ">= 1.3.0, < 1.3.2; >= 1.2.0, < 1.2.4",
                 "patched_versions" => "1.3.2; 1.2.4",
                 "severity" => "high",
                 "advisory_id" => "GHSA-6983-jfq8-485w",
                 "cve_id" => "CVE-2026-56811",
                 "published_on" => "2026-10-20",
                 "advisory_url" => _
               }
             } = PublishSecurity.entry_attrs(notice)

      assert html == notice.html
    end

    # `custom_fields` merges per key: writing "" would wipe a CVE an editor
    # added on the site, and a CVE assigned later fills in on the next run.
    test "leaves cve_id out when the advisory has none" do
      {:ok, notice} = PublishSecurity.notice(%{@advisory | "cve_id" => ""})
      refute Map.has_key?(PublishSecurity.entry_attrs(notice)["custom_fields"], "cve_id")
    end

    test "every custom field it writes is one the type check requires" do
      {:ok, notice} = PublishSecurity.notice(@advisory)

      written =
        notice |> PublishSecurity.entry_attrs() |> Map.fetch!("custom_fields") |> Map.keys()

      assert Enum.sort(written) == PublishSecurity.fields() |> Enum.map(& &1.name) |> Enum.sort()
    end
  end

  describe "the /security page" do
    test "is SECURITY.md without its H1, with relative links on GitHub's main" do
      html = PublishSecurity.render_policy(File.read!(".github/SECURITY.md"))

      refute html =~ "<h1>"
      refute html =~ "This policy is also published at"
      assert html =~ "<h2>Security notices</h2>"
      assert html =~ "<h2>Reporting a vulnerability</h2>"
      assert html =~ "<h2>Supported versions</h2>"

      assert html =~
               ~s(href="https://github.com/The-Verscienta/kiln_cms/blob/main/docs/threat-model.md")

      refute html =~ ~s(href="../)
    end

    test "lists notices newest first, escaped, under the type's segment, with the feed" do
      notices =
        PublishSecurity.sort_notices([
          %{
            slug: "ghsa-old",
            advisory_id: "GHSA-old",
            title: "Old",
            package: "kiln_cms",
            severity: "low",
            published_on: "2026-01-01"
          },
          %{
            slug: "ghsa-new",
            advisory_id: "GHSA-new",
            title: "<b>New</b>",
            package: "kiln_seo",
            severity: "high",
            published_on: "2026-10-01"
          }
        ])

      html = PublishSecurity.notices_html(notices, "security-notices")

      assert html =~ ~s(<a href="/security-notices/feed.xml">)
      assert html =~ ~s(<a href="/security-notices/feed.json">)

      assert html =~
               ~s(<li><a href="/security-notices/ghsa-new">&lt;b&gt;New&lt;/b&gt;</a> — kiln_seo, high, 2026-10-01</li>) <>
                 ~s(<li><a href="/security-notices/ghsa-old">Old</a>)
    end

    test "says so when there are none" do
      assert PublishSecurity.notices_html([], "security-notices") =~
               "No security notices have been published."
    end

    test "page_attrs/3 is the policy then the notices, in one rich_text block" do
      attrs = PublishSecurity.page_attrs("<p>policy</p>", [], "security-notices")

      assert attrs["title"] == "Security"
      assert is_binary(attrs["seo_description"])

      assert [
               %{
                 "_type" => "rich_text",
                 "legacy_html" => "<p>policy</p><h2>All security notices</h2>" <> _
               }
             ] =
               attrs["block_tree"]
    end
  end

  describe "check_type/2" do
    defp type_body(fields, feed? \\ true) do
      %{
        "data" => %{
          "id" => "type-id",
          "attributes" => %{"path_segment" => "security-notices", "has_published_feed" => feed?}
        },
        "included" =>
          for {name, type} <- fields do
            %{
              "type" => "field_definition",
              "attributes" => %{"name" => to_string(name), "field_type" => type}
            }
          end
      }
    end

    @all_fields [
      package: "string",
      affected_versions: "string",
      patched_versions: "string",
      severity: "string",
      advisory_id: "string",
      cve_id: "string",
      published_on: "date",
      advisory_url: "url"
    ]

    test "accepts a type with every field, and reports whether it has a feed" do
      assert PublishSecurity.check_type(type_body(@all_fields), "security_notice") ==
               {:ok, %{id: "type-id", path_segment: "security-notices", feed?: true}}

      assert {:ok, %{feed?: false}} =
               PublishSecurity.check_type(type_body(@all_fields, false), "security_notice")
    end

    test "names every missing or mistyped field" do
      body =
        type_body(Keyword.drop(@all_fields, [:cve_id]) |> Keyword.put(:published_on, "string"))

      assert {:error, message} = PublishSecurity.check_type(body, "security_notice")

      assert message =~ "`published_on` is a string field; make it date"
      assert message =~ "`cve_id` is missing"
      refute message =~ "`package`"
    end
  end
end
