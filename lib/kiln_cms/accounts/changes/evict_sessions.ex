defmodule KilnCMS.Accounts.Changes.EvictSessions do
  @moduledoc """
  Drops a user's live sockets after an action that narrows what they may do
  (#675).

  Declared on the actions that change a grant rather than called from their
  callers, for the reason `ThrottleSignIn`'s moduledoc gives about plugs: a list
  of call sites is a list to forget to add to, and the thing forgotten here is
  invisible — the socket simply stays connected, doing what it was allowed to do
  before.

  Runs `after_action`, so an action that fails evicts nobody. Failures inside
  the eviction are swallowed by `KilnCMS.Accounts.SessionEviction` itself: a
  broadcast that could roll back the change would leave the grant narrowed and
  the socket still holding the old one, which is the worst of both.

  ## Narrowing only, and every change counts as narrowing

  A widened grant needs no eviction — the socket simply has less than it could
  — but nothing here tries to tell the two apart. Comparing old and new
  `editable_types`, audiences and role for "is this strictly larger" is a
  subtle question with a silent failure mode, and being wrong in the permissive
  direction is exactly the bug. Evicting on a widening costs a reconnect.

  ## Which field names the user

  `:user_id` says where to read it, because this runs on two resources whose
  primary key means different things: on `User` the record *is* the user, and on
  `OrgMembership` `id` is the membership — evicting that would broadcast on a
  topic no socket listens on, and fail silently in the direction of not
  evicting.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.SessionEviction

  @impl true
  def change(changeset, opts, _context) do
    reason = Keyword.get(opts, :reason, changeset.action.name)
    field = Keyword.get(opts, :user_id, :id)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      SessionEviction.evict(Map.get(record, field), reason)
      {:ok, record}
    end)
  end
end
