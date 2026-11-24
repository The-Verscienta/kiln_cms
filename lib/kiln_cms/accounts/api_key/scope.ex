defmodule KilnCMS.Accounts.ApiKey.Scope do
  @moduledoc """
  The `access` scopes this release knows (#2604).

  `KilnCMS.Accounts.ApiKey.access` is a `KilnCMS.Types.KnownAtom`, so a scope a
  newer release wrote loads here as a `KilnCMS.Types.UnknownAtom` instead of
  failing the read. Such a key must authenticate as nothing:
  `User.valid_api_keys` admits only the scopes listed here, and that filter is
  the sole gate. The content policies do not refuse an unknown scope on reads.

  A plain module, not a function on the resource, so that `User`'s DSL can
  call it at compile time without depending on `ApiKey`. Keep it that way: it
  must not alias, use or match anything that reaches `ApiKey`.
  """

  @known [:read, :read_write, :draft_write]

  @doc "Every scope this release knows, in the order the console offers them."
  @spec known() :: [atom()]
  def known, do: @known

  @doc "Whether `access` is a scope this release knows."
  @spec known?(term()) :: boolean()
  def known?(access), do: access in @known
end
