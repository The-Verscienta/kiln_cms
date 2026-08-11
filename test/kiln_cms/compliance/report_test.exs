defmodule KilnCMS.Compliance.ReportTest do
  @moduledoc """
  "What claims are live on this site right now" (#858) — the question #377's
  editor panel and publish gate both cannot answer, because both are about the
  document in front of you rather than the site.

  The properties that matter here are the ones that separate a *report* from a
  second scanner: it looks at what is published rather than what is being
  edited, it judges by the rules in force now, and it never invents a claim by
  running fields together.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Compliance.Report

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Compliance)

    org = KilnCMS.Accounts.default_org_id()
    configure(enabled: true, rules: :default)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Compliance, original || [])
      KilnCMS.Cache.bust_compliance(org)
    end)

    %{admin: admin(), org: org}
  end

  # `Settings.for_org/1` is cached per org, so writing application env is not
  # enough on its own — a config change that leaves the cache warm is a test
  # asserting against the previous configuration.
  defp configure(opts) do
    Application.put_env(:kiln_cms, KilnCMS.Compliance, opts)
    KilnCMS.Cache.bust_compliance(KilnCMS.Accounts.default_org_id())
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "claims-#{System.unique_integer([:positive])}"

  defp page(admin, attrs) do
    Map.merge(%{title: "Untitled", slug: slug()}, attrs)
    |> CMS.create_page!(actor: admin)
  end

  defp published(admin, attrs) do
    admin |> page(attrs) |> CMS.publish_page!(%{}, actor: admin)
  end

  defp titles(report), do: Enum.map(report.findings, & &1.title)

  test "a published claim is reported, with the phrase that matched", %{admin: admin, org: org} do
    published(admin, %{title: "Our clinically proven method"})

    assert %{enabled?: true, findings: [finding]} = Report.for_org(org)
    assert finding.title == "Our clinically proven method"
    assert finding.type == "page"
    assert finding.errors?
    assert finding.matches[:regulatory_claim] == ["clinically proven"]
  end

  test "a draft making the same claim is not", %{admin: admin, org: org} do
    # Not an optimisation. A draft's claims are the editor panel's business and
    # the publish gate's, both of which already run; this page answers what the
    # site is *saying*, and a draft says nothing to anyone.
    page(admin, %{title: "Our clinically proven method"})

    assert %{findings: []} = Report.for_org(org)
  end

  test "a clean published page is scanned and reported as clean", %{admin: admin, org: org} do
    # `scanned` is what separates "no claims" from "nobody looked" — the same
    # distinction `KilnCMS.Links.Report` draws, and for the same reason.
    published(admin, %{title: "An ordinary page"})

    assert %{enabled?: true, scanned: scanned, findings: []} = Report.for_org(org)
    assert scanned >= 1
  end

  test "no claim is invented across a field boundary", %{admin: admin, org: org} do
    # The seam `ComplianceClaims` documents: a title ending in one word and a
    # description starting with the next must not produce the phrase between
    # them. Concatenating first is the obvious implementation and it reports a
    # claim the document does not make.
    published(admin, %{
      title: "Use the sauna at your own risk",
      seo_description: "Free consultation guide"
    })

    assert %{findings: []} = Report.for_org(org)
  end

  test "the switch being off is a state, not an empty report", %{admin: admin, org: org} do
    published(admin, %{title: "Our clinically proven method"})
    configure(enabled: false, rules: :default)

    # `enabled?: false` rather than `findings: []`, so the page can say nobody
    # looked instead of drawing a clean bill of health from a scan that never ran.
    assert %{enabled?: false, scanned: 0, findings: []} = Report.for_org(org)
  end

  test "findings are judged by the rules in force now", %{admin: admin, org: org} do
    # The consequence of recomputing rather than storing, asserted rather than
    # left to the moduledoc: narrowing the site's vocabulary retires the finding
    # instead of leaving a record judged by a rule nobody uses any more.
    published(admin, %{title: "Our clinically proven method"})
    assert [_one] = Report.for_org(org).findings

    configure(
      enabled: true,
      rules: [%{code: :other_claim, severity: :error, phrases: ["something else entirely"]}]
    )

    assert %{findings: []} = Report.for_org(org)
  end

  test "errors sort ahead of warnings", %{admin: admin, org: org} do
    # The page should open on the rows that would refuse a publish.
    configure(
      enabled: true,
      rules: [
        %{code: :hard, severity: :error, phrases: ["clinically proven"]},
        %{code: :soft, severity: :warning, phrases: ["best in class"]}
      ]
    )

    published(admin, %{title: "Zebra best in class"})
    published(admin, %{title: "Aardvark clinically proven"})

    report = Report.for_org(org)

    # Alphabetically the warning comes first, so an ordering that ignored
    # severity would put it there.
    assert titles(report) == ["Aardvark clinically proven", "Zebra best in class"]
    assert [%{errors?: true}, %{errors?: false}] = report.findings
  end
end
