defmodule KilnCMS.CMS.Types.StoredContentType do
  @moduledoc """
  `:atom`, except that a stored name with no existing atom loads as a
  `KilnCMS.CMS.OrphanedContentType` instead of failing the read (#1770).

  The type of `KilnCMS.CMS.FieldDefinition.content_type`. Storage is unchanged
  (text, as `:atom` stores it), so no migration comes with it, and input casts
  exactly as `:atom` does — an unknown name is still refused on write, and
  `Validations.KnownContentType` still requires a registered type. Only the
  read side is tolerant: `String.to_existing_atom/1` or the orphan marker,
  never a new atom.
  """
  use Ash.Type.NewType, subtype_of: :atom

  alias KilnCMS.CMS.OrphanedContentType

  @impl Ash.Type
  def cast_stored(value, constraints) when is_binary(value) do
    case super(value, constraints) do
      {:ok, atom} -> {:ok, atom}
      _unknown -> {:ok, %OrphanedContentType{name: value}}
    end
  end

  def cast_stored(value, constraints), do: super(value, constraints)

  # A loaded orphan passes back through a changeset untouched (it is what the
  # record already holds); `Validations.KnownContentType` then refuses to save
  # it. No other shape is new.
  @impl Ash.Type
  def cast_input(%OrphanedContentType{} = orphan, _constraints), do: {:ok, orphan}
  def cast_input(value, constraints), do: super(value, constraints)

  @impl Ash.Type
  def dump_to_native(%OrphanedContentType{name: name}, _constraints), do: {:ok, name}
  def dump_to_native(value, constraints), do: super(value, constraints)

  @impl Ash.Type
  def dump_to_embedded(%OrphanedContentType{name: name}, _constraints), do: {:ok, name}
  def dump_to_embedded(value, constraints), do: super(value, constraints)
end
