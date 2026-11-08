defmodule KilnCMS.CMS.DynamicDefaults do
  @moduledoc """
  Dynamic default values for custom fields (#2286): a `FieldDefinition` whose
  `default_source` names where a **new** record's value comes from, in place of
  the static `default` string.

  A closed set, no expression strings:

  | source          | value                                                    | field types           |
  |-----------------|----------------------------------------------------------|-----------------------|
  | `:today`        | the site's current day (the write's pinned `today`)      | `:date`               |
  | `:now`          | the current moment, UTC, to the second                   | `:datetime`           |
  | `:current_user` | the writing user, when they are a person on the site     | `:user`               |
  | `:site_locale`  | the site's default locale (`KilnCMS.I18n.default_locale/0`) | `:string`, `:select` (when it is an option) |
  | `:copy_of`      | another field's value on the same record (`default_field`) | the source's own type |

  `today` is the same site day `today()` answers in a computed formula
  (`KilnCMS.CMS.Computed.Context`), so one write never mixes two days.

  ## When it applies

  **On create only**, and only where the payload leaves the field blank or
  absent: a value the writer supplied always wins. An update never re-defaults
  a field — clearing it on an edit leaves it empty (a static `default` resets
  a cleared field; a dynamic one is not a standing rule). Machinery that
  carries values the record already holds (a copy, a restore — they set
  `custom_fields_constraints: :skip`) defaults nothing.

  Two further rules decide whether a field is defaulted at all:

    * **Conditional visibility.** A field hidden by its `visible_when` rule on
      the new record's values is not defaulted — an invisible field would
      carry a value its writer cannot see or clear.
    * **Field grants.** A default is not the writer's edit. A field the acting
      editor's `field_grants` do not cover still receives its default on
      create (like a static `default`), and `Changes.EnforceCustomFieldGrants`
      does not count it as a change while the payload left it blank. A value
      the editor *supplies* for it is judged as ever.

  A source that yields nothing (no acting user, a locale that is not one of a
  select's options, a `:copy_of` whose source is blank) leaves the field
  empty, which `required` then reports like any other blank field.

  `:copy_of` reads the payload, so it fires when a create names the source
  field. The editor's "New" button creates a title-only draft first, so a
  document started there has nothing to copy yet; `:copy_of` is for creates
  that carry values (API, import, forms).
  """

  alias KilnCMS.CMS.Computed.Context
  alias KilnCMS.CMS.Conditions

  @sources [:today, :now, :current_user, :site_locale, :copy_of]

  # Field types a `:copy_of` may copy between: scalar, single-valued.
  @copy_types [:string, :text, :url, :integer, :float, :boolean, :date, :datetime, :select, :user]

  @doc "The sources, in the order the fields form offers them."
  @spec sources() :: [atom()]
  def sources, do: @sources

  @doc "The field types a `:copy_of` default may copy between."
  @spec copy_types() :: [atom()]
  def copy_types, do: @copy_types

  @doc "The sources a field of `type` may take."
  @spec sources_for(atom()) :: [atom()]
  def sources_for(:date), do: [:today, :copy_of]
  def sources_for(:datetime), do: [:now, :copy_of]
  def sources_for(:user), do: [:current_user, :copy_of]
  def sources_for(:string), do: [:site_locale, :copy_of]
  def sources_for(:select), do: [:site_locale, :copy_of]
  def sources_for(type) when type in @copy_types, do: [:copy_of]
  def sources_for(_type), do: []

  @doc "Whether `definition` carries a dynamic default."
  @spec dynamic?(map()) :: boolean()
  def dynamic?(definition), do: not is_nil(Map.get(definition, :default_source))

  @doc """
  `definitions` with each dynamic default settled for this write, and the names
  of the fields the default now stands in for (payload blank or absent).

  `ctx` carries `:create?` (an ordinary create), `:today`, `:actor`, `:tenant`
  and the `:supplied` payload (string keys). On any other write a dynamic
  default resolves to nothing, so a cleared field stays cleared.
  """
  @spec settle([map()], map()) :: {[map()], [String.t()]}
  def settle(definitions, ctx) do
    if Enum.any?(definitions, &dynamic?/1) do
      do_settle(definitions, ctx)
    else
      {definitions, []}
    end
  end

  defp do_settle(definitions, %{create?: false}),
    do: {Enum.map(definitions, &strip/1), []}

  defp do_settle(definitions, ctx) do
    hidden = Conditions.effective(definitions, ctx.supplied)
    by_name = Map.new(definitions, &{&1.name, &1})

    settled = Enum.map(definitions, &settle_one(&1, ctx, hidden, by_name))

    defaulted =
      for %{name: name, default: default} = definition <- settled,
          dynamic?(definition),
          not is_nil(default),
          blank_payload?(Map.get(ctx.supplied, name)),
          do: name

    {settled, defaulted}
  end

  defp settle_one(definition, ctx, hidden, by_name) do
    cond do
      not dynamic?(definition) -> definition
      hidden[definition.name].hidden? -> %{definition | default: nil}
      true -> %{definition | default: value(definition, ctx, by_name)}
    end
  end

  # A dynamic source stands in for `default`; with no create to default, none.
  defp strip(%{default_source: nil} = definition), do: definition
  defp strip(definition), do: %{definition | default: nil}

  defp value(%{default_source: :today}, ctx, _by_name), do: Date.to_iso8601(ctx.today)

  defp value(%{default_source: :now}, _ctx, _by_name),
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp value(%{default_source: :current_user}, %{actor: %KilnCMS.Accounts.User{id: id}} = ctx, _) do
    if KilnCMS.CMS.Changes.ApplyCustomFields.site_person?(id, ctx.tenant), do: id
  end

  defp value(%{default_source: :current_user}, _ctx, _by_name), do: nil

  defp value(%{default_source: :site_locale} = definition, _ctx, _by_name) do
    locale = KilnCMS.I18n.default_locale()

    if definition.field_type == :select and locale not in definition.options,
      do: nil,
      else: locale
  end

  defp value(%{default_source: :copy_of, default_field: source}, ctx, by_name) do
    with false <- is_nil(source),
         raw when not is_nil(raw) <- Map.get(ctx.supplied, source),
         false <- blank_payload?(raw) do
      raw
    else
      _none -> source_default(by_name[source], ctx, by_name)
    end
  end

  # A copy of a source the payload left blank is that source's own default —
  # one hop only (`Validations.DefaultSource` refuses a source that itself
  # copies).
  defp source_default(%{default_source: source} = definition, ctx, by_name)
       when source not in [nil, :copy_of],
       do: value(definition, ctx, by_name)

  defp source_default(_definition, _ctx, _by_name), do: nil

  defp blank_payload?(nil), do: true
  defp blank_payload?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_payload?(_value), do: false

  @doc "The site's day for a write: the changeset's pinned `today`."
  @spec today(Ash.Changeset.t()) :: Date.t()
  def today(changeset), do: Context.pinned_today(changeset)
end
