defmodule KilnCMS.Accounts.Changes.CheckBreachedPassword do
  @moduledoc """
  Looks the new password up in the breach corpus before an account's password
  is set (#2240). On every password-setting action of `User`:
  `:register_with_password` (`action: :register`), `:change_password`
  (`:change`), `:reset_password_with_token` (`:reset`), `:bootstrap_admin`
  (`:bootstrap`), and the two invitation accepts (#2135),
  `:register_with_invitation` and `:accept_invitation_with_password`
  (`:invite`).

  An invitation is checked against the **invited** site's policy for the
  **invited** tier — the invitation `KilnCMS.Accounts.Changes.AcceptInvitation`
  put in the changeset context — not the host the link was opened on.

  ## From a `before_transaction` hook, not the change body

  `change/3` runs when the changeset is *built*, and `AshPhoenix.Form.validate/2`
  builds one per keystroke on a `phx-change` form. A lookup there would send a
  request to a third party for every character typed. The hook runs once, when
  the action actually executes, and only for a changeset that is still valid —
  a rejected form (mismatched confirmation, wrong current password, bad reset
  token) never calls out. It is `before_transaction`, not `before_action`, so
  no database connection is held for the lookup (the same reason
  `KilnCMS.Accounts.Changes.ThrottleRegistration` charges there).

  Bootstrap is the exception: it runs the whole action inside a transaction
  that holds a Postgres advisory lock, so `KilnCMS.Accounts.Bootstrap` makes the
  lookup **before** the transaction (`lookup/4`) and hands the verdict in
  through the changeset context. For that action the hook only reads the
  verdict, and never calls out when one is present.

  ## The verdict

    * the password is clean, or the lookup could not tell (any error — fail
      open): nothing happens;
    * breached under `:warn`: the action succeeds and its record carries
      `__metadata__.password_breach == %{status: :breached}` for the caller to
      show a warning (declared as `metadata :password_breach` on each action);
    * breached under `:block`: an `InvalidAttribute` error on `:password`,
      carrying neither the password nor the value. It is deliberately not an
      `AuthenticationFailed`: that is a forbidden-class error `AshPhoenix.Form`
      renders as no field error at all.

  ## Paths that set a credential without this check

  Deliberately exempt: `AdminPasswordReset` (an admin sends a mail; the owner's
  later use of the link is `:reset` and is checked), magic-link, SSO and passkey
  registration (no password is set), `AnonymizeUser`, seeds, `Beta.Round` and
  `Staging.Scrub` (operator-run). Sign-in is not checked either. See
  `docs/threat-model.md`, "Breached passwords".

  See `KilnCMS.Accounts.PasswordPolicy` for how the policy is chosen and
  `KilnCMS.Accounts.BreachedPassword` for what is sent. Telemetry is
  `[:kiln_cms, :password, :breach_check]`; nothing identifying the password,
  the hash, the account or the org is ever logged or emitted.
  """
  use Ash.Resource.Change
  use Gettext, backend: KilnCMSWeb.Gettext

  require Logger

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.PasswordNotice
  alias KilnCMS.Accounts.PasswordPolicy

  @event [:kiln_cms, :password, :breach_check]
  @verdict_key :breached_password_verdict

  @type verdict :: %{outcome: :clean | :breached | :unchecked, policy: PasswordPolicy.policy()}

  @doc "The changeset-context key `KilnCMS.Accounts.Bootstrap` passes its verdict under."
  @spec verdict_key() :: atom()
  def verdict_key, do: @verdict_key

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :action) do
      {:ok, action} when action in [:register, :change, :reset, :bootstrap, :invite] ->
        {:ok, opts}

      _other ->
        {:error, "action: must be :register, :change, :reset, :bootstrap or :invite"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    action = Keyword.fetch!(opts, :action)

    changeset
    |> Ash.Changeset.before_transaction(&check(&1, action))
    |> Ash.Changeset.after_action(fn changeset, record ->
      if changeset.context[:password_breach] == :breached do
        {:ok, Ash.Resource.put_metadata(record, :password_breach, %{status: :breached})}
      else
        {:ok, record}
      end
    end)
    |> Ash.Changeset.after_transaction(&leave_notice(&1, &2, action))
  end

  # Register and reset hand their record to upstream AshAuthentication.Phoenix
  # components that drop the action's metadata before any page is rendered, so
  # the warning is parked for the sign-in that follows
  # (`KilnCMS.Accounts.PasswordNotice`). After the transaction, so a rolled-back
  # action leaves nothing behind. Change and bootstrap show theirs directly.
  defp leave_notice(_changeset, {:ok, record} = result, action)
       when action in [:register, :reset, :invite] do
    case record.__metadata__ do
      %{password_breach: %{status: :breached}} -> PasswordNotice.put(record.id)
      _none -> :ok
    end

    result
  end

  defp leave_notice(_changeset, result, _action), do: result

  defp check(%{valid?: false} = changeset, _action), do: changeset

  defp check(changeset, action) do
    case verdict(changeset, action) do
      nil -> changeset
      verdict -> apply_verdict(changeset, verdict)
    end
  end

  # Bootstrap's verdict was taken before its transaction; every other action
  # looks the password up here.
  defp verdict(changeset, :bootstrap) do
    case Map.get(changeset.context, @verdict_key) do
      %{outcome: _} = verdict -> verdict
      _absent -> lookup_for(changeset, :bootstrap)
    end
  end

  defp verdict(changeset, action), do: lookup_for(changeset, action)

  defp lookup_for(changeset, action) do
    case Ash.Changeset.get_argument(changeset, :password) do
      password when is_binary(password) and password != "" ->
        org = target_org(changeset, action)
        with_tier(changeset, action, org, &lookup(password, action, org, &1))

      _none ->
        nil
    end
  end

  # Registration creates a viewer and bootstrap an admin; a change or a reset
  # is for the account the changeset holds.
  # The tier read hits the database (`Scoping.effective_tier`): a failure there
  # is "could not tell", like every other lookup problem, never a 500 on a
  # password change.
  defp with_tier(changeset, action, org, fun) do
    fun.(target_tier(changeset, action, org))
  rescue
    _error ->
      Logger.warning("breached-password tier could not be resolved; allowing the password")
      nil
  end

  defp target_org(%{context: %{invitation: %{organization_id: org_id}}}, :invite), do: org_id
  defp target_org(changeset, _action), do: Accounts.org_id(changeset.tenant)

  defp target_tier(%{context: %{invitation: %{role: role}}}, :invite, _org), do: role
  defp target_tier(_changeset, :register, _org), do: :viewer
  defp target_tier(_changeset, :bootstrap, _org), do: :admin
  defp target_tier(changeset, _action, org), do: PasswordPolicy.target_tier(changeset.data, org)

  @doc """
  Resolve the policy for the target and, unless it is `:off`, look `password`
  up. Returns the verdict, or `nil` when the check is off. Fails open: any
  error — including an exception while resolving the tier or the setting —
  is an `:unchecked` outcome.
  """
  @spec lookup(String.t(), atom(), Ash.UUID.t(), atom()) :: verdict() | nil
  def lookup(password, action, org_id, tier) do
    case safe_policy(org_id, tier) do
      :off -> nil
      policy -> run(password, action, policy)
    end
  end

  defp safe_policy(org_id, tier) do
    PasswordPolicy.resolve(org_id, tier)
  rescue
    # Boundary: a failure to work out the policy must not stop a password being
    # set. Fail open to the default stance, and say nothing about who.
    _error ->
      Logger.warning("breached-password policy could not be resolved; treating as warn")
      :warn
  end

  defp run(password, action, policy) do
    started = System.monotonic_time()
    result = BreachedPassword.check(password)
    duration = System.monotonic_time() - started

    {outcome, reason} =
      case result do
        {:ok, :clean} -> {:clean, nil}
        {:ok, {:breached, _count}} -> {:breached, nil}
        {:error, class} -> {:unchecked, class}
      end

    if reason do
      Logger.warning("breached-password lookup failed (#{reason}); allowing the password")
    end

    :telemetry.execute(@event, %{count: 1, duration: duration}, %{
      result: telemetry_result(outcome),
      action: action,
      policy: policy,
      enforcement: enforcement(outcome, policy),
      reason: reason
    })

    %{outcome: outcome, policy: policy}
  end

  defp telemetry_result(:unchecked), do: :error
  defp telemetry_result(outcome), do: outcome

  defp enforcement(:breached, :block), do: :blocked
  defp enforcement(:breached, :warn), do: :warned
  defp enforcement(_outcome, _policy), do: :allowed

  defp apply_verdict(changeset, %{outcome: :breached, policy: :block}) do
    Ash.Changeset.add_error(
      changeset,
      InvalidAttribute.exception(
        field: :password,
        message:
          gettext("This password has appeared in a known data breach. Choose a different one.")
      )
    )
  end

  defp apply_verdict(changeset, %{outcome: :breached}),
    do: Ash.Changeset.set_context(changeset, %{password_breach: :breached})

  defp apply_verdict(changeset, _verdict), do: changeset
end
