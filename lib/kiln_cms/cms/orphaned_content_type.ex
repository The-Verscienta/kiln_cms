defmodule KilnCMS.CMS.OrphanedContentType do
  @moduledoc """
  A stored content-type name this VM no longer knows (#1770).

  `KilnCMS.CMS.FieldDefinition.content_type` is persisted as text and read back
  as an atom. A fresh database can only hold names of registered types —
  `Validations.KnownContentType` refuses anything else on write — but an
  upgraded one can hold a name whose type has since gone: a removed plugin, a
  renamed or deleted compiled type, a row left over from early dynamic-type
  testing. When no atom of that name exists, turning it back into one would
  mean creating atoms from database strings, which is off the table (atom
  exhaustion). Refusing the row instead crashed every read that met it, so one
  stale definition took the whole Fields screen down.

  So such a name loads as this struct instead: it keeps the stored name for
  display and deletion, dumps back to the same text, and matches no type —
  `KilnCMS.CMS.ContentTypes.get/2` answers `nil` for it rather than looking the
  bare string up as a *dynamic* type name, which would aim the definition at an
  unrelated type. `KilnCMS.CMS.FieldDefinition.orphaned?/1` is the question
  callers ask; it also covers a name that is still an atom but no longer a
  registered type.
  """

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}

  defimpl String.Chars do
    def to_string(%{name: name}), do: name
  end

  defimpl Jason.Encoder do
    def encode(%{name: name}, opts), do: Jason.Encode.string(name, opts)
  end
end
