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
  Verify the source is usable (readable, well-formed PEM) without returning
  the secret — for settings-page feedback.
  """
  @callback check(config :: map()) :: :ok | {:error, term()}

  @doc "Whether the app can write key material to this provider (UI generate/rotate)."
  @callback writable?() :: boolean()
end
