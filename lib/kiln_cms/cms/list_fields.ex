defmodule KilnCMS.CMS.ListFields do
  @moduledoc """
  Which custom fields the content list (`/editor`) may show as columns.

  Every choice of list columns goes through `readable_fields/4`, so a rule
  about who may see a field (private fields today, #2044; more under #2281)
  lives in one place. The list is editor-only, and editors already see
  private values in the content editor, so the UI path passes
  `include_private?: true`; a caller that lists fields for anyone else, or
  for a file that leaves the console, passes `false`.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping

  # What a column can show as one short value. `:group`, `:geolocation`, `:json` and
  # multi-valued fields are left out of the picker in v1.
  @picker_types [
    :string,
    :text,
    :integer,
    :float,
    :boolean,
    :date,
    :datetime,
    :url,
    :select,
    :reference,
    :user,
    :media,
    :email,
    :telephone,
    :color,
    :slug,
    :time
  ]

  # The most columns remembered per type, and shown in a row's strip.
  @max_stored 6
  @max_shown 4

  @doc "The field types the column picker offers."
  @spec picker_types() :: [atom()]
  def picker_types, do: @picker_types

  @doc "The most column names stored per type."
  @spec max_stored() :: pos_integer()
  def max_stored, do: @max_stored

  @doc "The most columns a row shows."
  @spec max_shown() :: pos_integer()
  def max_shown, do: @max_shown

  @doc """
  The definitions among `definitions` that `actor` may list as columns on
  `tenant`'s site, in their given order.

  A private field is kept only when `include_private?` is true *and* the
  actor is an editor or admin of the site; everything else is dropped.
  Fields whose type the picker does not offer (`picker_types/0`), and
  multiple-valued ones, are dropped too.
  """
  @spec readable_fields(map() | nil, term(), [struct()], boolean()) :: [struct()]
  def readable_fields(actor, tenant, definitions, include_private?)
      when is_list(definitions) and is_boolean(include_private?) do
    private_ok? =
      include_private? and
        Scoping.effective_tier(actor, Accounts.org_id(tenant)) in [:editor, :admin]

    Enum.filter(definitions, fn definition ->
      pickable?(definition) and (private_ok? or not private?(definition))
    end)
  end

  @doc "True when the picker offers a field of this definition's type."
  @spec pickable?(struct()) :: boolean()
  def pickable?(%{field_type: type} = definition),
    do: type in @picker_types and Map.get(definition, :multiple) != true

  def pickable?(_definition), do: false

  @doc """
  The column names `user` remembered for `type` on the site `org_id`, or `[]`.

  Reads the org-keyed map of `content_list_columns` defensively: an unloaded
  or missing attribute, a missing org or type, or a malformed value is `[]`.
  At most `max_stored/0` strings come back.
  """
  @spec stored_columns(map() | nil, term(), term()) :: [String.t()]
  def stored_columns(%{content_list_columns: columns}, org_id, type)
      when is_map(columns) and not is_struct(columns) and is_binary(org_id) and is_binary(type) do
    case columns do
      %{^org_id => %{^type => names}} when is_list(names) ->
        names |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.take(@max_stored)

      _ ->
        []
    end
  end

  def stored_columns(_user, _org_id, _type), do: []

  @doc """
  The stored `names` that still name one of `definitions`, in stored order
  (a field deleted since is dropped silently), capped at `max_shown/0`.
  """
  @spec resolve_columns([String.t()], [struct()]) :: [struct()]
  def resolve_columns(names, definitions) when is_list(names) and is_list(definitions) do
    by_name = Map.new(definitions, &{&1.name, &1})

    names
    |> Enum.flat_map(fn name -> List.wrap(Map.get(by_name, name)) end)
    |> Enum.take(@max_shown)
  end

  defp private?(definition), do: Map.get(definition, :private) == true
end
