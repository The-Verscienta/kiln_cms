defmodule KilnCMS.Provenance.GenerateKeyWorker do
  @moduledoc """
  Generates the instance's content-signing key on the node that runs it, when
  provenance is on and no key resolves (#2974).

  Queued by the staging scrub (`KilnCMS.Staging.Scrub`) after it removes
  production's generated key, as the last thing the scrub does. The scrub
  itself can't generate the replacement: the key is sealed under the
  `SECRET_KEY_BASE` of whoever generates it (`KilnCMS.Keys.Vault`), and the
  scrub often runs with production's (`bin/kiln_cms eval` on the production
  host), which the staging application does not have. The job runs on the
  staging application's own Oban, under its own `SECRET_KEY_BASE`, so staging
  signs from its first minutes with a key it can read, without anyone having
  to press "Generate" on the overview.

  Does nothing when a key already resolves: one the staging application
  mounts (`KILN_PROVENANCE_KEY_FILE` / `KILN_PROVENANCE_PRIVATE_KEY`), or one
  generated since. `max_attempts: 3` covers a database blip at boot; past
  that the overview's "Generate" button does the same thing.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias KilnCMS.Provenance

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Provenance.enabled?() and not Provenance.key_available?() do
      # authorize?: false — `:generate` is platform-admin only and a job has
      # no actor. Safe: it takes no input, writes only the instance's own key,
      # and only when none resolves; the singleton identity refuses a second
      # row, so it can never replace a key that exists.
      case KilnCMS.Firing.generate_provenance_key(authorize?: false) do
        {:ok, _settings} ->
          Provenance.forget_stored_key()
          :ok

        {:error, error} ->
          {:error, error}
      end
    else
      :ok
    end
  end
end
