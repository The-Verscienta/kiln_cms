defmodule KilnCMS.I18n.FieldFallback do
  @moduledoc """
  Fills a locale variant's empty `:fallback` fields along the site's locale
  fallback chain (#1327, Design A in `docs/field-level-localization.md`).

  The document-level chain (`KilnCMS.I18n.Fallback`, #1579) picks a **row**:
  the first variant that exists. This walks the same chain per **field**: for
  every field a type declares `:fallback` (`KilnCMS.I18n.FieldLocalization`)
  that is empty on the row being delivered, the value comes from the first
  other variant along `Fallback.chain(org, row.locale, :site)` that has one.

  It runs where a variant is turned into something a reader sees, and nowhere
  else — nothing is written back to the row:

    * `KilnCMS.Firing.Engine.fire/2`, before the block tree reaches a renderer,
      so every fired surface carries the filled value in the shape the field
      declares, and the `:json` artifact names what it filled under
      `"inherited_fields"`;
    * the public HTML page (`KilnCMSWeb.ContentController`), which renders the
      record live;
    * the `inherited_fields` calculation, which is how JSON:API and GraphQL
      clients ask for the same values (`KilnCMS.I18n.Calculations.InheritedFields`).

  ## Who a value may be inherited from

  Only a **published** sibling, readable by at least everyone who can read the
  row being filled: its audience is `:public` or the row's own, and it is not
  locked by a passphrase. Inheriting from anything wider would put a member-only
  or locked variant's text on a public page — the leak
  `KilnCMS.Firing.Engine` keeps fragments from causing, for the same reason.

  ## What it fills

    * record attributes the type's `localization:` option lists as `fallback:`;
    * custom fields whose definition's `localization` is `:fallback`;
    * block fields declared `localized: :fallback`, on top-level blocks and
      on blocks nested inside `columns` at any depth, matched to the donor's
      block by the shared block `_id` (and `_type`), wherever in the donor's
      tree that block sits.

  A field is empty when `KilnCMS.I18n.FieldLocalization.empty?/1` says so.
  """

  require Ash.Query

  alias KilnCMS.I18n.Fallback
  alias KilnCMS.I18n.FieldLocalization

  @typedoc """
  Where each filled value came from, by locale:

      %{"excerpt" => "en",
        "custom_fields" => %{"caption" => "en"},
        "blocks" => %{"<block id>" => %{"caption" => "fr"}}}

  Empty when nothing was filled.
  """
  @type inherited :: %{optional(String.t()) => String.t() | map()}

  @doc """
  `record` with its empty `:fallback` fields filled, and where each came from.

  ## Options

    * `:definitions` — the record's custom-field definitions, when the caller
      already read them; otherwise read as `:actor`.
    * `:actor` — who reads the definitions. Defaults to the `:localization`
      system actor.
    * `:attributes` — the record-attribute modes, `%{shared: [...], fallback:
      [...]}`. Defaults to what the record's type declares
      (`FieldLocalization.attributes/1`).
  """
  @spec fill(struct(), keyword()) :: {struct(), inherited()}
  def fill(record, opts \\ []) do
    definitions =
      Keyword.get_lazy(opts, :definitions, fn ->
        FieldLocalization.definitions(record, Keyword.get(opts, :actor, system_actor()))
      end)

    attributes =
      Keyword.get_lazy(opts, :attributes, fn -> FieldLocalization.attributes(record) end)

    plan = plan(record, definitions, attributes)

    if plan == :none do
      {record, %{}}
    else
      case donors(record) do
        [] -> {record, %{}}
        donors -> apply_plan(record, plan, donors)
      end
    end
  end

  @doc """
  The values `fill/2` would inherit, with their source locale, in the shape
  the `inherited_fields` calculation serves: record attributes and custom
  fields only (`blocks` is not a JSON:API or GraphQL field).

      %{"excerpt" => %{"value" => "…", "locale" => "en"},
        "custom_fields" => %{"caption" => %{"value" => "…", "locale" => "en"}}}
  """
  @spec inherited_values(struct(), keyword()) :: map()
  def inherited_values(record, opts \\ []) do
    {filled, inherited} = fill(record, opts)

    inherited
    |> Map.delete("blocks")
    |> Map.new(fn
      {"custom_fields", fields} ->
        values = Map.get(filled, :custom_fields) || %{}

        {"custom_fields",
         Map.new(fields, fn {name, locale} ->
           {name, %{"value" => Map.get(values, name), "locale" => locale}}
         end)}

      {attribute, locale} ->
        {attribute,
         %{"value" => Map.get(filled, String.to_existing_atom(attribute)), "locale" => locale}}
    end)
  end

  # What this record could inherit: `:none` when the type declares no
  # `:fallback` field at all, which is every site that opted nothing in.
  defp plan(record, definitions, modes) do
    attributes = Enum.filter(modes.fallback, &FieldLocalization.empty?(Map.get(record, &1)))

    custom_values = Map.get(record, :custom_fields) || %{}

    custom =
      for {name, :fallback} <- FieldLocalization.custom_fields(definitions),
          FieldLocalization.empty?(Map.get(custom_values, name)),
          do: name

    blocks =
      for %module{id: id} = value <-
            FieldLocalization.typed_blocks(FieldLocalization.block_list(record)),
          not is_nil(id),
          fields <- [empty_fallback_fields(module, value)],
          fields != [],
          into: %{},
          do: {id, {module, fields}}

    if attributes == [] and custom == [] and blocks == %{},
      do: :none,
      else: %{attributes: attributes, custom: custom, blocks: blocks}
  end

  defp empty_fallback_fields(module, value) do
    for {name, :fallback} <- FieldLocalization.block_fields(module),
        FieldLocalization.empty?(Map.get(value, name)),
        do: name
  end

  defp apply_plan(record, plan, donors) do
    {record, inherited} =
      Enum.reduce(plan.attributes, {record, %{}}, fn attribute, {acc, inherited} ->
        case first_value(donors, &Map.get(&1, attribute)) do
          {value, locale} ->
            {Map.put(acc, attribute, value), Map.put(inherited, to_string(attribute), locale)}

          nil ->
            {acc, inherited}
        end
      end)

    {record, inherited} = fill_custom(record, plan.custom, donors, inherited)
    fill_blocks(record, plan.blocks, donors, inherited)
  end

  defp fill_custom(record, [], _donors, inherited), do: {record, inherited}

  defp fill_custom(record, names, donors, inherited) do
    {values, filled} =
      Enum.reduce(names, {Map.get(record, :custom_fields) || %{}, %{}}, fn name,
                                                                           {values, filled} ->
        case first_value(donors, &Map.get(Map.get(&1, :custom_fields) || %{}, name)) do
          {value, locale} -> {Map.put(values, name, value), Map.put(filled, name, locale)}
          nil -> {values, filled}
        end
      end)

    if filled == %{},
      do: {record, inherited},
      else: {Map.put(record, :custom_fields, values), Map.put(inherited, "custom_fields", filled)}
  end

  defp fill_blocks(record, plan, _donors, inherited) when plan == %{}, do: {record, inherited}

  defp fill_blocks(record, plan, donors, inherited) do
    donor_blocks =
      Enum.map(
        donors,
        &{&1.locale, FieldLocalization.blocks_by_id(FieldLocalization.block_list(&1))}
      )

    {blocks, filled} =
      FieldLocalization.map_reduce_block_fields(
        FieldLocalization.block_list(record),
        %{},
        &fill_planned_block(&1, &2, plan, donor_blocks)
      )

    if filled == %{},
      do: {record, inherited},
      else: {Map.put(record, :blocks, blocks), Map.put(inherited, "blocks", filled)}
  end

  # The fields to fill on one block, at whatever depth, and where each came from.
  defp fill_planned_block(%{id: id} = value, filled, plan, donor_blocks) do
    case Map.fetch(plan, id) do
      {:ok, {module, fields}} ->
        {changes, block_filled} = fill_block(value, module, fields, donor_blocks)
        filled = if block_filled == %{}, do: filled, else: Map.put(filled, id, block_filled)
        {changes, filled}

      :error ->
        {%{}, filled}
    end
  end

  defp fill_planned_block(_value, filled, _plan, _donor_blocks), do: {%{}, filled}

  defp fill_block(value, module, fields, donor_blocks) do
    Enum.reduce(fields, {%{}, %{}}, fn field, {changes, filled} ->
      case Enum.find_value(donor_blocks, &donor_value(&1, module, value.id, field)) do
        {candidate, locale} ->
          {Map.put(changes, field, candidate), Map.put(filled, to_string(field), locale)}

        nil ->
          {changes, filled}
      end
    end)
  end

  # The donor's value for `field` of the block with `id`, if it holds that
  # block (same id, same type) and the value is not empty.
  defp donor_value({locale, by_id}, module, id, field) do
    with %^module{} = donor <- Map.get(by_id, id),
         candidate = Map.get(donor, field),
         false <- FieldLocalization.empty?(candidate) do
      {candidate, locale}
    else
      _none -> nil
    end
  end

  defp first_value(donors, getter) do
    Enum.find_value(donors, fn donor ->
      value = getter.(donor)
      if FieldLocalization.empty?(value), do: nil, else: {value, donor.locale}
    end)
  end

  @doc """
  The siblings `record` may inherit from, in chain order: published,
  unlocked, and readable by everyone who can read `record` (see the
  moduledoc). `[]` when the site's chain for the record's locale is empty.
  """
  @spec donors(struct()) :: [struct()]
  def donors(%module{org_id: org_id, slug: slug, locale: locale} = record)
      when is_binary(slug) and is_binary(locale) do
    case tl(Fallback.chain(org_id, locale, :site)) do
      [] ->
        []

      chain ->
        audiences = Enum.uniq([:public, Map.get(record, :audience) || :public])

        module
        |> Ash.Query.filter(
          slug == ^slug and locale in ^chain and state == :published and
            audience in ^audiences and is_nil(access_password_hash)
        )
        |> scope_to_type(record)
        # authorize?: false — a delivery-path read with no actor, pinned to
        # this tenant, this slug and the published, unlocked, no-wider-audience
        # variants above. Only the values of fields the type marked
        # `:fallback` leave this module.
        |> Ash.read!(tenant: org_id, authorize?: false)
        |> Enum.sort_by(&Enum.find_index(chain, fn candidate -> candidate == &1.locale end))
    end
  end

  def donors(_record), do: []

  # Dynamic entries share one table across every admin-defined type, so a
  # slug is only unique within its type definition.
  defp scope_to_type(query, %{type_definition_id: id}) when is_binary(id),
    do: Ash.Query.filter(query, type_definition_id == ^id)

  defp scope_to_type(query, _record), do: query

  defp system_actor, do: KilnCMS.SystemActor.new(:localization)
end
