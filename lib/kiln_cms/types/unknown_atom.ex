defmodule KilnCMS.Types.UnknownAtom do
  @moduledoc """
  A stored atom-column value this release does not know (#2509).

  `KilnCMS.Types.KnownAtom` loads a value as this struct when it is not one of
  the column's `one_of` values, or names no atom at all: typically a row a
  newer release wrote (a new security event type, a new notification event)
  read by an older one during a rolling deploy or after a rollback. Turning
  the text into an atom would mean creating atoms from database strings (atom
  exhaustion), and refusing it failed every read that met the row, so one
  unknown row took down a whole list, its export, and the erasure sweep.

  It keeps the stored text in `value`, renders and encodes as that text, dumps
  back to it unchanged, and equals no atom, so a `case` on the known values
  falls through to its catch-all. Same idea as `KilnCMS.CMS.OrphanedContentType`
  (#1770).
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  defimpl String.Chars do
    def to_string(%{value: value}), do: value
  end

  defimpl Jason.Encoder do
    def encode(%{value: value}, opts), do: Jason.Encode.string(value, opts)
  end

  # Escaped like any string: the text came from the database, not from code.
  defimpl Phoenix.HTML.Safe do
    def to_iodata(%{value: value}), do: Phoenix.HTML.Engine.html_escape(value)
  end
end
