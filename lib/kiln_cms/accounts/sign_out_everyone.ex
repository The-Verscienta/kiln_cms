defmodule KilnCMS.Accounts.SignOutEveryone do
  @moduledoc """
  "Sign out everyone on every site" (#2491): `KilnCMS.Accounts.InstanceSessions`'s
  `:sign_out_everyone`, authorized there as a platform admin.

  An incident tool for the whole installation. Where a site's own "Sign out
  everyone" (`KilnCMS.Accounts.SignOutAll`) reaches the rows bound to that
  site and leaves a watermark for the rest, this names and revokes every row
  in one transaction, so there is no watermark to leave:

    1. compares the typed `confirmation` with `phrase/0` (trimmed, any case);
       a mismatch revokes nothing and records nothing;
    2. revokes every unexpired session, remember-me cookie and held two-factor
       sign-in of every account, on every site and on none — sessions from
       before sessions recorded a site, and headless app tokens
       (`POST /api/auth/sign_in`) included
       (`KilnCMS.Accounts.Sessions.revoke_everywhere/1`), except the caller's
       own browser when asked;
    3. records `:all_sessions_revoked_everywhere` in the **instance** security
       log (`KilnCMS.Security.InstanceEvent`), which only platform admins
       read. A write that fails, or is skipped
       (`KilnCMS.Accounts.Errors.SignOutNotRecorded`), rolls the revocation
       back.

  The rows are locked before they are written, in the order a session in use
  locks them, so a session used meanwhile waits rather than deadlocking the
  sign-out. Each statement may take `Sessions.revoke_timeout/0`; past it the
  whole sign-out rolls back with an `Ash.Error.Invalid.Timeout`.

  Once it commits, each revoked session's open pages are sent to sign-in and
  its collab and `/ws/gql` sockets are closed
  (`SessionEviction.evict_sessions/2`, one message per session), in a task
  off the request (inline under test, `:async_analytics` off).

  API keys are another resource and are untouched; so are password-reset,
  confirmation and magic-link tokens, which have purposes of their own.

  ## Keeping the caller signed in

  `except_session_jti` names the browser to keep: one of the caller's own
  live sessions, on any site. Anything else is refused and nothing is
  revoked. That session and the remember-me cookie issued with it are kept.
  Cookies are per host, so the caller's sessions on other sites' hosts end.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.SignOutNotRecorded
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.Token
  alias KilnCMS.AfterCommit
  alias KilnCMS.Repo
  alias KilnCMS.Security.Recorder

  @doc """
  The phrase a platform admin types to confirm: the instance's main host
  (the endpoint URL's host, `PHX_HOST`), lowercased. Not translated: it names
  the installation, so typing it on staging cannot sign out production.
  """
  @spec phrase() :: String.t()
  def phrase, do: normalize(KilnCMSWeb.Endpoint.host())

  @doc "Whether `typed` is `phrase/0`, ignoring surrounding space and case."
  @spec phrase_matches?(term()) :: boolean()
  def phrase_matches?(typed) when is_binary(typed), do: normalize(typed) == phrase()
  def phrase_matches?(_typed), do: false

  defp normalize(text), do: text |> String.trim() |> String.downcase()

  @impl true
  def run(input, _opts, context) do
    except = input.arguments[:except_session_jti]

    with :ok <- confirm(input.arguments[:confirmation]),
         {:ok, keep} <- keep(context.actor, except) do
      sign_out(keep, except, context)
    end
  end

  defp confirm(typed) do
    if phrase_matches?(typed),
      do: :ok,
      else:
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :confirmation,
           message: "does not match the instance's host name"
         )}
  end

  defp keep(_actor, nil), do: {:ok, []}

  defp keep(actor, jti) when is_binary(jti) do
    subject = actor && AshAuthentication.user_to_subject(actor)

    # authorize?: false — a system read of one token row by jti, to check
    # below that it is the caller's own live session.
    case Accounts.get_session_activity(jti, authorize?: false, not_found_error?: false) do
      {:ok, %Token{purpose: "user", subject: ^subject} = row} when is_binary(subject) ->
        {:ok, [row.jti | List.wrap(row.remember_me_jti)]}

      _not_yours ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :except_session_jti,
           message: "is not one of your sessions"
         )}
    end
  end

  defp sign_out(keep, except, context) do
    result =
      AfterCommit.deferring(fn ->
        Sessions.revoke_transaction(fn -> in_transaction(keep, except, context) end)
      end)

    case result do
      {:ok, count} -> {:ok, count}
      {:error, error} -> {:error, error}
    end
  end

  defp in_transaction(keep, except, context) do
    with {:ok, jtis} <- Sessions.revoke_everywhere(keep),
         {:ok, _event} <- record(length(jtis), except, context) do
      AfterCommit.run(fn -> dispatch_eviction(jtis) end)
      length(jtis)
    else
      {:error, error} -> Repo.rollback(error)
      :skipped -> Repo.rollback(SignOutNotRecorded.exception([]))
    end
  end

  defp record(count, except, context) do
    request = Map.get(context.source_context || %{}, Recorder.context_key())

    Recorder.record(:all_sessions_revoked_everywhere,
      scope: :instance,
      user: context.actor,
      target_type: "instance",
      metadata: %{
        "count" => Integer.to_string(count),
        "except_self" => to_string(is_binary(except))
      },
      request: request
    )
  end

  # Off the request: one broadcast pair per session on every node, which for
  # a whole installation is too many to hold the admin's page for.
  defp dispatch_eviction(jtis) do
    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn ->
        SessionEviction.evict_sessions(jtis, :instance_sign_out_all)
      end)
    else
      SessionEviction.evict_sessions(jtis, :instance_sign_out_all)
    end

    :ok
  catch
    # `start_child/2` is a call: a restarting supervisor exits the caller,
    # which here is a sign-out that has already committed. The revoked
    # sessions' pages and sockets still meet the revoked rows on their next
    # request, rejoin or re-check.
    :exit, reason ->
      Logger.warning("Instance sign-out eviction not started: #{inspect(reason)}")
      :ok
  end
end
