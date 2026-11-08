defmodule KilnCMS.Accounts.SignOutAll do
  @moduledoc """
  "Sign out everyone" on one site (#2246): `KilnCMS.CMS.SiteSessionPolicy`'s
  `:sign_out_all`, authorized there as an org admin of the tenant.

  In one transaction it:

    1. revokes every session, remember-me cookie and held two-factor sign-in
       bound to the site (`KilnCMS.Accounts.Sessions.revoke_org/2`), except the
       caller's own browser when asked;
    2. writes the site's watermark (`sessions_revoked_at`), which signs out a
       session bound to no site — signed in before sessions recorded one, or
       held at the two-factor prompt — the next time it is used here;
    3. records `:all_sessions_revoked` in the site's security log.

  Once it commits, each revoked session's open pages are sent to sign-in
  (`SessionEviction.evict_sessions/2`, one message per session — never the
  per-user topic, which would reach the account's sessions on other sites).

  It reaches this site only. A session on another site is bound to that site,
  or, bound to none, is caught only on this site's host. API keys and bearer
  JWTs are not sessions and are untouched: a compromised account needs a
  password reset or "Sign out everywhere" on the account itself.

  ## Keeping the caller signed in

  `except_session_jti` names the browser to keep. It must be one of the
  caller's own live sessions, used on this site (or bound to none yet);
  anything else is refused and nothing is revoked. That session and the
  remember-me cookie issued with it are kept, and bound to this site so the
  watermark does not catch them.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.Token
  alias KilnCMS.AfterCommit
  alias KilnCMS.Repo
  alias KilnCMS.Security.Recorder

  @impl true
  def run(input, _opts, context) do
    case context.tenant do
      nil ->
        {:error, "sign_out_all needs a tenant: pass `tenant:` the site to sign everyone out of"}

      tenant ->
        org_id = Ash.ToTenant.to_tenant(tenant, input.resource)
        except = input.arguments[:except_session_jti]

        with {:ok, keep} <- keep(context.actor, except, org_id) do
          sign_out(org_id, keep, except, context)
        end
    end
  end

  defp keep(_actor, nil, _org_id), do: {:ok, []}

  defp keep(actor, jti, org_id) when is_binary(jti) do
    subject = actor && AshAuthentication.user_to_subject(actor)

    # authorize?: false — a system read of one token row by jti, to check
    # below that it is the caller's own live session on this site.
    case Accounts.get_session_activity(jti, authorize?: false, not_found_error?: false) do
      {:ok, %Token{purpose: "user", subject: ^subject, org_id: row_org} = row}
      when is_binary(subject) and row_org in [nil, org_id] ->
        {:ok, [row.jti | List.wrap(row.remember_me_jti)]}

      _not_yours ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :except_session_jti,
           message: "is not one of your sessions on this site"
         )}
    end
  end

  defp sign_out(org_id, keep, except, context) do
    result =
      AfterCommit.deferring(fn ->
        Repo.transaction(fn -> in_transaction(org_id, keep, except, context) end)
      end)

    case result do
      {:ok, count} -> {:ok, count}
      {:error, error} -> {:error, error}
    end
  end

  defp in_transaction(org_id, keep, except, context) do
    # The kept browser first: bound to this site, the watermark below passes
    # it by.
    if keep != [],
      do: Sessions.bind_to_site(keep, org_id, AshAuthentication.user_to_subject(context.actor))

    with {:ok, sessions, _others} <- Sessions.revoke_org(org_id, keep),
         {:ok, _row} <- stamp_watermark(org_id),
         {:ok, _event} <- record(org_id, length(sessions), except, context) do
      jtis = Enum.map(sessions, & &1.jti)
      AfterCommit.run(fn -> SessionEviction.evict_sessions(jtis, :admin_sign_out_all) end)
      length(sessions)
    else
      {:error, error} -> Repo.rollback(error)
      :skipped -> Repo.rollback(:not_recorded)
    end
  end

  defp stamp_watermark(org_id) do
    # authorize?: false — the watermark is written only here, after
    # `sign_out_all` authorized the caller as an admin of this tenant; the
    # action refuses every direct caller by name.
    KilnCMS.CMS.record_sessions_revoked(%{at: DateTime.utc_now()},
      tenant: org_id,
      authorize?: false,
      context: AfterCommit.context()
    )
  end

  defp record(org_id, count, except, context) do
    request = Map.get(context.source_context || %{}, Recorder.context_key())

    Recorder.record(:all_sessions_revoked,
      tenant: org_id,
      user: context.actor,
      target_type: "organization",
      target_id: org_id,
      metadata: %{
        "count" => Integer.to_string(count),
        "except_self" => to_string(is_binary(except))
      },
      request: request
    )
  end
end
