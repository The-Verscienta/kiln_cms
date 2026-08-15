defmodule KilnCMS.CMS.SiteCompliance do
  @moduledoc """
  Per-org claim-checking settings (#857): whether this site runs the compliance
  panel, whether a flagged claim refuses a publish, the disclaimer it requires,
  and its own claim vocabulary.

  Claim checking shipped as `config :kiln_cms, KilnCMS.Compliance` and nothing
  else, which is the wrong grain for a shared install (#336). A claims
  vocabulary is a statement about one publication's voice and jurisdiction, and
  `require_at_publish` is a hard refusal — one tenant deciding that "cures"
  cannot ship applied that to every other site on the instance, and no tenant
  admin could opt out, because the switch lived in a file they cannot edit.
  This row is the per-org layer above that config; `KilnCMS.Compliance.Settings`
  resolves the two.

  One row per organization — the `KilnCMS.CMS.FeedSettings` shape: admin-only
  settings with no `paper_trail` history and no public read policy. The row is
  created lazily by `:save`, never by a read, so a site that never opens
  `/editor/compliance` costs nothing and inherits the operator's config exactly
  as it did before this existed.

  ## No row means "inherit"; a row means "this site said so"

  The columns are not individually nullable, and the page is what makes that
  work: `/editor/compliance` renders the **resolved** settings and writes every
  column on save, and "Use the operator defaults" destroys the row. So the
  inherit-vs-explicit distinction lives in the row's existence rather than in
  six nullable columns and a tri-state control for each — with one exception,
  `disclaimer`, where blank has to mean "inherit" because there is no third
  state a text box can express.

  `phrases` is the exception that proves the rule in the other direction: an
  empty list is a legitimate answer ("this site adds nothing to the shipped
  pack") and reads identically to never having said anything, because the
  shipped pack is controlled by `use_shared_rules` beside it.
  """
  # The shared one-row-per-org shape comes from `KilnCMS.CMS.OrgSettings`
  # (#1080). Editors read it: the editor's compliance panel is resolved from
  # this row on every keystroke, and it is read there as the signed-in author,
  # not as a system read. Nothing here is delivered to a visitor. Deciding what
  # this site may not say — and whether saying it refuses a publish — is an
  # admin act, the same call `SiteLinkCheck` makes.
  #
  # **A save writes every column.** AshPostgres narrows `upsert_fields` to the
  # attributes the changeset carries, which is what lets `FeedSettings` accept
  # a partial save — but every column here has a *default*, and a default is
  # applied on the create side of an upsert. So an attribute the caller
  # omitted arrives as its default and overwrites what was there.
  #
  # That is the honest shape for a settings row whose columns are all
  # non-null, and it is why `/editor/compliance` renders the resolved settings
  # into the form and submits the lot, including for its one-click "turn it
  # on". A caller sending `%{enabled: true}` alone would clear the site's
  # phrase list.
  use KilnCMS.CMS.OrgSettings,
    table: "site_compliance",
    accept: [
      :enabled,
      :require_at_publish,
      :disclaimer,
      :use_shared_rules,
      :phrases,
      :phrase_severity
    ],
    read: :editor,
    admin_columns: [:enabled, :require_at_publish, :phrases, :updated_at]

  # A ceiling on the site's own vocabulary. Every phrase compiles into one
  # alternation that is scanned over the whole document on every body change in
  # the editor, so this is the bound that keeps a settings row from making that
  # work unbounded. Comfortably above any real house style guide.
  @max_phrases 500

  @doc false
  @spec normalize_phrases(term()) :: [String.t()]
  def normalize_phrases(phrases) when is_list(phrases) do
    phrases
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_phrases(other), do: other

  changes do
    change KilnCMS.CMS.Changes.BustCompliance, on: [:create, :update, :destroy]

    # A blank line in the phrase textarea is not an error, it is a blank line.
    # Without this, Ash's string type trims `"   "` to `nil` and the save fails
    # with "no nil values" — a message naming a constraint no admin can see, on
    # a list they typed by hand. Deduped here too, so the list an admin gets
    # back is the list a scanner would build from it.
    change fn changeset, _context ->
             Ash.Changeset.update_change(changeset, :phrases, &__MODULE__.normalize_phrases/1)
           end,
           on: [:create, :update]
  end

  attributes do
    # Whether the panel and its checks run for this site at all.
    attribute :enabled, :boolean do
      default false
      allow_nil? false
      public? true
    end

    # Whether an `:error`-severity match refuses the publish
    # (`KilnCMS.CMS.Validations.ComplianceClaims`). Read *through* `enabled` by
    # `KilnCMS.Compliance.Settings`, exactly as the config pair always was:
    # there is nothing to have matched while checking is off, so this on its own
    # is inert rather than a gate with no vocabulary behind it.
    attribute :require_at_publish, :boolean do
      default false
      allow_nil? false
      public? true
    end

    # Text a body must contain verbatim. Blank is the *inherit* state here
    # rather than "no disclaimer required": a single-line text box has no third
    # value, and an operator-configured disclaimer that a site cleared by
    # tabbing through the form would be a compliance requirement dropped by
    # accident. A site that genuinely wants none turns the whole feature off, or
    # the operator clears it in config.
    attribute :disclaimer, :string do
      allow_nil? true
      public? true
      constraints max_length: KilnCMS.Limits.paragraph()
    end

    # Whether the rules this deployment configured — the shipped English pack
    # unless the operator replaced it — apply here too. A site with its own
    # vocabulary usually wants both; a site that finds the shipped pack wrong
    # for its subject matter needs to be able to say so without an operator.
    attribute :use_shared_rules, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # This site's own claim vocabulary — the `KilnCMS.CMS.FormSpamSettings`
    # shape, and the same kind of thing: a per-org phrase list an admin
    # maintains. They become one rule (`:site_claim`) at
    # `KilnCMS.Compliance.Settings.for_row/1`, carrying `phrase_severity`.
    #
    # One rule rather than one per phrase because a rule *code* is an atom the
    # web layer translates, and minting atoms from column values is how a
    # settings table becomes an unbounded atom table.
    # `allow_empty?`/`trim?` are relaxed on the *items* so a blank line reaches
    # `normalize_phrases/1` and is dropped there. Left at their defaults, Ash's
    # string type trims `"   "` to `nil` during casting — before any change runs
    # — and the save fails with "no nil values", which is a message naming a
    # constraint no admin can see, on a list they typed by hand.
    attribute :phrases, {:array, :string} do
      default []
      allow_nil? false
      public? true

      constraints max_length: @max_phrases,
                  items: [max_length: KilnCMS.Limits.line(), allow_empty?: true, trim?: false]
    end

    # What a match on this site's own phrases *means*. `:error` is the only
    # value that can refuse a publish, so this is the control that decides
    # whether the site's vocabulary is advice or a gate — deliberately separate
    # from `require_at_publish`, which decides whether *any* error gates.
    #
    # Defaults to `:warning`: a phrase list an admin has just typed has not been
    # tested against the site's own archive yet, and a first save that starts
    # refusing publishes is the version of this feature people switch off.
    attribute :phrase_severity, :atom do
      default :warning
      allow_nil? false
      public? true
      constraints one_of: [:error, :warning, :info]
    end
  end
end
