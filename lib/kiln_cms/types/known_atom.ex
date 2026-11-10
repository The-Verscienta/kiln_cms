defmodule KilnCMS.Types.KnownAtom do
  @moduledoc """
  `:atom`, except that a stored value this release does not know loads as a
  `KilnCMS.Types.UnknownAtom` instead of failing the read (#2509).

  For a closed-vocabulary column a later release may add values to: an
  `:atom` column with `one_of`. Plain `:atom` turns stored text back into an
  atom with `String.to_existing_atom/1` and fails the whole read when there is
  none; and when there is one (any atom the VM happens to hold) it loads it
  even if it is outside `one_of`, which only applies to input. So a row a newer
  release wrote broke every read that met it on an older one: a rolling deploy,
  or a rollback.

  Read side, for a column (`cast_stored/2`) and inside an embedded resource
  (`cast_from_embedded/2`), single or `{:array, KnownAtom}`: a stored value
  that is in `one_of` (or any existing atom, when the attribute has no
  `one_of`) loads as that atom; anything else loads as
  `%UnknownAtom{value: text}`. Never `String.to_atom/1`: no atom is created
  from database text.

  Write side: unchanged and strict. Input casts exactly as `:atom` does, and
  `one_of` is still applied, so an unknown name is refused. An `UnknownAtom`
  is refused as input too, on purpose and unlike
  `KilnCMS.CMS.Types.StoredContentType`: the columns using this type are only
  ever written with a value the writing code chose, never round-tripped from
  a loaded record, so a struct arriving as input is a bug to surface. Writes
  that leave the column alone (an erasure scrub, marking a notification read)
  never cast it and keep working on such a row.

  Storage is text, as `:atom` stores it: switching a column to this type needs
  no migration.
  """
  use Ash.Type.NewType, subtype_of: :atom

  alias KilnCMS.Types.UnknownAtom

  @impl Ash.Type
  def cast_stored(value, constraints), do: tolerant(value, constraints)

  # An embedded resource (a D3 JSON tree) reads its attributes through this
  # rather than `cast_stored/2`, and `Ash.Type.NewType` hands it straight to
  # `:atom`, where an unknown value fails the whole tree's read. Same rule as
  # a column. `{:array, KnownAtom}` casts each item through here too.
  @impl Ash.Type
  def cast_from_embedded(value, constraints), do: tolerant(value, constraints)

  @impl Ash.Type
  def dump_to_native(%UnknownAtom{value: value}, _constraints), do: {:ok, value}
  def dump_to_native(value, constraints), do: super(value, constraints)

  @impl Ash.Type
  def dump_to_embedded(%UnknownAtom{value: value}, _constraints), do: {:ok, value}
  def dump_to_embedded(value, constraints), do: super(value, constraints)

  # Never `String.to_atom/1`: `:atom`'s own cast with `unsafe_to_atom?` forced
  # off, so a name with no atom stays text. An atom (a caller may hand one
  # over) goes through the same `one_of` test as a name.
  defp tolerant(nil, _constraints), do: {:ok, nil}

  defp tolerant(value, constraints) when is_binary(value) do
    safe = Keyword.put(constraints, :unsafe_to_atom?, false)

    case Ash.Type.cast_stored(Ash.Type.Atom, value, safe) do
      {:ok, atom} when is_atom(atom) -> {:ok, known(atom, value, constraints)}
      _no_such_atom -> {:ok, %UnknownAtom{value: value}}
    end
  end

  defp tolerant(value, constraints) when is_atom(value),
    do: {:ok, known(value, Atom.to_string(value), constraints)}

  defp tolerant(%UnknownAtom{} = unknown, _constraints), do: {:ok, unknown}
  defp tolerant(_value, _constraints), do: :error

  # An atom outside `one_of` is as unknown as one that does not exist: the code
  # handling this column has no clause for it either. (A stored `NULL` never
  # reaches here; it arrives as `nil`, not as text.)
  defp known(atom, value, constraints) do
    case constraints[:one_of] do
      nil -> atom
      one_of -> if atom in one_of, do: atom, else: %UnknownAtom{value: value}
    end
  end
end
