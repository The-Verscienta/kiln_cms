defmodule KilnCMS.KnownAtomEmbedded do
  @moduledoc """
  A test-only embedded resource with `KilnCMS.Types.KnownAtom` attributes:
  how a D3 JSON tree reads a value a newer release stored (#2509).
  Here rather than in the test file so it compiles before protocols
  consolidate.
  """
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, create: :*]
  end

  attributes do
    attribute :kind, KilnCMS.Types.KnownAtom,
      public?: true,
      constraints: [one_of: [:alpha, :beta]]

    attribute :kinds, {:array, KilnCMS.Types.KnownAtom},
      public?: true,
      constraints: [items: [one_of: [:alpha, :beta]]]
  end
end
