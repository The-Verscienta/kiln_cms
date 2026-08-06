defmodule KilnCMS.CMS.Validations.ComplianceClaims do
  @moduledoc """
  Blocks going live with an unreviewed `:error`-severity claim (#377).

  The hard half of claim checking. `KilnCMS.Compliance.Checks.Claims` advises
  in the editor and never prevents a save; this refuses the publish. Both read
  the same rules, so the panel an author has been looking at is the panel that
  decides.

  ## Off by default, twice

      config :kiln_cms, KilnCMS.Compliance,
        enabled: true,
        require_at_publish: true

  `enabled` has to be on for anything to have been scanned, and
  `require_at_publish` has to be on for a match to stop a publish. Neither is
  the default. A CMS that started refusing publishes on a phrase list nobody
  chose would be indefensible, and the rule pack is explicitly a starting
  point (see `KilnCMS.Compliance`).

  ## Only `:error` rules gate

  A rule's severity is the operator's statement of what it means. `:warning`
  and `:info` matches are advice and stay advice — of the shipped pack only
  the regulatory and safety rules are errors, because those are the two whose
  failure mode is a reader harmed or a regulator's line crossed rather than
  loose marketing copy.

  ## The scan covers what is published, not just the body

  The title, SEO title and SEO description are scanned alongside the block
  text. A claim in the meta description is the one that ships to a search
  results page, where it is read by more people than the article — gating the
  body alone would leave the widest-reach surface unchecked.

  ## `only_new?`, like the alt-text gate

  Passed by the edit gate (#722), where the question is not "does this document
  contain a claim" but "does this write *introduce* one". Without it, switching
  `require_at_publish` on would make every already-published page carrying a
  flagged phrase un-editable — an author fixing a typo would be refused until
  they also rewrote a sentence they did not touch. Diffed per rule code so
  adding a *new* category of claim to a document that already had one is still
  refused.
  """
  use Ash.Resource.Validation

  alias Kiln.Advisory.Body
  alias KilnCMS.Compliance

  @scanned_fields [:title, :seo_title, :seo_description]

  @impl true
  def validate(changeset, opts, _context) do
    if Compliance.require_at_publish?() and judgeable?(changeset) do
      check(changeset, opts[:only_new] == true)
    else
      :ok
    end
  end

  # The same locale test the panel applies (`KilnCMS.Compliance.judgeable?/1`).
  #
  # Without it the gate and the panel diverge in the worst possible direction:
  # a French page under the shipped English pack renders *no compliance panel
  # at all* — `Checks.Claims` reports `:n_a` — and is then refused at publish
  # quoting an English phrase the author was never shown. Custom rules are
  # assumed to fit the content they were written for, so those still run.
  defp judgeable?(changeset) do
    not Compliance.default_pack?() or Compliance.english_locale?(locale(changeset))
  end

  # `Kiln.Advisory.Context.new/3`'s fallback, exactly: a blank locale is the
  # instance default, not "unknown". Anything else and a record whose `locale`
  # is empty would silently skip the gate — a gate that turns itself off on
  # missing data is worse than no gate, because it reads as passing.
  defp locale(changeset) do
    case changeset |> Ash.Changeset.get_attribute(:locale) |> to_string() |> String.trim() do
      "" -> KilnCMS.I18n.default_locale()
      locale -> locale
    end
  end

  defp check(changeset, only_new?) do
    rules = Compliance.rules()

    new = offenders(changeset, :new, rules)
    existing = if only_new?, do: offenders(changeset, :existing, rules), else: %{}

    case diff(new, existing) do
      [] ->
        :ok

      offenders ->
        {:error, field: :state, message: message(offenders)}
    end
  end

  # `{code, phrase}` pairs rather than the map, so the diff is per phrase:
  # adding "100% safe" to a page that already said "no side effects" is a new
  # claim even though the rule code is unchanged.
  defp diff(new, existing) do
    existing_pairs = pairs(existing)

    new
    |> pairs()
    |> Enum.reject(&(&1 in existing_pairs))
    |> Enum.sort()
  end

  defp pairs(matches), do: for({code, phrases} <- matches, phrase <- phrases, do: {code, phrase})

  defp offenders(changeset, which, rules) do
    changeset
    |> segments(which)
    |> Enum.map(&(&1 |> Body.fold() |> Compliance.scan(rules)))
    |> Enum.reduce(%{}, &Compliance.merge/2)
    |> Compliance.errors_only(rules)
  end

  # Each field scanned on its own, never concatenated.
  #
  # Joining them first invents claims that are not in the document: a body
  # ending "use the sauna at your own risk" followed by a title "Free
  # consultation guide" produces the phrase "risk free" across the seam, and
  # the publish is refused for words that never appear together anywhere an
  # author can see. The editor scans in separate pieces (it has to — the body
  # is memoized and the fields are not), so a concatenating gate would also be
  # the one thing this is designed never to be: a gate that disagrees with the
  # panel.
  defp segments(changeset, which) do
    blocks = value(changeset, which, :blocks)

    fields =
      Enum.map(@scanned_fields, fn field ->
        case value(changeset, which, field) do
          text when is_binary(text) -> text
          _other -> ""
        end
      end)

    [Body.compute(blocks).text | fields]
  end

  defp value(changeset, :new, field), do: Ash.Changeset.get_attribute(changeset, field)
  defp value(changeset, :existing, field), do: Map.get(changeset.data, field)

  defp message(offenders) do
    quoted =
      offenders
      |> Enum.map(fn {_code, phrase} -> "\"#{phrase}\"" end)
      |> Enum.uniq()
      |> Enum.join(", ")

    # Names every offending phrase at once rather than making an author
    # rediscover the next one on each retry — the same reasoning as
    # `KilnCMS.CMS.Validations.MediaAltText`.
    "cannot go live: #{quoted} #{verb(offenders)} an unreviewed claim. " <>
      "Reword it, or have an admin clear the compliance rule."
  end

  defp verb([_one]), do: "is"
  defp verb(_many), do: "are"
end
