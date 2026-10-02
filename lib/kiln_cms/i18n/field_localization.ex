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
      `localization: [shared: [:seo_image, :category_id], fallback: [:excerpt]]`.

  Nothing is shared or inherited until one of those opts in, so a site that
  declares none of them behaves exactly as before.

  This module is the one place those declarations are read back.
  """

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

    shared = option |> Keyword.get(:shared, []) |> check_list!(:shared, @shareable, excerpt?)

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
  The record-attribute modes a content resource declares, as
  `%{shared: [atom], fallback: [atom]}`. Empty for a resource that declares
  none, and for anything built outside the Content macro.
  """
  @spec attributes(module() | struct()) :: %{shared: [atom()], fallback: [atom()]}
  def attributes(%module{}), do: attributes(module)

  def attributes(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__kiln_localization__, 0) do
      module.__kiln_localization__()
    else
      %{shared: [], fallback: []}
    end
  end

  def attributes(_other), do: %{shared: [], fallback: []}

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
  record attribute, one of `definitions`, or a block in the record's tree
  whose module declares a mode. The cheap gate every caller checks first, so a
  site that opted nothing in pays one definitions read and nothing more.
  """
  @spec any?(struct(), [struct()]) :: boolean()
  def any?(record, definitions) do
    %{shared: shared, fallback: fallback} = attributes(record)

    shared != [] or fallback != [] or custom_fields(definitions) != %{} or
      Enum.any?(block_list(record), &(block_fields(block_module(&1)) != %{}))
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
end
