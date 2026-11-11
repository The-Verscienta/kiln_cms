defmodule KilnCMS.CMS.FieldAccess do
  @moduledoc """
  The pure vocabulary of per-custom-field grants (#2281): what a `field_grants`
  or `field_read_grants` entry for a type can name, and who may write or read
  which custom field given a list of them.

  Entries are dotted keys, spelled the way `custom_fields` itself is:

    * `custom_fields` — every custom field (the original, whole-attribute grant);
    * `custom_fields.<name>` — one top-level field;
    * `custom_fields.<group>` — a whole `:group` field, rows added, removed and
      reordered included (the same shape as `<name>`, told apart by the
      definitions, not the syntax);
    * `custom_fields.<group>.<sub>` — one sub-field, in every row.

  A field name matches `\\A[a-z][a-z0-9_]*\\z`, so a dot is unambiguous. Link
  fields (details on a reference's connections) are not grantable on their own:
  they ride on their parent. Computed fields are never written by anyone.

  A *path* is the list of names an entry addresses: `["name"]` or
  `["group", "sub"]`.

  ## Write

  A write grant is the list of entries for a type, or `nil` for "no
  restriction". `writable?/2` is plain membership: the bare entry, the field's
  own entry, or (for a sub-field) its group's entry.

  ## Read

  A read grant restricts which *private* fields an editor sees
  (`field_read_grants`): `nil` is unrestricted, a list names the private fields
  that stay visible (`custom_fields` for all of them, `custom_fields.<name>`
  for one) and `[]` hides every private field. A write grant on a field implies
  reading it. A field that is not `private: true` is never hidden — it is
  world-readable on published content, so hiding it from one role would be
  theatre; `hidden_names/3` simply ignores it.
  """

  @prefix "custom_fields"
  @name ~r/\A[a-z][a-z0-9_]*\z/

  @type grant :: [String.t()] | nil
  @type path :: [String.t()]
  @type parsed ::
          :all
          | {:field, String.t()}
          | {:sub, String.t(), String.t()}
          | :other
          | :invalid

  @doc """
  Classifies one grant entry: `:all` for the bare key, `{:field, name}`,
  `{:sub, group, sub}`, `:other` for any entry that is not about custom fields
  (`"title"`), and `:invalid` for a `custom_fields...` entry that does not
  parse (`"custom_fields."`, `"custom_fields.A"`, `"custom_fields.a.b.c"`).
  """
  @spec parse(term()) :: parsed()
  def parse(@prefix), do: :all

  def parse(@prefix <> "." <> rest) do
    case String.split(rest, ".") do
      [name] ->
        if valid_name?(name), do: {:field, name}, else: :invalid

      [group, sub] ->
        if valid_name?(group) and valid_name?(sub), do: {:sub, group, sub}, else: :invalid

      _more ->
        :invalid
    end
  end

  def parse(@prefix <> _other), do: :invalid
  def parse(entry) when is_binary(entry), do: :other
  def parse(_entry), do: :invalid

  defp valid_name?(name), do: Regex.match?(@name, name)

  @doc """
  The key for `path`: `["a"]` is `"custom_fields.a"`.
  """
  @spec key(path()) :: String.t()
  def key(path), do: Enum.join([@prefix | path], ".")

  @doc """
  True when the grant holds at least one `custom_fields.*` entry: the editor is
  held to named custom fields rather than all-or-nothing. A `nil` grant, or one
  with only the bare `custom_fields` key, is not per-key.
  """
  @spec per_key?(grant()) :: boolean()
  def per_key?(grant) when is_list(grant), do: Enum.any?(grant, &named?(parse(&1)))

  def per_key?(_grant), do: false

  defp named?({:field, _name}), do: true
  defp named?({:sub, _group, _sub}), do: true
  defp named?(_parsed), do: false

  @doc """
  May the editor holding write `grant` write the field at `path`?

  `nil` is unrestricted. Otherwise the bare `custom_fields`, the field's own
  entry, or — for a sub-field — its group's entry.
  """
  @spec writable?(grant(), path()) :: boolean()
  def writable?(nil, _path), do: true

  def writable?(grant, path) when is_list(grant) do
    @prefix in grant or key(path) in grant or
      case path do
        [group, _sub] -> key([group]) in grant
        _single -> false
      end
  end

  @doc """
  May the editor read the (private) field at `path`, given their `read` grant
  and `write` grant? A `nil` read grant is unrestricted; a write grant on the
  field implies reading it.
  """
  @spec readable?(grant(), grant(), path()) :: boolean()
  def readable?(nil, _write, _path), do: true

  def readable?(read, write, path) when is_list(read) do
    @prefix in read or key(path) in read or (is_list(write) and writable?(write, path))
  end

  @doc """
  The names of the private fields among `definitions` that an editor holding
  `read` and `write` grants may not see. `[]` when `read` is `nil`.

  Only top-level, `private: true` definitions can be hidden: a private field is
  always a plain scalar (`KilnCMS.CMS.PrivateFields.types/0`).
  """
  @spec hidden_names([map()], grant(), grant()) :: [String.t()]
  def hidden_names(_definitions, nil, _write), do: []

  def hidden_names(definitions, read, write) when is_list(read) do
    for %{private: true, name: name} = definition <- definitions,
        top_level?(definition),
        not readable?(read, write, [name]),
        do: name
  end

  @doc """
  Is `entry` a legal read-grant entry for a type holding `definitions`? Only
  the bare key, or `custom_fields.<name>` for a *private* definition (a stale
  name is accepted: the picker shows it as "(not found)").
  """
  @spec valid_read_entry?(String.t(), [map()]) :: boolean()
  def valid_read_entry?(entry, definitions) do
    case parse(entry) do
      :all ->
        true

      {:field, name} ->
        case Enum.find(definitions, &(&1.name == name and top_level?(&1))) do
          nil -> true
          definition -> definition.private == true
        end

      _other ->
        false
    end
  end

  @doc "The syntax-only form of `valid_read_entry?/2`, for the write-time shape check."
  @spec read_entry_shape?(term()) :: boolean()
  def read_entry_shape?(entry), do: parse(entry) in [:all] or match?({:field, _}, parse(entry))

  defp top_level?(definition),
    do: is_nil(Map.get(definition, :link_of_id)) and is_nil(Map.get(definition, :group_of_id))
end
