defmodule Kiln.Advisory.Finding do
  @moduledoc """
  One advisory observation.

  Carries a `code` and interpolation `args`, never a sentence — the prose lives
  in the web layer so checks stay free of Gettext and the same finding renders
  in every locale. See `Kiln.Advisory`.
  """

  @type severity :: :error | :warning | :info

  @type t :: %__MODULE__{
          code: atom(),
          severity: severity(),
          field: atom(),
          args: map()
        }

  @enforce_keys [:code, :severity]
  defstruct [:code, :severity, field: :body, args: %{}]

  @doc """
  Block positions this finding points at, if any, capped for display.

  Findings that name specific blocks (images missing alt text) carry
  `args.indexes`; the editor turns them into jump links. Capped so a gallery
  with fifty un-alt'd images doesn't render fifty links into a sidebar.
  """
  @spec block_indexes(t(), pos_integer()) :: [non_neg_integer()]
  def block_indexes(%__MODULE__{args: %{indexes: indexes}}, max) when is_list(indexes),
    do: Enum.take(indexes, max)

  def block_indexes(_finding, _max), do: []
end
