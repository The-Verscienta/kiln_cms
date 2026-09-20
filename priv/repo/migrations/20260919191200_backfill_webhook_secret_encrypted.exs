defmodule KilnCMS.Repo.Migrations.BackfillWebhookSecretEncrypted do
  @moduledoc """
  Data migration — **step 2 of 3** of encrypting webhook signing secrets at
  rest.

    1. `encrypt_webhook_secrets` — adds the nullable `secret_encrypted` column
       and relaxes `secret` to nullable.
    2. *this migration* — encrypts every plaintext `secret` into
       `secret_encrypted` with `KilnCMS.Keys.Vault` and clears the plaintext.
    3. `drop_webhook_plaintext_secret` — drops `secret` and makes
       `secret_encrypted` required.

  Idempotent (`WHERE secret_encrypted IS NULL`). Hand-written *data*
  migration — Ash owns the schema, but a backfill can't be generated.

  The vault key is derived from `secret_key_base`, which is configured by the
  time migrations run (`mix ecto.migrate` loads the app config; a release's
  `KilnCMS.Release.migrate/0` runs after `runtime.exs`). Its key cache is an
  ETS table owned by `:plug_crypto`, which a migration run does not otherwise
  start — hence the `ensure_all_started`.

  `down/0` decrypts back into `secret`. A value the current `secret_key_base`
  cannot open is left encrypted rather than guessed at.
  """
  use Ecto.Migration

  import Ecto.Query

  alias KilnCMS.Keys.Vault

  def up do
    {:ok, _apps} = Application.ensure_all_started(:plug_crypto)

    rows =
      repo().all(
        from(e in "webhook_endpoints",
          where: is_nil(e.secret_encrypted) and not is_nil(e.secret),
          select: {e.id, e.secret}
        )
      )

    for {id, secret} <- rows do
      repo().update_all(
        from(e in "webhook_endpoints", where: e.id == ^id),
        set: [secret_encrypted: Vault.encrypt(secret), secret: nil]
      )
    end
  end

  def down do
    {:ok, _apps} = Application.ensure_all_started(:plug_crypto)

    rows =
      repo().all(
        from(e in "webhook_endpoints",
          where: is_nil(e.secret) and not is_nil(e.secret_encrypted),
          select: {e.id, e.secret_encrypted}
        )
      )

    for {id, encrypted} <- rows, {:ok, secret} <- [Vault.decrypt(encrypted)] do
      repo().update_all(
        from(e in "webhook_endpoints", where: e.id == ^id),
        set: [secret: secret, secret_encrypted: nil]
      )
    end
  end
end
