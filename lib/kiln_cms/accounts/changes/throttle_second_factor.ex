defmodule KilnCMS.Accounts.Changes.ThrottleSecondFactor do
  @moduledoc """
  Charges one attempt against the account's second-factor budget, for the TOTP
  actions reachable from an authenticated session (#727).

  #714 bounded the second factor at `POST /sign-in/verify`, and #726 extended
  that budget to the headless gate. Neither covered the *other* three actions
  that check a six-digit code — `:disable_totp`,
  `:regenerate_totp_recovery_codes` and `:confirm_totp` — all reachable as
  LiveView events on `/editor/settings`. A LiveView event passes no router
  pipeline, so those did not even get the per-IP `:auth` bucket, the same gap
  #715 closed for the sign-in submit. An attacker holding a stolen session
  cookie could grind the 10^6 space at socket speed; on a hit, `:disable_totp`
  nulls the secret and empties the recovery hashes, and either of the other two
  hands over a working recovery-code set.

  ## Why the charge is in a change *body*, not a hook

  The charge has to land on the attempt that fails — a budget that only counts
  correct codes counts nothing worth counting. That rules out the two obvious
  homes:

    * `KilnCMS.Accounts.Validations.ValidTotpCode`, which the three actions
      already share, is not a place for a side effect;
    * a `before_action` hook never runs at all here. Ash's own
      run_before_actions returns immediately on an invalid changeset, and the
      validation has already invalidated it by then.

  A `change` body runs during `Ash.Changeset.for_update/4`, before either, so
  the budget is spent whatever the code turns out to be. That is the ordering
  `KilnCMS.Accounts.AccountThrottle`'s moduledoc argues for — check-then-count
  is the bug class it exists to prevent, and getting it backwards fails
  *silently*, still refusing wrong codes but with an unbounded budget.

  Declared *above* the validation for readability rather than necessity: Ash
  runs changes and validations in declaration order, but skips a change only
  when it sets `only_when_valid?: true`, which defaults to `false`. So this
  would charge from below the validation too. Do not rely on that — the
  invariant is "a wrong code costs budget", and
  `KilnCMS.Accounts.SecondFactorSettingsBudgetTest` pins it directly rather
  than pinning the ordering that happens to produce it.

  Living on the action rather than at the three call sites is the other half:
  `ThrottleSignIn`'s moduledoc makes the case (*"a plug per route is a list to
  forget to add to"*), and a fourth caller of `:disable_totp` — a headless
  settings API, an admin tool — inherits the bound instead of missing it.

  > #### A form would charge per keystroke {: .warning}
  >
  > Build-time means once per `Ash.Changeset.for_update/4`. Today's callers use
  > the code interface directly from `handle_event`, which is one build per
  > submit. Move any of them onto an `AshPhoenix.Form` and
  > `AshPhoenix.Form.validate/2` builds a changeset *per keystroke*, so the
  > budget would be spent typing the first correct code. That is #478's live bug
  > one layer down; if it ever happens, the charge has to move to the submit.

  ## The budget is shared with the sign-in gate, deliberately

  `consume_second_factor/1` keys on the account, and the sign-in prompt charges
  the same bucket. Two budgets would be one budget twice as large: an attacker
  who exhausted `/sign-in/verify` would simply pivot here for a fresh five.

  ## All three actions, including `:confirm_totp`

  Since #754, `:confirm_totp` checks `totp_pending_secret` — the secret staged
  by `:setup_totp`, not yet promoted — rather than the live one. An attacker
  who calls `:setup_totp` themselves gets a secret of their own and confirms
  it with their own code, so there is nothing there to guess or to budget.

  What remains is a narrower race: the *real* owner calls `:setup_totp`,
  leaving an unconfirmed secret sitting in `totp_pending_secret` while they
  reach for their authenticator app, and a second, attacker-held session on
  the same account could otherwise grind the 6-digit space for that same
  pending secret and confirm it before the owner does — hijacking an
  enrolment the owner started but had not yet finished. The budget bounds that
  window the same way it bounds the other two.

  Charging it does cost a legitimate enroller with a skewed device clock five
  attempts out of the budget that gates their next sign-in. That is the same
  bargain every other prompt here makes, and a correct code clears the counter.

  ## Charged at build, which is before authorization

  A `change` body runs during `for_update/4`, so the budget is spent whether or
  not the caller was allowed to run the action at all — `Ash.can?`-style
  preflight included. No surface reaches it today: these three actions are
  self-service only, and the read policy stops an actor loading another user's
  record to build a changeset against. Anything that changes either of those
  gives an attacker a way to spend a *victim's* second-factor budget, which is
  a lockout rather than a bypass, but is worth knowing before adding a caller.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.SecondFactorThrottled

  @impl true
  def change(changeset, _opts, _context) do
    case AccountThrottle.consume_second_factor(changeset.data.id) do
      :allow ->
        # Only on a code that actually verified — `after_action` does not run
        # for a changeset the validation below rejected. Same reasoning as the
        # sign-in gate's forgive: someone whose authenticator was a minute out
        # of sync has now proved they hold the factor, and carrying that into
        # their next sign-in would lock out the person the budget protects.
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          AccountThrottle.forgive_second_factor(record.id)
          {:ok, record}
        end)

      {:deny, retry_after_ms} ->
        Ash.Changeset.add_error(
          changeset,
          SecondFactorThrottled.exception(
            retry_after_seconds: AccountThrottle.retry_after_seconds(retry_after_ms)
          )
        )
    end
  end
end
