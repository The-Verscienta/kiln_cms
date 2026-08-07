defmodule KilnCMS.Accounts.Changes.ReloadPendingTotpSecret do
  @moduledoc """
  Refreshes `totp_pending_secret` on the changeset's data from the database at
  build time, so `:confirm_totp` validates and promotes the secret that is
  *actually* staged right now — not one baked into a stale in-memory
  `current_user` that a second settings tab has since superseded (#787).

  ## The race this closes

  `:setup_totp` stages a fresh secret into `totp_pending_secret`. Two tabs open
  on `/editor/settings` for the same account are two separate LiveView
  processes, each holding its own `current_user` assign:

    1. Tab A runs `:setup_totp` → DB and tab A's assign both hold secret A.
    2. Tab B runs `:setup_totp` → DB now holds secret B; tab A's assign is stale.
    3. Tab A submits a code for secret A. `ValidTotpCode` and
       `PromotePendingTotpSecret` both read `changeset.data.totp_pending_secret`
       — the value on the struct tab A passed in (A) — so A's code validates and
       A is promoted, silently discarding tab B's in-progress enrolment.

  Reading the field fresh here makes that a clean "last `:setup_totp` wins": at
  step 3 the changeset's pending secret is B, tab A's code for A fails
  `ValidTotpCode` with the ordinary "that code isn't valid" message, and nothing
  is promoted. Confirming from tab B still works.

  ## Why a build-time change, and why only the one field

  Ash runs changes and validations in declaration order during
  `Ash.Changeset.for_update/4` (see `ThrottleSecondFactor`'s moduledoc). Declared
  above `ValidTotpCode`, this runs before the validation reads the secret, and
  before `PromotePendingTotpSecret` (also declared below) copies it into
  `totp_secret`. A `before_action` hook would be too late — the validation has
  already run against the stale value by then.

  Only `totp_pending_secret` is refreshed, not the whole `data` struct: this
  action `accept`s nothing, so there is no user input to preserve, but a
  wholesale swap of `data` would be a broader change than the bug needs.

  A `get_user` miss (the row was deleted mid-enrolment) leaves the changeset
  untouched — the update itself then fails, which is the correct outcome.

  A narrow residual remains — a `:setup_totp` that commits between this read and
  the promoting update — but its worst case is benign last-writer-wins on the
  same account: only a secret whose code was just proven against fresh data is
  ever promoted, which is the actual defect. Full serialization would need an
  enrolment version stamped at `:setup_totp`; out of proportion to a
  same-account UX edge.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case KilnCMS.Accounts.get_user(changeset.data.id,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %{} = fresh} ->
        %{changeset | data: %{changeset.data | totp_pending_secret: fresh.totp_pending_secret}}

      _ ->
        changeset
    end
  end
end
