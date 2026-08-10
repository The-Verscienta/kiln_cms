defmodule KilnCMS.ComplianceTest do
  use ExUnit.Case, async: false

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context
  alias Kiln.Advisory.Registry
  alias KilnCMS.Compliance
  alias KilnCMS.Compliance.Checks.Claims
  alias KilnCMS.Compliance.Checks.Disclaimer
  alias KilnCMS.Compliance.Settings

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Compliance)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Compliance, original || []) end)
    :ok
  end

  defp configure(opts) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Compliance,
      Keyword.merge([enabled: true, rules: :default], opts)
    )
  end

  # The operator layer on its own — no database, which is what keeps this file a
  # unit test of the scanner and the checks. `KilnCMS.Compliance.SettingsTest`
  # covers the per-org row on top of it.
  defp settings, do: Settings.defaults()

  defp rules, do: settings().rules

  defp context(opts) do
    text = Keyword.get(opts, :text, "")
    matches = Keyword.get(opts, :matches, :scan)
    given = Keyword.get(opts, :settings, settings())
    scan_with = if given == :absent, do: settings(), else: given

    body = %Body{text: text, folded_text: Body.fold(text)}

    facts =
      case matches do
        :scan -> %{claim_matches: Compliance.scan(text, scan_with.rules)}
        :absent -> %{}
        other -> %{claim_matches: other}
      end

    # `settings: :absent` is the caller that resolved none at all — a check must
    # report `:n_a` there rather than inventing the deployment's answer.
    facts = if given == :absent, do: facts, else: Map.put(facts, :compliance_settings, given)

    Context.new(%{}, body, locale: Keyword.get(opts, :locale, "en"), facts: facts)
  end

  describe "scan/2 phrase matching" do
    setup do
      configure([])
    end

    test "matches a multi-word phrase and attributes it to its rule" do
      assert %{regulatory_claim: ["fda approved"]} =
               Compliance.scan("Our formula is FDA approved.", rules())
    end

    test "is case insensitive and matches hyphenated variants listed separately" do
      assert %{regulatory_claim: ["fda-approved"]} = Compliance.scan("FDA-APPROVED", rules())
    end

    test "matches across a line break or doubled spacing" do
      assert %{regulatory_claim: ["clinically proven"]} =
               Compliance.scan("It is clinically\n  proven to work.", rules())
    end

    # The bug this guards is the whole reason the phrases are word-bounded:
    # a naive substring scan for "cures" fires on "manicures", "procures" and
    # "secures", and a panel that flags the word "secures" on a security page
    # is one an author turns off within a day.
    test "does not match a phrase embedded inside a longer word" do
      configure(rules: [%{code: :curative, severity: :error, phrases: ["cures"]}])

      assert %{} == Compliance.scan("He secures manicures and procures things.", rules())
      assert %{curative: ["cures"]} = Compliance.scan("It cures nothing.", rules())
    end

    test "matches a phrase whose edge is not a word character" do
      assert %{safety_claim: ["100% safe"]} = Compliance.scan("It is 100% safe.", rules())
    end

    test "collects several rules from one pass, deduped" do
      matches = Compliance.scan("FDA approved, no side effects, and FDA approved again.", rules())

      assert matches[:regulatory_claim] == ["fda approved"]
      assert matches[:safety_claim] == ["no side effects"]
    end

    test "returns an empty map for clean text" do
      assert %{} == Compliance.scan("A calm article about herbal tea.", rules())
    end

    test "returns an empty map when no rule carries a usable phrase" do
      configure(rules: [%{code: :junk, severity: :error, phrases: ["", "  "]}])

      assert %{} == Compliance.scan("fda approved", rules())
    end

    test "does not raise on a malformed rule in the list" do
      rules = [
        %{code: :missing_phrases},
        :not_a_map,
        %{code: :good, severity: :error, phrases: ["fda approved"]}
      ]

      assert %{good: ["fda approved"]} = Compliance.scan("FDA approved.", rules)
    end
  end

  # Each of these was a real, silent failure of the single-combined-alternation
  # design this replaced. Two of the three let content past the publish gate.
  describe "scan/2 attribution (regressions)" do
    setup do
      configure([])
    end

    # PCRE caseless matching FOLDS; String.downcase/1 MAPS. They disagree on
    # ſ (U+017F) and on Greek final sigma, so attributing a match by looking
    # the downcased text back up in a phrase map dropped it entirely.
    test "a match whose case-folding downcase cannot reproduce is still reported" do
      matches = Compliance.scan("Our formula has no ſide effects and is FDA approved.", rules())

      assert Map.has_key?(matches, :safety_claim)
      assert Map.has_key?(matches, :regulatory_claim)
    end

    # Last-writer-wins on a shared phrase key silently demoted a shipped
    # :error phrase to the appended rule's severity — and the publish gate
    # stopped refusing it.
    test "a phrase shared by two rules reports under both, keeping the error" do
      rules =
        Compliance.default_rules() ++
          [%{code: :house_style, severity: :info, phrases: ["clinically proven"]}]

      matches = Compliance.scan("Our product is clinically proven.", rules)

      assert Map.has_key?(matches, :regulatory_claim)
      assert Map.has_key?(matches, :house_style)
      assert Map.has_key?(Compliance.errors_only(matches, rules), :regulatory_claim)
    end

    # One consuming alternation is scanned leftmost-first, so "always works"
    # swallowed the span "works for everyone…" and the overlapping :error rule
    # was never seen.
    test "an overlapping phrase from another rule is not swallowed" do
      rules =
        Compliance.default_rules() ++
          [%{code: :house_style, severity: :error, phrases: ["works for everyone in the family"]}]

      matches = Compliance.scan("It always works for everyone in the family.", rules)

      assert Map.has_key?(matches, :efficacy_claim)
      assert Map.has_key?(matches, :house_style)
      assert Map.has_key?(Compliance.errors_only(matches, rules), :house_style)
    end

    test "severity/2 tolerates a rule list with malformed entries" do
      assert Compliance.severity(:anything, [%{no_code: 1}, :junk]) == :warning
    end
  end

  # The operator layer, which is what a site with no row of its own inherits.
  # `KilnCMS.Compliance.SettingsTest` covers the row on top of it.
  describe "the operator configuration layer" do
    test "is off unless enabled" do
      Application.put_env(:kiln_cms, KilnCMS.Compliance, [])

      refute settings().enabled?
      refute settings().require_at_publish?
    end

    test "the publish gate stays off while claim checking itself is off" do
      Application.put_env(:kiln_cms, KilnCMS.Compliance,
        enabled: false,
        require_at_publish: true
      )

      refute settings().require_at_publish?
    end

    test "drops malformed rules rather than raising" do
      configure(
        rules: [
          %{code: :good, severity: :error, phrases: ["fda approved"]},
          %{code: :bad_severity, severity: :catastrophic, phrases: ["x"]},
          %{code: :no_phrases, severity: :error, phrases: []},
          :not_a_rule
        ]
      )

      assert [%{code: :good}] = rules()
    end

    test "a blank disclaimer reads as none configured" do
      configure(disclaimer: "   ")
      assert settings().disclaimer == nil

      configure(disclaimer: "Not medical advice.")
      assert settings().disclaimer == "Not medical advice."
    end

    test "recompiles when the configured rules change" do
      configure(rules: [%{code: :a, severity: :error, phrases: ["alpha"]}])
      assert %{a: ["alpha"]} = Compliance.scan("alpha beta", rules())

      configure(rules: [%{code: :b, severity: :error, phrases: ["beta"]}])
      assert %{b: ["beta"]} = Compliance.scan("alpha beta", rules())
    end

    # Two sites with different vocabularies alternating used to evict each
    # other from a single-entry cache, so every scan recompiled — and
    # `:persistent_term.put/2` is not a cheap write, it scans every process on
    # the node. Asserted on the cache itself: both rule sets scan correctly
    # either way, so only the retained entries show the thrash is gone.
    test "keeps compiled scanners for several rule sets at once" do
      alpha = [%{code: :a, severity: :error, phrases: ["alpha"]}]
      beta = [%{code: :b, severity: :error, phrases: ["beta"]}]

      assert %{a: ["alpha"]} = Compliance.scan("alpha beta", alpha)
      assert %{b: ["beta"]} = Compliance.scan("alpha beta", beta)

      cached = :persistent_term.get({Compliance, :scanners}, %{})

      assert Map.has_key?(cached, alpha)
      assert Map.has_key?(cached, beta)
    end
  end

  describe "severity and errors_only/2" do
    setup do
      configure([])
    end

    test "reads severity from the matching rule" do
      assert Compliance.severity(:regulatory_claim, rules()) == :error
      assert Compliance.severity(:efficacy_claim, rules()) == :warning
    end

    # A `matches` map computed under one configuration and judged under another
    # must not become an error by accident.
    test "an unknown code falls back to :warning, never :error" do
      assert Compliance.severity(:a_rule_nobody_configured, rules()) == :warning
    end

    test "keeps only error-severity rules" do
      matches = Compliance.scan("100% safe with guaranteed results", rules())

      assert Map.has_key?(matches, :safety_claim)
      assert Map.has_key?(matches, :efficacy_claim)

      errors = Compliance.errors_only(matches, rules())

      assert Map.has_key?(errors, :safety_claim)
      refute Map.has_key?(errors, :efficacy_claim)
    end
  end

  describe "merge/2" do
    test "unions phrases per code without duplicating" do
      left = %{regulatory_claim: ["fda approved"], safety_claim: ["100% safe"]}
      right = %{regulatory_claim: ["fda approved", "clinically proven"]}

      assert %{
               regulatory_claim: ["fda approved", "clinically proven"],
               safety_claim: ["100% safe"]
             } = Compliance.merge(left, right)
    end
  end

  describe "Checks.Claims" do
    setup do
      configure([])
    end

    test "reports one finding per matched rule, quoting the phrases" do
      findings = Claims.check(context(text: "FDA approved and 100% safe."))

      assert [%{code: :regulatory_claim, severity: :error, args: %{phrases: ["fda approved"]}}, _] =
               findings

      assert Enum.map(findings, & &1.code) == [:regulatory_claim, :safety_claim]
    end

    test "passes on clean text that was actually scanned" do
      assert :ok == Claims.check(context(text: "Herbal tea is pleasant."))
    end

    # The distinction the whole design turns on: nobody scanned it, so it is
    # not clean — it is unknown, and saying `:ok` would be a verdict nobody
    # computed.
    test "is :n_a when the caller computed no scan" do
      assert :n_a == Claims.check(context(text: "FDA approved.", matches: :absent))
    end

    test "is :n_a while claim checking is off" do
      configure(enabled: false)
      assert :n_a == Claims.check(context(text: "FDA approved."))
    end

    # Which rules apply is a property of the site (#857), so a caller that
    # resolved none has checked nothing — the same answer, for the same reason,
    # as a caller that computed no scan.
    test "is :n_a when the caller resolved no settings" do
      assert :n_a == Claims.check(context(text: "FDA approved.", settings: :absent))
    end

    test "is :n_a on a non-English document under the shipped English pack" do
      assert :n_a == Claims.check(context(text: "FDA approved.", locale: "fr"))
    end

    test "custom rules run in every locale" do
      configure(rules: [%{code: :custom, severity: :error, phrases: ["approuvé par la fda"]}])

      assert [%{code: :custom}] =
               Claims.check(context(text: "Approuvé par la FDA.", locale: "fr"))
    end

    test "takes the severity from the rule, not from the finding's category" do
      configure(rules: [%{code: :soft, severity: :info, phrases: ["fda approved"]}])

      assert [%{code: :soft, severity: :info}] = Claims.check(context(text: "FDA approved."))
    end

    test "reports into the compliance lens only" do
      assert Claims.lenses() == [:compliance]
      assert Disclaimer.lenses() == [:compliance]
    end
  end

  describe "Checks.Disclaimer" do
    test "is :n_a when no disclaimer is configured" do
      configure([])
      assert :n_a == Disclaimer.check(context(text: "Anything at all."))
    end

    test "is :n_a on an empty body rather than opening a new draft with an error" do
      configure(disclaimer: "Not medical advice.")
      assert :n_a == Disclaimer.check(context(text: "   "))
    end

    test "passes when the disclaimer appears inside longer prose" do
      configure(disclaimer: "Not medical advice.")

      assert :ok ==
               Disclaimer.check(
                 context(text: "Some article body. Not medical advice. Consult a clinician.")
               )
    end

    test "tolerates case and line wrapping, since the editor introduces both" do
      configure(disclaimer: "Not medical advice.")

      assert :ok == Disclaimer.check(context(text: "Body text. NOT MEDICAL\n  ADVICE. More."))
    end

    test "reports a body that does not carry it" do
      configure(disclaimer: "Not medical advice.")

      assert %{code: :disclaimer_missing, severity: :warning, args: %{disclaimer: text}} =
               Disclaimer.check(context(text: "An article with no disclaimer."))

      assert text == "Not medical advice."
    end

    test "is :n_a while claim checking is off, even with a disclaimer configured" do
      configure(enabled: false, disclaimer: "Not medical advice.")
      assert :n_a == Disclaimer.check(context(text: "An article."))
    end

    test "is :n_a when the caller resolved no settings" do
      configure(disclaimer: "Not medical advice.")

      assert :n_a ==
               Disclaimer.check(
                 context(text: "An article with no disclaimer.", settings: :absent)
               )
    end
  end

  describe "registry integration" do
    setup do
      configure([])
    end

    test "compliance findings do not leak into the SEO or accessibility panels" do
      outcomes = Registry.run(context(text: "FDA approved."), [Claims])

      assert [_finding] = outcomes |> Registry.by_lens(:compliance) |> Registry.findings()
      assert [] == outcomes |> Registry.by_lens(:seo) |> Registry.findings()
      assert [] == outcomes |> Registry.by_lens(:accessibility) |> Registry.findings()
    end

    # A check that predates lenses, or a plugin's that never considered them,
    # must not land in the compliance panel — that is the panel whose value
    # depends on not crying wolf.
    test "a check with the default lenses is absent from the compliance panel" do
      outcomes = Registry.run(context(text: "x"), [KilnCMS.Seo.Checks.Meta])

      assert [] == Registry.by_lens(outcomes, :compliance)
    end
  end
end
