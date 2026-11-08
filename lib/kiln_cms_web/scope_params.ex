defmodule KilnCMSWeb.ScopeParams do
  @moduledoc """
  Turns the team page's scope pickers (`KilnCMSWeb.ScopePickers`) into the
  three granular-RBAC attributes a custom role or a membership stores —
  `editable_types`, `readable_types` and `field_grants` (#2141), and the
  fourth, `field_read_grants` (#2281).

  The pickers post *modes*, not attribute values, because the stored shapes
  give two different meanings to things a checkbox list cannot tell apart:

    * a type axis — `"all"` stores `[]` (no restriction from this record, so
      resolution falls through to the next one); `"only"` stores the checked
      list. "Only" with nothing checked is refused, never read as `[]`: that
      would silently widen the axis to every type.
    * a field-grant row — `"any"` deletes the type's key (falls through);
      `"only"` stores the checked list (again refused when empty); `"none"`
      stores `[]`, which stops resolution and lets the member change *no*
      fields of that type.

  The result is **merged onto the stored value**, never rebuilt from the params:

    * an axis whose mode is absent (or unrecognized) keeps its stored value;
    * only grant keys that arrive with a mode are touched — every other stored
      key, including ones for types this site no longer has, passes through;
    * a list whose picked set equals the stored set keeps the stored list
      verbatim, otherwise the stored order is kept and new picks are appended.

  So opening a form and saving it untouched writes back exactly what was there,
  and a param shape from an older page (or a replayed form recovery) can never
  overwrite a value it does not carry a mode for.

  The read picker of a grant row (`grant_read_mode[3]`, `grant_read_fields[3][]`,
  keyed by the same `grant_type[3]`) has the same three modes, stored in
  `field_read_grants`: `"any"` deletes the type's key (every private custom
  field stays visible), `"only"` stores the checked list (refused when empty),
  `"none"` stores `[]` (every private field hidden).

  Grant rows are posted by **position** — `grant_mode[3]`, `grant_type[3]` (the
  key, as a value) and `grant_fields[3][]` — so a stored key, which may be
  anything an earlier JSON editor accepted, never becomes part of a param name.
  """

  @type axis :: :editable_types | :readable_types
  @type stored :: %{
          editable_types: [String.t()],
          readable_types: [String.t()],
          field_grants: %{optional(String.t()) => [String.t()]},
          field_read_grants: %{optional(String.t()) => [String.t()]}
        }
  @type pick :: %{mode: String.t(), values: [String.t()] | nil}
  @type picks :: %{
          editable_types: pick() | nil,
          readable_types: pick() | nil,
          field_grants: %{optional(String.t()) => pick()},
          field_read_grants: %{optional(String.t()) => pick()}
        }
  @type errors :: %{
          optional(axis() | {:grant, String.t()} | {:read_grant, String.t()}) => :none_picked
        }

  @picker_keys ~w(editable_mode readable_mode grant_mode grant_type grant_fields
                  grant_read_mode grant_read_fields)
  @attribute_keys ~w(editable_types readable_types field_grants field_read_grants)

  @axis_params %{
    editable_types: {"editable_mode", "editable_types"},
    readable_types: {"readable_mode", "readable_types"}
  }

  @type_modes ~w(all only)
  @grant_modes ~w(any only none)

  @doc "The stored value of a create form: every axis unrestricted."
  @spec blank() :: stored()
  def blank,
    do: %{editable_types: [], readable_types: [], field_grants: %{}, field_read_grants: %{}}

  @doc "The scope attributes of a role, membership or user."
  @spec stored(map()) :: stored()
  def stored(%{} = record) do
    %{
      editable_types: Map.get(record, :editable_types) || [],
      readable_types: Map.get(record, :readable_types) || [],
      field_grants: Map.get(record, :field_grants) || %{},
      field_read_grants: Map.get(record, :field_read_grants) || %{}
    }
  end

  @doc """
  Normalizes submitted form params against the `stored` scope.

  Returns the params with the picker keys removed and the three attributes set
  to their merged values, or the axes and grant keys that chose "only" with
  nothing picked.
  """
  @spec normalize(map(), stored()) :: {:ok, map()} | {:error, errors()}
  def normalize(%{} = params, stored) do
    picks = picks(params)

    {editable, errors} = axis(picks, stored, :editable_types, %{})
    {readable, errors} = axis(picks, stored, :readable_types, errors)
    {grants, errors} = grants(picks.field_grants, stored.field_grants, errors)

    {read_grants, errors} =
      read_grants(picks.field_read_grants, Map.get(stored, :field_read_grants, %{}), errors)

    if errors == %{} do
      {:ok,
       params
       |> strip()
       |> Map.put("editable_types", editable)
       |> Map.put("readable_types", readable)
       |> Map.put("field_grants", grants)
       |> Map.put("field_read_grants", read_grants)}
    else
      {:error, errors}
    end
  end

  @doc """
  The params without any scope key — picker keys and raw attribute values
  alike, so nothing the client sent for those attributes reaches the form.
  """
  @spec strip(map()) :: map()
  def strip(%{} = params), do: Map.drop(params, @picker_keys ++ @attribute_keys)

  @doc """
  What the pickers posted, per axis and per grant key, ignoring anything
  without a recognized mode. `values` is `nil` when no list was posted for it
  (the list is only rendered in "only" mode), which reads as "the stored list".
  """
  @spec picks(map()) :: picks()
  def picks(%{} = params) do
    %{
      editable_types: axis_pick(params, :editable_types),
      readable_types: axis_pick(params, :readable_types),
      field_grants: grant_picks(params, "grant_mode", "grant_fields"),
      field_read_grants: grant_picks(params, "grant_read_mode", "grant_read_fields")
    }
  end

  @doc """
  `picked` merged onto `stored`: the stored list itself when the two hold the
  same names, otherwise the stored order of what is still picked followed by
  the new picks in the order they arrived.
  """
  @spec merge_list([String.t()], [String.t()]) :: [String.t()]
  def merge_list(stored, picked) do
    picked = Enum.uniq(picked)

    if MapSet.new(stored) == MapSet.new(picked) do
      stored
    else
      Enum.filter(stored, &(&1 in picked)) ++ (picked -- stored)
    end
  end

  # --- type axes ---------------------------------------------------------------

  defp axis_pick(params, axis) do
    {mode_key, list_key} = Map.fetch!(@axis_params, axis)

    case Map.get(params, mode_key) do
      mode when mode in @type_modes -> %{mode: mode, values: values(Map.get(params, list_key))}
      _absent_or_unknown -> nil
    end
  end

  defp axis(picks, stored, axis, errors) do
    stored_list = Map.fetch!(stored, axis)

    case Map.fetch!(picks, axis) do
      nil ->
        {stored_list, errors}

      %{mode: "all"} ->
        {[], errors}

      %{mode: "only", values: values} ->
        case merge_list(stored_list, values || stored_list) do
          [] -> {stored_list, Map.put(errors, axis, :none_picked)}
          list -> {list, errors}
        end
    end
  end

  # --- field grants ------------------------------------------------------------

  defp grant_picks(params, mode_key, fields_key) do
    modes = map_param(params, mode_key)
    types = map_param(params, "grant_type")
    fields = map_param(params, fields_key)

    modes
    |> Enum.sort_by(fn {index, _mode} -> {String.length(to_string(index)), index} end)
    |> Enum.reduce(%{}, fn {index, mode}, acc ->
      case Map.get(types, index) do
        key when mode in @grant_modes and is_binary(key) and key != "" ->
          Map.put(acc, key, %{mode: mode, values: values(Map.get(fields, index))})

        _ ->
          acc
      end
    end)
  end

  defp grants(picks, stored, errors) do
    Enum.reduce(picks, {stored, errors}, fn {key, pick}, {grants, errors} ->
      case grant(pick, Map.get(stored, key)) do
        :delete -> {Map.delete(grants, key), errors}
        {:ok, fields} -> {Map.put(grants, key, fields), errors}
        :none_picked -> {grants, Map.put(errors, {:grant, key}, :none_picked)}
      end
    end)
  end

  defp read_grants(picks, stored, errors) do
    Enum.reduce(picks, {stored, errors}, fn {key, pick}, {grants, errors} ->
      case grant(pick, Map.get(stored, key)) do
        :delete -> {Map.delete(grants, key), errors}
        {:ok, fields} -> {Map.put(grants, key, fields), errors}
        :none_picked -> {grants, Map.put(errors, {:read_grant, key}, :none_picked)}
      end
    end)
  end

  defp grant(%{mode: "any"}, _stored), do: :delete
  defp grant(%{mode: "none"}, _stored), do: {:ok, []}

  defp grant(%{mode: "only", values: values}, stored) do
    stored = if is_list(stored), do: stored, else: []

    case merge_list(stored, values || stored) do
      [] -> :none_picked
      fields -> {:ok, fields}
    end
  end

  # --- param shapes ------------------------------------------------------------

  # A checkbox list arrives as a list behind its `""` sentinel. Any other
  # shape is not one this page renders, so it reads as "not posted".
  defp values(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: Enum.reject(list, &(&1 == "")), else: nil
  end

  defp values(_other), do: nil

  defp map_param(params, key) do
    case Map.get(params, key) do
      %{} = map -> map
      _ -> %{}
    end
  end
end
