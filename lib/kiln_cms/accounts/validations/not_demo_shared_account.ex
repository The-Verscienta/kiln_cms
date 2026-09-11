defmodule KilnCMS.Accounts.Validations.NotDemoSharedAccount do
  @moduledoc """
  Refuses a self-service credential change while demo mode is on, unless the
  actor is an admin (`KilnCMS.Demo.locks_credentials?/1`, `docs/demo-mode.md`).

  Declared on every action that changes how the account signs in — the password,
  TOTP enrolment and removal, recovery codes, passkey registration and removal —
  because on a demo that account is shared by every visitor. Admins pass: the
  operator curates the demo as an admin, and the admin console is how they
  repair the shared account.

  A validation rather than a policy check, for two reasons:

    * **It covers the system calls too.** Passkey registration runs
      `authorize?: false` from the WebAuthn ceremony, where no policy runs; a
      validation runs on every call, authorized or not.
    * **It carries the reason.** A policy refusal is a bare `Forbidden`; this
      returns `KilnCMS.Accounts.Errors.DemoAccountLocked`, which the settings
      page turns into a sentence.

  Keyed on the actor, never on the record: a call with no actor is a system
  call (the release console, a ceremony) and passes. An authorized call with no
  actor is refused by the actions' own `id == ^actor(:id)` policies anyway.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.Errors.DemoAccountLocked

  @impl true
  def validate(_changeset, _opts, context) do
    if KilnCMS.Demo.locks_credentials?(context.actor),
      do: {:error, DemoAccountLocked.exception([])},
      else: :ok
  end

  # Reads nothing off the record, so the atomic answer is the same one.
  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)
end
