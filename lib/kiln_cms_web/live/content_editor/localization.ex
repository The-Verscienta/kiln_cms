defmodule KilnCMSWeb.ContentEditor.Localization do
  @moduledoc """
  What the content editor shows for field-level localization (#1327, Design A
  in `docs/field-level-localization.md`).

  Built once per record load, from the translation coverage the editor already
  reads, into a plain map the inspector and the block canvas consult:

    * a `:shared` field on a **translation** is read-only, labelled *Shared:
      edited in the EN version*, with a link to the source variant;
    * a `:shared` field on the **source** is labelled *Shared with N locales*;
    * an empty `:fallback` field shows the value it will inherit as its
      placeholder, labelled with the locale it comes from.

  `active?: false` for a type that declares no `:shared` or `:fallback` field,
  and every helper here then answers "nothing to show" — so an editor of a
  site that opted nothing in renders exactly what it did.
  """
  use KilnCMSWeb, :html

  alias KilnCMS.I18n.FieldFallback
  alias KilnCMS.I18n.FieldLocalization

  @typedoc "See the moduledoc."
  @type t :: %{
          active?: boolean(),
          source?: boolean(),
          source_locale: String.t(),
          source_id: term(),
          shared_with: non_neg_integer(),
          attributes: %{atom() => :shared | :fallback},
          custom: %{String.t() => :shared | :fallback},
          inherited: map(),
          values: map()
        }

  @doc "The map for a record that opts nothing in."
  @spec inactive() :: t()
  def inactive do
    %{
      active?: false,
      source?: true,
      source_locale: FieldLocalization.source_locale(),
      source_id: nil,
      shared_with: 0,
      attributes: %{},
      custom: %{},
      inherited: %{},
      values: %{}
    }
  end

  @doc """
  The editor's localization map for `record`, given its custom-field
  `definitions` and the translation `coverage` (`Translations.coverage/3`).
  """
  @spec build(struct(), [struct()], [map()]) :: t()
  def build(record, definitions, coverage) do
    if FieldLocalization.any?(record, definitions) do
      modes = FieldLocalization.attributes(record)
      source_locale = FieldLocalization.source_locale()
      source = Enum.find_value(coverage, &(&1.locale == source_locale && &1.record))
      {filled, inherited} = FieldFallback.fill(record, definitions: definitions)

      %{
        active?: true,
        source?: FieldLocalization.source?(record),
        source_locale: source_locale,
        source_id: source && source.id,
        shared_with: Enum.count(coverage, &(&1.record && &1.record.id != record.id)),
        attributes:
          Map.merge(
            Map.new(modes.shared, &{&1, :shared}),
            Map.new(modes.fallback, &{&1, :fallback})
          ),
        custom: FieldLocalization.custom_fields(definitions),
        inherited: inherited,
        values: %{record: filled}
      }
    else
      inactive()
    end
  end

  @doc """
  The mode of a field: `{:attribute, :seo_title}`, `{:custom, "price"}` or
  `{:block, module, :caption}`. `:localized` when nothing says otherwise.
  """
  @spec mode(t(), tuple()) :: :localized | :shared | :fallback
  def mode(%{active?: false}, _field), do: :localized
  def mode(loc, {:attribute, name}), do: Map.get(loc.attributes, name, :localized)
  def mode(loc, {:custom, name}), do: Map.get(loc.custom, name, :localized)

  def mode(_loc, {:block, module, name}),
    do: module |> FieldLocalization.block_fields() |> Map.get(name, :localized)

  @doc "Whether `field` is shared and this record is a translation — read-only here."
  @spec locked?(t(), tuple()) :: boolean()
  def locked?(loc, field), do: mode(loc, field) == :shared and not loc.source?

  @doc """
  The value an empty `:fallback` field inherits, as text for a placeholder,
  with its source locale — `{text, locale}` — or `nil`. Block fields are
  addressed `{:block, module, name, block_id}`.
  """
  @spec inherited(t(), tuple()) :: {String.t(), String.t()} | nil
  def inherited(%{active?: false}, _field), do: nil

  def inherited(loc, {:attribute, name}) do
    with locale when is_binary(locale) <- Map.get(loc.inherited, to_string(name)) do
      {text(Map.get(loc.values.record, name)), locale}
    end
  end

  def inherited(loc, {:custom, name}) do
    with %{^name => locale} <- Map.get(loc.inherited, "custom_fields", %{}) do
      {text(Map.get(loc.values.record.custom_fields || %{}, name)), locale}
    end
  end

  def inherited(loc, {:block, _module, name, id}) do
    with %{^id => fields} <- Map.get(loc.inherited, "blocks", %{}),
         %{} <- fields,
         locale when is_binary(locale) <- Map.get(fields, to_string(name)),
         value when not is_nil(value) <- block_value(loc.values.record, id, name) do
      {text(value), locale}
    else
      _none -> nil
    end
  end

  @doc "The placeholder for an empty `:fallback` field, or `nil`."
  @spec placeholder(t(), tuple()) :: String.t() | nil
  def placeholder(loc, field) do
    case inherited(loc, field) do
      {text, _locale} -> text
      nil -> nil
    end
  end

  defp block_value(record, id, name) do
    Enum.find_value(FieldLocalization.block_list(record), fn
      %Ash.Union{value: %{id: ^id} = value} -> Map.get(value, name)
      _other -> nil
    end)
  end

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  @doc """
  The note under a field that is not per-locale: *Shared: edited in the EN
  version* (with a link to the source) on a translation, *Shared with N other
  locales* on the source, and on a fallback field the locale an empty value
  is inherited from. Renders nothing for a localized field.

  `field` is a mode key (see `mode/2`); `inherited` is the `inherited/2`
  answer for a fallback field, when the caller has one.
  """
  attr :localization, :map, required: true
  attr :field, :any, required: true
  attr :kind, :any, default: nil
  attr :inherited, :any, default: nil

  def localization_note(assigns) do
    assigns = assign(assigns, :mode, mode(assigns.localization, assigns.field))

    ~H"""
    <p
      :if={@mode == :shared and not @localization.source?}
      class="mt-1 flex items-center gap-1 text-xs text-base-content/70"
      data-localization="shared"
    >
      <.icon name="hero-link" class="size-3.5 shrink-0" />
      <span>
        {gettext("Shared: edited in the %{locale} version.",
          locale: String.upcase(@localization.source_locale)
        )}
      </span>
      <.link
        :if={@localization.source_id && @kind}
        navigate={~p"/editor/content/#{@kind}/#{@localization.source_id}"}
        class="text-primary-ink hover:underline"
      >
        {gettext("Open")}
      </.link>
    </p>
    <p
      :if={@mode == :shared and @localization.source?}
      class="mt-1 flex items-center gap-1 text-xs text-base-content/70"
      data-localization="shared"
    >
      <.icon name="hero-link" class="size-3.5 shrink-0" />
      {ngettext(
        "Shared with 1 other locale when you publish.",
        "Shared with %{count} other locales when you publish.",
        @localization.shared_with
      )}
    </p>
    <p
      :if={@mode == :fallback}
      class="mt-1 flex items-center gap-1 text-xs text-base-content/70"
      data-localization="fallback"
    >
      <.icon name="hero-arrow-uturn-down" class="size-3.5 shrink-0" />
      <span :if={@inherited}>
        {gettext("Empty here, so readers get the %{locale} value.",
          locale: String.upcase(elem(@inherited, 1))
        )}
      </span>
      <span :if={is_nil(@inherited)}>
        {gettext("Leave empty to inherit along the site's fallback chain.")}
      </span>
    </p>
    """
  end
end
