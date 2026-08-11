defmodule KilnCMS.Compliance do
  @moduledoc """
  Editorial **claim checking** — the compliance third of #377.

  A claim check reads authored text and flags the phrases a regulator, a
  clinic's counsel, or an editorial style guide would want a second look at
  before it is published: "FDA approved", "clinically proven", "no side
  effects". It is the compliance analogue of the SEO and accessibility panels,
  and it is built on the same machinery — see `Kiln.Advisory`.

  ## Why an advisory and not an agent

  #377 frames all three of its boxes as automation reactions: a background
  agent that inspects content and acts on it. For claim checking specifically,
  that shape is wrong twice over.

  A claim is a judgement about *meaning*, and the tool cannot make it. "This
  herb does not cure cancer" contains the phrase "cure cancer" and is a
  perfectly responsible sentence; "widely regarded as clinically proven" is a
  claim wearing a hedge. Every honest implementation of this surfaces the
  phrase and asks a human, and the human is already in the editor. Routing
  that through a background reaction adds latency and a notification and
  removes the one person who can answer.

  The second reason is the one recorded on #377 for metadata generation, and
  it applies here too: an automated writer or gate that fires on a state
  transition takes the human out of the loop on exactly the content where the
  human matters most.

  So this is an advisory check that runs live in the editor, plus an **opt-in
  hard gate at publish** for operators who want a claim to be un-shippable
  rather than merely flagged. Both are off by default.

  ## Configuration is per site, over a deployment default (#857)

  This module owns the **rule pack and the scanner**. What a given site has
  switched on lives in `KilnCMS.Compliance.Settings`, which resolves the site's
  `KilnCMS.CMS.SiteCompliance` row over the deployment-wide config:

      config :kiln_cms, KilnCMS.Compliance,
        enabled: true,
        require_at_publish: false,
        disclaimer: "This information is not medical advice.",
        rules: :default

  * `enabled` — whether the panel and its checks run at all. **Off by
    default**: a general-purpose CMS has no business grading a marketing page
    against a health-claims vocabulary until someone asks it to.
  * `require_at_publish` — whether an `:error`-severity match *blocks* going
    live. See `KilnCMS.CMS.Validations.ComplianceClaims`. Off by default.
  * `disclaimer` — text that must appear in the body, or `nil` for no such
    requirement. See `KilnCMS.Compliance.Checks.Disclaimer`.
  * `rules` — `:default` for the shipped pack, or a list of custom rules.

  Nothing here reads that config directly, and nothing outside `Settings`
  should: on a multi-org install (#336) the answer to "is claim checking on"
  is a question about *which site*, and a zero-arity reader is a function that
  cannot ask it. Every entry point takes a resolved `t:Settings.t/0`.

  ## Rules

  A rule is a map:

      %{code: :regulatory_claim, severity: :error, phrases: ["fda approved"]}

  `code` names it (and is what the web layer translates), `severity` is the
  usual `:error | :warning | :info`, and `phrases` are matched
  **case-insensitively, on whole-word boundaries**.

  Word boundaries are not a nicety. `"cures"` as a substring matches
  *manicures*, *procures* and *secures*; a compliance panel that flags the
  word "secures" on a page about data security is one an author switches off
  within a day, and it then catches nothing.

  ## The default pack is deliberately narrow

  `default_rules/0` ships only phrases that are a claim in *essentially any
  context*: regulatory assertions ("FDA approved", "clinically proven"),
  safety absolutes ("no side effects", "100% safe") and efficacy absolutes
  ("guaranteed results", "never fails").

  What it pointedly does **not** ship is curative vocabulary — bare "cures",
  "heals", "treats". Those are the phrases a health CMS most obviously wants,
  and they are also the ones with the most legitimate uses: "this herb cures
  nothing", "traditionally used to treat insomnia", an article *about* cure
  claims. Where the editorial line falls is a question about a specific
  publication's voice and jurisdiction, and only its operator can answer it.
  Shipping a guess would mean every install starts by turning the panel off.

  Add your own — the whole pack is replaceable:

      config :kiln_cms, KilnCMS.Compliance,
        rules: KilnCMS.Compliance.default_rules() ++ [
          %{code: :curative_claim, severity: :error, phrases: ["cures", "heals"]}
        ]

  ## Negation is not handled, on purpose

  "Does not cure cancer" matches a `cure cancer` phrase, and this reports it.
  A negation window ("skip a match preceded by *not* within three words")
  would suppress that one and just as readily suppress "not only clinically
  proven, but…", which is a claim.

  Between a false positive an author dismisses in a second and a false
  negative that ships an unreviewed claim, a compliance tool should choose the
  first. The panel's job is to say *look at this*, not to render a verdict —
  which is also why the shipped severities lean on `:warning`, and why the
  publish gate is opt-in.

  ## English only, for the default pack

  The shipped phrases are English, so `KilnCMS.Compliance.Checks.Claims`
  reports `:n_a` on a non-English document rather than passing it — a document
  nobody checked is not a document that is clean. **Custom** rules run in every
  locale, since an operator (or an admin typing a site's own phrase list) who
  wrote French phrases meant them to fire.
  """

  @type rule :: %{
          required(:code) => atom(),
          required(:severity) => Kiln.Advisory.Finding.severity(),
          required(:phrases) => [String.t()]
        }

  @typedoc "Rule code to the phrases that matched, in document order, deduped."
  @type matches :: %{atom() => [String.t()]}

  @cache_key {__MODULE__, :scanners}

  # How many distinct rule sets keep their compiled scanners before the cache is
  # dropped and rebuilt. Sized for "every site on this node, plus a few edits in
  # flight", not for a global registry of every rule set ever seen.
  @max_cached_scanners 32

  @doc """
  Resolve a configured `rules` value — `:default` for the shipped pack, or a
  list — into a rule list, dropping junk entries.

  A malformed rule map is dropped here rather than left to raise from inside a
  check, where `Kiln.Advisory.Registry` catches it and the only visible effect
  is an advisory that silently stopped appearing.
  """
  @spec rules_from(:default | [rule()] | term()) :: [rule()]
  def rules_from(:default), do: default_rules()
  def rules_from(list) when is_list(list), do: Enum.filter(list, &valid_rule?/1)
  def rules_from(_other), do: default_rules()

  @doc """
  Whether `locale` is one the shipped English pack can judge.

  Exists so the publish gate, which has a changeset rather than a
  `Kiln.Advisory.Context`, applies the *same* test as the panel. A gate that
  refused a French page quoting an English phrase the panel never showed is
  the one divergence this feature must not have.
  """
  @spec english_locale?(String.t()) :: boolean()
  def english_locale?(locale) when is_binary(locale), do: String.starts_with?(locale, "en")

  @doc """
  The shipped rule pack. Narrow on purpose — see the moduledoc.
  """
  @spec default_rules() :: [rule()]
  def default_rules do
    [
      # Assertions about a regulator's or a profession's endorsement. These are
      # claims about a *fact of record*: either the approval exists and can be
      # cited, or the sentence is inventing one.
      %{
        code: :regulatory_claim,
        severity: :error,
        phrases: [
          "fda approved",
          "fda-approved",
          "approved by the fda",
          "clinically proven",
          "medically proven",
          "scientifically proven",
          "doctor recommended",
          "doctor-recommended",
          "physician recommended",
          "physician-recommended",
          "medically endorsed"
        ]
      },
      # Absolutes about safety. Unfalsifiable as written, and the category
      # where being wrong hurts a reader rather than a brand.
      %{
        code: :safety_claim,
        severity: :error,
        phrases: [
          "no side effects",
          "without side effects",
          "completely safe",
          "totally safe",
          "100% safe",
          "perfectly safe",
          "risk free",
          "risk-free",
          "safe for everyone"
        ]
      },
      # Absolutes about efficacy. A warning rather than an error: these are
      # more often loose marketing copy than a regulated claim, and an error
      # would put an ordinary landing page in front of the publish gate.
      %{
        code: :efficacy_claim,
        severity: :warning,
        phrases: [
          "guaranteed results",
          "guaranteed to work",
          "guaranteed cure",
          "miracle cure",
          "always works",
          "never fails",
          "works for everyone",
          "instant results"
        ]
      },
      # Text that positions the content as a substitute for care. The failure
      # mode here is a reader acting on an article instead of seeing someone.
      %{
        code: :medical_advice_claim,
        severity: :warning,
        phrases: [
          "replaces your doctor",
          "no need to see a doctor",
          "instead of seeing a doctor",
          "skip the doctor",
          "self-diagnose"
        ]
      }
    ]
  end

  @doc """
  Scan `text` for every configured phrase, in one pass.

  Returns `t:matches/0` — rule code to the distinct phrases that matched, in
  the order they first appear. An empty map means nothing matched.

  ## One regex per rule, not one for all of them

  Each rule compiles to its own alternation and gets its own pass. A single
  combined alternation would be one pass instead of four, and it was the first
  design here — but it attributes a match by looking the matched text back up
  in a phrase-to-rule map, and that lookup is wrong in three ways that all fail
  *silently*:

    * **Case folding.** PCRE's caseless matching folds; `String.downcase/1`
      maps. They disagree — `ſ` (U+017F) folds to `s` for the regex but stays
      `ſ` under downcase, so "no ſide effects" matches and is then dropped on
      lookup. Greek final sigma does the same, which reaches any legitimate
      Greek rule pack.
    * **Duplicate phrases.** Two rules naming the same phrase collapse to one
      map entry, last writer winning — so an operator appending an `:info`
      house-style rule that repeats a shipped phrase silently demotes it out
      of the publish gate.
    * **Overlap.** One alternation is scanned leftmost-first and consumes what
      it matches, so a phrase whose span overlaps an earlier match is never
      seen. "always works" (`:warning`) swallows "works for everyone"
      (`:error`), and the gate stops refusing.

  Per rule, attribution is by construction: the rule that matched is the rule
  that was scanned, no lookup and nothing to disagree with. Overlap *between*
  rules disappears with it. Overlap *within* one rule remains — two phrases of
  the same rule sharing a span report once — which is harmless, since they
  carry the same code and severity either way.

  The cost is one pass per rule (four, with the shipped pack) rather than one.
  Advisory checks re-run on **every keystroke** in the content editor, so this
  is not called from a check regardless — the caller scans when the body
  changes and hands the result in as a `Kiln.Advisory.Context` fact. See
  `KilnCMS.Compliance.Checks.Claims`.

  The rules are always passed in, never read from config here: on a
  multi-org install they belong to *a site* (#857), and a scanner that resolved
  them itself would scan one tenant's document against another's vocabulary.
  """
  @spec scan(String.t(), [rule()]) :: matches()
  def scan(text, rules) when is_binary(text) and is_list(rules) do
    rules
    |> scanner()
    |> Enum.reduce(%{}, fn {code, regex}, acc -> attribute(text, code, regex, acc) end)
  end

  def scan(_text, _rules), do: %{}

  # The matched TEXT is what gets reported, normalized for display — never
  # looked up. A phrase that matched under a fold the caller cannot reproduce
  # still names itself correctly, and nothing is ever dropped for failing a
  # lookup.
  #
  # `Enum.uniq/1` after the scan keeps document order: the panel quotes these,
  # and quoting them in an arbitrary order reads as arbitrary.
  defp attribute(text, code, regex, acc) do
    regex
    |> Regex.scan(text, capture: :first)
    |> Enum.map(fn [match] -> normalize_phrase(match) end)
    |> Enum.uniq()
    |> case do
      [] -> acc
      phrases -> Map.update(acc, code, phrases, &Enum.uniq(&1 ++ phrases))
    end
  end

  @doc """
  Combine two `t:matches/0` maps.

  The content editor scans in two pieces on two schedules — the body when it
  changes, the short scalar fields on every keystroke — and the check must see
  one map, because a phrase that appears in both the body and the SEO
  description is one finding, not two.
  """
  @spec merge(matches(), matches()) :: matches()
  def merge(left, right) when is_map(left) and is_map(right),
    do: Map.merge(left, right, fn _code, a, b -> Enum.uniq(a ++ b) end)

  @doc """
  The severity `code` carries in `rules`, or `:warning` for a code with no rule.

  The fallback matters for the publish gate: a `matches` map computed under one
  site's rules and judged under another's must not silently become an `:error`.
  """
  @spec severity(atom(), [rule()]) :: Kiln.Advisory.Finding.severity()
  def severity(code, rules) when is_list(rules) do
    # `match?` rather than `&1.code == code`: this is public and documented for
    # callers holding their own rule list, and a map with no `:code` key must
    # not raise here — a raise inside a check becomes a silently missing
    # advisory once the registry catches it.
    case Enum.find(rules, &match?(%{code: ^code, severity: _}, &1)) do
      %{severity: severity} when severity in [:error, :warning, :info] -> severity
      _other -> :warning
    end
  end

  @doc """
  Only the matches whose rule is `:error` severity — what the publish gate acts on.
  """
  @spec errors_only(matches(), [rule()]) :: matches()
  def errors_only(matches, rules) when is_list(rules) do
    matches
    |> Enum.filter(fn {code, _phrases} -> severity(code, rules) == :error end)
    |> Map.new()
  end

  # Compiling the alternations is not free, so the compiled form is cached in
  # `:persistent_term` under the rules that produced it. Rules are runtime data
  # — config is settable at runtime, and since #857 a site's own phrases are a
  # database row — so the cache is keyed on the rule list itself and never on a
  # generation counter it would have to be told to bump.
  #
  # A **map** of rule-set to scanners rather than the single entry this started
  # as: with per-org rules, two sites with different vocabularies alternating
  # made every call a miss, and `:persistent_term.put/2` is not a cheap write —
  # it scans every process for references to the old term. One tenant's
  # keystrokes would have paid for the other's.
  #
  # Bounded by dropping the whole map at `@max_cached_scanners`: entries are
  # never invalidated (a rule set that no longer exists is simply never looked
  # up again), so without a ceiling a long-lived node that has seen many edits
  # of many sites' phrase lists accumulates compiled regexes forever. Resetting
  # wholesale rather than evicting one costs a recompile for the sites still
  # active and needs no recency bookkeeping in a term that is expensive to
  # write.
  #
  # Returns `[{code, regex}]` in rule order.
  defp scanner(rules) do
    cache = :persistent_term.get(@cache_key, %{})

    case Map.fetch(cache, rules) do
      {:ok, scanners} ->
        scanners

      :error ->
        scanners = compile(rules)
        base = if map_size(cache) >= @max_cached_scanners, do: %{}, else: cache
        :persistent_term.put(@cache_key, Map.put(base, rules, scanners))
        scanners
    end
  end

  # `valid_rule?/1` again rather than trusting the caller: `scan/2` and
  # `severity/2` are public and documented for the publish gate and for tests,
  # so a rule map missing `:phrases` would otherwise be a `KeyError` from
  # inside a check — which the registry swallows into a silently absent
  # advisory.
  defp compile(rules) do
    for rule <- rules, valid_rule?(rule) do
      phrases =
        rule.phrases
        |> Enum.map(&normalize_phrase/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      {rule.code, build_regex(phrases)}
    end
  end

  # Longest first, so an alternation prefers "fda approved" over a shorter
  # phrase of the SAME rule that happens to be its prefix — PCRE alternation is
  # first-match, not longest-match, so the shorter branch would otherwise win
  # and the panel would quote the truncated phrase back at the author.
  defp build_regex(phrases) do
    alternation =
      phrases
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.map_join("|", &escape/1)

    # `\b` on each end rather than around the whole alternation: a phrase may
    # begin or end with a non-word character ("100% safe"), where `\b` would
    # assert the opposite of what is wanted. Anchoring per phrase inside
    # `escape/1` is not possible either, since the phrase is one branch — so
    # the boundary is applied conditionally by looking at the phrase's own
    # edges.
    Regex.compile!("(?:#{alternation})", "iu")
  end

  # Word boundaries per phrase edge: `\b` only where the phrase's own edge is a
  # word character. "100% safe" ends in a word character but starts with a
  # digit — `\b` before "1" is correct — while a phrase starting with "%" would
  # need `\B`, so the assertion is simply omitted where it cannot help.
  defp escape(phrase) do
    # Word-by-word, joined with `\s+`, so a phrase stays matchable when the
    # authored text wrapped it across a line or double-spaced it.
    #
    # Split BEFORE escaping, never after: `Regex.escape/1` escapes a space to
    # `\ `, so substituting `\s+` for " " in the escaped string lands on the
    # space of that pair and leaves a stray backslash — every multi-word phrase
    # then compiles to something that matches nothing, silently.
    escaped =
      phrase
      |> String.split(" ", trim: true)
      |> Enum.map_join("\\s+", &Regex.escape/1)

    leading = if word_char?(String.first(phrase)), do: "\\b", else: ""
    trailing = if word_char?(String.last(phrase)), do: "\\b", else: ""

    leading <> escaped <> trailing
  end

  defp word_char?(nil), do: false
  defp word_char?(char), do: Regex.match?(~r/[\p{L}\p{N}_]/u, char)

  # Phrases are matched against text that may use any spacing; collapsing runs
  # of whitespace to one space keeps a two-word phrase matchable when the
  # authored text wrapped it across a line.
  defp normalize_phrase(phrase) when is_binary(phrase) do
    phrase
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end

  defp normalize_phrase(_phrase), do: ""

  defp valid_rule?(%{code: code, severity: severity, phrases: phrases})
       when is_atom(code) and is_list(phrases) and severity in [:error, :warning, :info],
       do: Enum.any?(phrases, &(normalize_phrase(&1) != ""))

  defp valid_rule?(_rule), do: false
end
