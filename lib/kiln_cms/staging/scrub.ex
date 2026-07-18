defmodule KilnCMS.Staging.Scrub do
  @moduledoc """
  Turns a production **clone** into a safe-to-share staging environment by
  removing personal data and outbound secrets. The one place that decides "this
  copy is safe to run somewhere less locked-down than production."

  It reuses the existing privacy work rather than re-deciding what counts as
  personal data: user accounts go through the GDPR-erasure `:anonymize` action
  (`docs/data-flows.md`), and the rest are whole-table purges / de-activations
  of the same data the retention jobs already treat as sensitive.

  Everything here is a purge or a de-activation — it never sends mail, fires a
  webhook, or contacts a subprocessor. See `KilnCMS.Staging.scrub!/1` for the
  guarded, operator-facing entry point and `docs/staging-environments.md` for
  the full flow.

  > This is destructive by design. It must only run against a throwaway clone,
  > never production — the guards live in `KilnCMS.Staging.scrub!/1`.
  """
  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo

  @type summary :: %{
          users_anonymized: non_neg_integer(),
          api_keys_purged: non_neg_integer(),
          tokens_purged: non_neg_integer(),
          webhooks_deactivated: non_neg_integer(),
          mail_settings_purged: non_neg_integer(),
          search_queries_purged: non_neg_integer(),
          admin_provisioned: String.t() | nil
        }

  @doc """
  Scrub the database the repo is currently connected to. Returns a summary map
  of what was removed.

  ## Options

    * `:admin_email` / `:admin_password` — provision one usable staging admin
      after anonymizing every real account. Both must be present or no admin is
      seeded (and you won't be able to sign in to staging).

  Callers are responsible for the safety guards; use `KilnCMS.Staging.scrub!/1`
  unless you have already confirmed the target.
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    users_anonymized = anonymize_users()

    # Whole-table purges / de-activations run at the repo level on purpose: they
    # are system-level scrubs that bypass policies (there is no acting user), and
    # doing them as data-only writes avoids per-row side effects — e.g. the
    # webhook update action would re-run its SSRF/DNS validation, which is both
    # slow and pointless when we only want the rows switched off.
    {api_keys_purged, _} = Repo.delete_all(KilnCMS.Accounts.ApiKey)
    {tokens_purged, _} = Repo.delete_all(KilnCMS.Accounts.Token)
    {mail_settings_purged, _} = Repo.delete_all(KilnCMS.Mail.Settings)
    {search_queries_purged, _} = Repo.delete_all(KilnCMS.Analytics.SearchQuery)

    {webhooks_deactivated, _} =
      Repo.update_all(
        from(e in KilnCMS.CMS.WebhookEndpoint, where: e.active == true),
        set: [active: false, auto_disabled_at: DateTime.utc_now()]
      )

    admin_provisioned = maybe_provision_admin(opts[:admin_email], opts[:admin_password])

    %{
      users_anonymized: users_anonymized,
      api_keys_purged: api_keys_purged,
      tokens_purged: tokens_purged,
      webhooks_deactivated: webhooks_deactivated,
      mail_settings_purged: mail_settings_purged,
      search_queries_purged: search_queries_purged,
      admin_provisioned: admin_provisioned
    }
  end

  # Anonymize every account that isn't already scrubbed, via the real GDPR
  # erasure action (scrambles credentials, revokes tokens, nulls audit actors —
  # `KilnCMS.Accounts.Changes.AnonymizeUser`). Runs as a system job (no actor),
  # so it bypasses the admin-only policy that guards the action at runtime.
  defp anonymize_users do
    Accounts.list_users!(authorize?: false)
    |> Enum.reject(& &1.anonymized_at)
    |> Enum.map(&Accounts.anonymize_user!(&1, authorize?: false))
    |> length()
  end

  # Seed one pre-confirmed admin so the scrubbed environment is usable. Safe to
  # do as a plain `Ash.Seed` (mirroring priv/repo/seeds.exs): it runs *after*
  # anonymization, so every real email is already a tombstone and this address
  # is guaranteed free.
  defp maybe_provision_admin(email, password)
       when is_binary(email) and is_binary(password) and email != "" and password != "" do
    Ash.Seed.seed!(User, %{
      email: email,
      name: "Staging Admin",
      hashed_password: Bcrypt.hash_pwd_salt(password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    email
  end

  defp maybe_provision_admin(_email, _password), do: nil
end
