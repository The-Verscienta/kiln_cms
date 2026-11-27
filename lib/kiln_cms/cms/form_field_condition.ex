defmodule KilnCMS.CMS.FormFieldCondition do
  @moduledoc """
  When a `KilnCMS.CMS.FormField` is shown (#2262), embedded in its
  `condition` (one jsonb column on the field's own row, D3).

    * `action` — `:show` (the field is shown while `rule` holds) or `:hide`
      (it is hidden while `rule` holds);
    * `rule` — a rule in the `KilnCMS.CMS.Conditions` shape, the one custom
      fields use (#2277), naming earlier fields of the same form by `name`.
      Stored normalized: string keys and string operators throughout.

  A field hidden by its condition is not required, and whatever value was
  sent for it is dropped: `KilnCMS.Forms.Logic` decides, in form order, and
  `KilnCMS.Forms.submit/3` enforces it.

  Not `visible_when` as on a `FieldDefinition`: the rule engine has no `not`,
  so a hide rule stored as a negated show rule could not be read back by the
  builder as the rule the admin wrote. The action keeps the intent.

  `action` is a `KilnCMS.Types.KnownAtom`: an action a newer release adds
  loads here as a `KilnCMS.Types.UnknownAtom`, and a condition this release
  can't read leaves its field shown (`KilnCMS.Forms.Logic.effective/2`).

  The checks against the rest of the form (the fields a rule names, their
  order and types) are `KilnCMS.CMS.Validations.FormFieldCondition`'s, on the
  field: an embedded resource can't see its siblings.
  """
  use Ash.Resource, data_layer: :embedded

  @actions [:show, :hide]

  @doc "The actions a condition may take."
  @spec actions() :: [atom()]
  def actions, do: @actions

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:action, :rule]
      change KilnCMS.CMS.FormFieldCondition.NormalizeRule
    end

    update :update do
      primary? true
      accept [:action, :rule]
      change KilnCMS.CMS.FormFieldCondition.NormalizeRule
    end
  end

  attributes do
    attribute :action, KilnCMS.Types.KnownAtom do
      allow_nil? false
      default :show
      constraints one_of: @actions
      public? true
    end

    attribute :rule, :map, allow_nil?: false, public?: true
  end
end
