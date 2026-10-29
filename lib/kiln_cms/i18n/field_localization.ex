defmodule KilnCMS.I18n.FieldLocalization do
  @moduledoc """
  Field-level localization over locale variants (#1327, Design A in
  `docs/field-level-localization.md`).

  Kiln stores **one record per locale**, and that does not change. What this
  adds is a per-field *mode*:

    * `:localized` (the default) — each variant holds its own value, which is
      what every field did before;
    * `:shared` — one value for the document, owned by the **source variant**
      (the default-locale row) and copied into every sibling when the source
      publishes (`KilnCMS.I18n.SharedFields`);
    * `:fallback` — a variant may leave the value empty, and delivery fills it
      from the first variant along the site's fallback chain that has one
      (`KilnCMS.I18n.FieldFallback`).

  The modes are declared in three places, one per kind of field:

    * **block fields** — `field :image_url, :string, localized: :shared` on a
      `Kiln.Block` (`Kiln.Block.Info.localization/1`);
    * **custom fields** — the `localization` attribute on a
      `KilnCMS.CMS.FieldDefinition`, set on the Fields screen;
    * **record attributes** — the `localization:` option of
      `use KilnCMS.CMS.Content`, e.g.
      `localization: [shared: [:seo_image, :category_id], fallback: [:excerpt]]`;
    * **relationships** — the same option's `shared:` list may also name
      `:tags` and `:related` (the curated related content, #1859). Their
      copy is `KilnCMS.I18n.SharedFields`'; neither can fall back.

  Nothing is shared or inherited until one of those opts in, so a site that
  declares none of them behaves exactly as before.

  This module is the one place those declarations are read back.
  """

  require Logger

  alias KilnCMS.Blocks.Columns
  alias KilnCMS.Blocks.Upcaster
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.I18n

  @typedoc "A field's localization mode."
  @type mode :: :localized | :shared | :fallback

  @modes [:localized, :shared, :fallback]

  # Record attributes a type may share: one value for the document is a
  # coherent answer for each. `title`, `slug`, `locale` and `canonical_url` are
  # absent on purpose — they are what makes a variant *this* locale's page.
  @shareable [
    :excerpt,
    :seo_title,
    :seo_description,
    :seo_keywords,
    :seo_image,
    :category_id,
    :featured_image_id
  ]

  # Relationships a type may share (#1859): the tag set, copied as tag ids
  # (tags have no locale), and the curated related list, each target resolved
  # to its variant in the sibling's locale (`KilnCMS.I18n.SharedFields`).
  @shareable_relationships [:tags, :related]

  # Record attributes that may fall back. Text (and the social image) only:
  # what a reader sees about the page, where "use the next locale's" is a
  # better answer than nothing.
  @fallbackable [:excerpt, :seo_title, :seo_description, :seo_keywords, :seo_image]

  @doc "The three modes, default first."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "The record attributes the `localization:` option may name as `shared:`."
  @spec shareable_attributes() :: [atom()]
  def shareable_attributes, do: @shareable

  @doc "The relationships the `localization:` option may name as `shared:` (#1859)."
  @spec shareable_relationships() :: [atom()]
  def shareable_relationships, do: @shareable_relationships

  @doc "The record attributes the `localization:` option may name as `fallback:`."
  @spec fallbackable_attributes() :: [atom()]
  def fallbackable_attributes, do: @fallbackable

  @doc """
  Validates the `localization:` option of `use KilnCMS.CMS.Content` at build
  time and returns it normalized, as `%{shared: [atom], fallback: [atom]}`.

  `nil` (the option left out) is `%{shared: [], fallback: []}`. Anything else
  that is not a keyword list of `shared:` / `fallback:` attribute lists raises
  an `ArgumentError` naming the problem, so a typo fails the overlay's
  compile rather than silently sharing nothing.
  """
  @spec validate!(term(), boolean()) :: %{shared: [atom()], fallback: [atom()]}
  def validate!(nil, _excerpt?), do: %{shared: [], fallback: []}

  def validate!(option, excerpt?) when is_list(option) do
    unless Keyword.keyword?(option) and Keyword.keys(option) -- [:shared, :fallback] == [] do
      invalid!("expected a keyword list of `shared:` and `fallback:`, got: #{inspect(option)}")
    end

    shared =
      option
      |> Keyword.get(:shared, [])
      |> check_list!(:shared, @shareable ++ @shareable_relationships, excerpt?)

    fallback =
      option |> Keyword.get(:fallback, []) |> check_list!(:fallback, @fallbackable, excerpt?)

    case Enum.filter(shared, &(&1 in fallback)) do
      [] -> :ok
      both -> invalid!("#{inspect(both)} cannot be both shared and fallback")
    end

    %{shared: shared, fallback: fallback}
  end

  def validate!(option, _excerpt?),
    do: invalid!("expected a keyword list of `shared:` and `fallback:`, got: #{inspect(option)}")

  defp check_list!(names, key, allowed, excerpt?) do
    unless is_list(names) and Enum.all?(names, &is_atom/1) do
      invalid!("`#{key}:` must be a list of attribute names, got: #{inspect(names)}")
    end

    case Enum.reject(names, &(&1 in allowed)) do
      [] ->
        :ok

      unknown ->
        invalid!("`#{key}:` cannot name #{inspect(unknown)}; it may name #{inspect(allowed)}")
    end

    if :excerpt in names and not excerpt? do
      invalid!("`#{key}:` names :excerpt, but this type has no excerpt (`excerpt?: true`)")
    end

    Enum.uniq(names)
  end

  defp invalid!(message),
    do:
      raise(
        ArgumentError,
        "invalid `localization:` option to `use KilnCMS.CMS.Content`: " <> message
      )

  @doc """
  The record-attribute modes for a content resource, as
  `%{shared: [atom], fallback: [atom]}`: what its `localization:` option
  declares, joined with what the operator configures for its type under
  `config :kiln_cms, :i18n, field_localization: [page: [shared: [...]]]`.

  The config is how a site opts the **core** types (`page`, `post`) in, since
  it cannot edit their `use` line. It names a compiled type by its `type`
  atom and takes the same keyword list the option does. A malformed entry is
  ignored with a logged warning rather than raised on: it is read at run time,
  on delivery paths. Empty for a resource that declares nothing, and for
  anything built outside the Content macro.

  Record attributes only: a shared relationship (`:tags`, `:related`) the
  same option names is `relationships/1`'s.
  """
  @spec attributes(module() | struct()) :: %{shared: [atom()], fallback: [atom()]}
  def attributes(record_or_module) do
    modes = modes(record_or_module)
    %{modes | shared: modes.shared -- @shareable_relationships}
  end

  @doc """
  The relationships a content resource shares across its locale variants
  (#1859): the subset of `:tags` and `:related` its `localization:` option, or
  the operator's `field_localization:` entry for its type, names as `shared:`.
  `[]` for a resource that shares neither.
  """
  @spec relationships(module() | struct()) :: [atom()]
  def relationships(record_or_module),
    do: Enum.filter(modes(record_or_module).shared, &(&1 in @shareable_relationships))

  # Everything declared and configured, attributes and relationships together.
  defp modes(%module{}), do: modes(module)

  defp modes(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__kiln_localization__, 0) do
      module.__kiln_localization__() |> merge(configured(module))
    else
      %{shared: [], fallback: []}
    end
  end

  defp modes(_other), do: %{shared: [], fallback: []}

  defp merge(declared, nil), do: declared

  defp merge(declared, configured) do
    fallback = Enum.uniq(declared.fallback ++ configured.fallback) -- declared.shared
    shared = Enum.uniq(declared.shared ++ configured.shared) -- fallback
    %{shared: shared, fallback: fallback}
  end

  # The operator's `field_localization:` entry for this module's type, validated
  # like the option; nil when there is none or it does not validate.
  defp configured(module) do
    with true <- function_exported?(module, :__kiln_content_type__, 0),
         config when is_list(config) <- Application.get_env(:kiln_cms, :i18n, []),
         true <- Keyword.keyword?(config),
         entries when is_list(entries) <- Keyword.get(config, :field_localization),
         true <- Keyword.keyword?(entries),
         entry when not is_nil(entry) <- Keyword.get(entries, module.__kiln_content_type__()) do
      try do
        validate!(entry, Ash.Resource.Info.attribute(module, :excerpt) != nil)
      rescue
        error in ArgumentError ->
          Logger.warning(
            "ignoring :i18n field_localization for #{inspect(module)}: " <>
              Exception.message(error)
          )

          nil
      end
    else
      _none -> nil
    end
  end

  @doc "The custom-field modes in `definitions`, by field name, skipping `:localized`."
  @spec custom_fields([struct()]) :: %{String.t() => :shared | :fallback}
  def custom_fields(definitions) do
    for %{name: name, localization: mode} <- definitions,
        mode in [:shared, :fallback],
        into: %{},
        do: {name, mode}
  end

  @doc "A block module's non-default field modes, by field name."
  @spec block_fields(module()) :: %{atom() => :shared | :fallback}
  def block_fields(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) do
      for {name, mode} <- Kiln.Block.Info.localization(module),
          mode != :localized,
          into: %{},
          do: {name, mode}
    else
      %{}
    end
  end

  def block_fields(_module), do: %{}

  @doc "The locale that owns shared values: the deployment's default locale."
  @spec source_locale() :: String.t()
  def source_locale, do: I18n.default_locale()

  @doc "Whether `record` is the source variant of its document."
  @spec source?(struct()) :: boolean()
  def source?(%{locale: locale}), do: locale == source_locale()
  def source?(_record), do: false

  @doc """
  Whether a value counts as **empty** for `:fallback`: `nil`, a blank string,
  an empty list or an empty map. `false` and `0` are values.
  """
  @spec empty?(term()) :: boolean()
  def empty?(nil), do: true
  def empty?(value) when is_binary(value), do: String.trim(value) == ""
  def empty?([]), do: true
  def empty?(value) when is_map(value) and not is_struct(value), do: map_size(value) == 0
  def empty?(_value), do: false

  @doc """
  The custom-field definitions in scope for a content record, read as
  `actor` under the record's own org: its dynamic type's, or its compiled
  type's. `[]` for a record outside both.
  """
  @spec definitions(struct(), term()) :: [struct()]
  def definitions(%{org_id: org_id} = record, actor) do
    case {Map.get(record, :type_definition_id), content_type(record)} do
      {nil, nil} ->
        []

      {nil, type} ->
        KilnCMS.CMS.field_definitions_for!(type, actor: actor, tenant: org_id)

      {id, _type} ->
        KilnCMS.CMS.field_definitions_for_definition!(id, actor: actor, tenant: org_id)
    end
  end

  def definitions(_record, _actor), do: []

  defp content_type(%module{}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__kiln_content_type__, 0) do
      module.__kiln_content_type__()
    end
  end

  @doc """
  Whether anything on `record`'s type opts out of `:localized`: a declared
  record attribute or relationship, one of `definitions`, or a block in the
  record's tree (top level or nested inside `columns`) whose module declares a
  mode. The cheap gate every caller checks first, so a
  site that opted nothing in pays one definitions read and nothing more.
  """
  @spec any?(struct(), [struct()]) :: boolean()
  def any?(record, definitions) do
    %{shared: shared, fallback: fallback} = modes(record)

    shared != [] or fallback != [] or custom_fields(definitions) != %{} or
      Enum.any?(typed_blocks(block_list(record)), &(block_fields(block_module(&1)) != %{}))
  end

  @doc """
  Whether a content type can inherit a value along the fallback chain: its
  resource (`nil` for a dynamic type) declares a `fallback:` attribute, one of
  its `definitions` is a `:fallback` custom field, or any registered block
  declares a `localized: :fallback` field.
  """
  @spec inherits?(module() | nil, [struct()]) :: boolean()
  def inherits?(resource, definitions) do
    (resource != nil and attributes(resource).fallback != []) or
      :fallback in Map.values(custom_fields(definitions)) or
      Enum.any?(KilnCMS.Blocks.modules(), &(:fallback in Map.values(block_fields(&1))))
  end

  @doc false
  def block_list(record) do
    case Map.get(record, :blocks) do
      blocks when is_list(blocks) -> blocks
      _none -> []
    end
  end

  @doc false
  # The module behind one stored block: an `%Ash.Union{}` wraps the struct.
  def block_module(%Ash.Union{value: %module{}}), do: module
  def block_module(%module{}), do: module
  def block_module(_block), do: nil

  # ── The block tree (#1858) ─────────────────────────────────────────────────
  # A shared or fallback field behaves the same at every depth. Top-level
  # blocks come out of the union's `cast_stored` as typed structs, upcast to
  # their current version. A `columns` child does not: it is stored as the raw
  # map it was written as (the recursive-type cycle `KilnCMS.Blocks.Columns`
  # avoids), so it is typed here through `TypedBlocks.to_typed/1`, which
  # upcasts it first. Both sides of every comparison are then read at the same
  # schema version, whichever depth they sit at.

  @doc false
  # Every block in `blocks` at every depth, typed, in document order: each
  # block followed by the children of its columns, recursively.
  @spec typed_blocks([term()] | nil) :: [struct()]
  def typed_blocks(blocks) do
    Enum.flat_map(List.wrap(blocks), fn block ->
      case typed(block) do
        %Columns{} = value -> [value | typed_blocks(Columns.child_blocks_flat(value))]
        %_{} = value -> [value]
        nil -> []
      end
    end)
  end

  @doc false
  # `typed_blocks/1` by block id. The variants share ids at every depth
  # (`ContentCopy` keeps them on the translation path), so a block is matched
  # to its counterpart by id whether it is top-level or nested.
  @spec blocks_by_id([term()] | nil) :: %{term() => struct()}
  def blocks_by_id(blocks) do
    for %{id: id} = value <- typed_blocks(blocks), not is_nil(id), into: %{}, do: {id, value}
  end

  @doc false
  # `blocks` with `fun` applied to every block at every depth, threading `acc`.
  # `fun` gets a block's typed struct and returns `{changes, acc}`, where
  # `changes` maps field names to the values to write (`%{}` for none).
  #
  # A top-level block takes the changes into its struct. A nested child keeps
  # its raw map: it is left exactly as stored when nothing changes, and is
  # otherwise upcast (so the fields written are the current version's) and
  # takes each value dumped to its stored form.
  @spec map_reduce_block_fields([term()] | nil, acc, (struct(), acc -> {map(), acc})) ::
          {[term()] | nil, acc}
        when acc: term()
  def map_reduce_block_fields(blocks, acc, fun) when is_list(blocks),
    do: Enum.map_reduce(blocks, acc, &update_block(&1, &2, fun))

  def map_reduce_block_fields(blocks, acc, _fun), do: {blocks, acc}

  # A top-level block is an `%Ash.Union{}` (or its bare struct) by the time
  # anything reads it; anything else is left alone.
  defp update_block(block, acc, fun) when is_struct(block) do
    case typed(block) do
      %_{} = value ->
        {changes, acc} = fun.(value, acc)
        value = Map.merge(value, changes)
        {columns, acc} = update_columns(value, Map.get(value, :columns), acc, fun)
        value = if columns == :none, do: value, else: %{value | columns: columns}
        {put_typed(block, value), acc}

      nil ->
        {block, acc}
    end
  end

  defp update_block(block, acc, _fun), do: {block, acc}

  defp put_typed(%Ash.Union{} = union, value), do: %{union | value: value}
  defp put_typed(_block, value), do: value

  defp update_columns(%Columns{}, columns, acc, fun) when is_list(columns),
    do: Enum.map_reduce(columns, acc, &update_column(&1, &2, fun))

  defp update_columns(_value, _columns, acc, _fun), do: {:none, acc}

  defp update_column(%{} = column, acc, fun) do
    key = if Map.has_key?(column, :blocks), do: :blocks, else: "blocks"

    case Map.get(column, key) do
      children when is_list(children) ->
        {children, acc} = Enum.map_reduce(children, acc, &update_child(&1, &2, fun))
        {Map.put(column, key, children), acc}

      _none ->
        {column, acc}
    end
  end

  defp update_column(column, acc, _fun), do: {column, acc}

  defp update_child(%{} = child, acc, fun) when not is_struct(child) do
    case typed(child) do
      %module{id: id} = value when not is_nil(id) ->
        {changes, acc} = fun.(value, acc)
        child = if changes == %{}, do: child, else: put_raw_fields(child, module, changes)
        update_nested_columns(child, value, acc, fun)

      %_{} = value ->
        update_nested_columns(child, value, acc, fun)

      nil ->
        {child, acc}
    end
  end

  defp update_child(child, acc, _fun), do: {child, acc}

  # A child that is itself a `columns` block keeps its columns under its own
  # (string, as stored) key.
  defp update_nested_columns(child, %Columns{}, acc, fun) do
    key = if Map.has_key?(child, :columns), do: :columns, else: "columns"

    case Map.get(child, key) do
      columns when is_list(columns) ->
        {columns, acc} = Enum.map_reduce(columns, acc, &update_column(&1, &2, fun))
        {Map.put(child, key, columns), acc}

      _none ->
        {child, acc}
    end
  end

  defp update_nested_columns(child, _value, acc, _fun), do: {child, acc}

  defp put_raw_fields(child, module, changes) do
    child = child |> Map.new(fn {key, value} -> {to_string(key), value} end)
    child = Upcaster.upcast_block_map(child)

    Enum.reduce(changes, child, fn {name, value}, acc ->
      Map.put(acc, to_string(name), dump(module, name, value))
    end)
  end

  # A value written into a raw child is stored as JSON, so it takes the form
  # its block attribute dumps to, whichever depth it was read from.
  defp dump(module, name, value) do
    with %{type: type, constraints: constraints} <- Ash.Resource.Info.attribute(module, name),
         {:ok, dumped} <- Ash.Type.dump_to_embedded(type, value, constraints) do
      dumped
    else
      _not_dumpable -> value
    end
  end

  defp typed(%Ash.Union{value: %_{} = value}), do: value
  defp typed(%Ash.Union{}), do: nil
  defp typed(%_{} = value), do: value
  defp typed(%{} = raw), do: raw |> List.wrap() |> TypedBlocks.to_typed() |> hd()
  defp typed(_other), do: nil
end
