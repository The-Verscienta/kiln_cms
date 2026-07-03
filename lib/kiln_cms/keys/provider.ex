defmodule KilnCMS.Keys.Provider do
  @moduledoc """
  Where a named secret's material lives (`KilnCMS.Keys`).

  Modeled on Drupal's Key module: the CMS stores *metadata* (which provider,
  provider config, the non-secret public half), while the secret itself lives
  wherever the provider points — an environment variable, a file (e.g. a
  mounted Docker/K8s secret), or encrypted in the database. Consumers resolve
  secrets through `KilnCMS.Keys.fetch/1` and never store them.

  `config` is the persisted provider config map (string keys — it round-trips
  through a Postgres `:map` column), e.g. `%{"var" => "DKIM_PRIVATE_KEY"}`.
  """

  @doc "Resolve the secret material."
  @callback fetch(config :: map()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Whether the app can write key material to this provider — i.e. whether the
  admin UI offers *generate/rotate* (database) rather than a *point-at-source*
  input (env/file).
  """
  @callback writable?() :: boolean()
end
