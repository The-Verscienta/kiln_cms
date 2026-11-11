defmodule Kiln.Plugins.Health.Notice do
  @moduledoc """
  A security notice that may concern an installed plugin (#2244).

  Two sources produce these:

    * `:kiln` — a `security_notice` entry on kilncms.dev (#1873). `affected`
      is its version-range text (`">= 1.0.0, < 1.3.2; >= 2.0.0 and < 2.1.1"`
      or the literal `"unknown"`), matched by
      `Kiln.Plugins.Health.Evaluate.affected?/2`. The feed publishes
      first-party advisories only (The-Verscienta/kiln_cms and its plugins).
    * `:hex` — an advisory Hex lists on the installed *release*, so it already
      applies to that version; `affected` is kept for display only.

  `patched` is the feed's `patched_versions` text as published (`"1.3.2;
  1.2.4"`, or `"unknown"`), `nil` when absent; Hex notices have none.

  `id` is the advisory id; `aliases` holds the other ids it is known by (CVE,
  GHSA), so the same advisory reported by both sources is shown once.
  """

  @enforce_keys [:id, :source]
  defstruct [
    :id,
    :title,
    :affected,
    :patched,
    :url,
    :source,
    packages: [],
    aliases: [],
    severity: :unknown
  ]

  @type severity :: :low | :medium | :high | :critical | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          packages: [String.t()],
          aliases: [String.t()],
          affected: String.t() | nil,
          patched: String.t() | nil,
          severity: severity(),
          url: String.t() | nil,
          source: :kiln | :hex
        }

  @doc "Every id this notice is known by, downcased, for de-duplication."
  @spec ids(t()) :: [String.t()]
  def ids(%__MODULE__{id: id, aliases: aliases}),
    do: [id | aliases] |> Enum.reject(&is_nil/1) |> Enum.map(&String.downcase/1)
end
