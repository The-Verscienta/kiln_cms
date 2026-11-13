defmodule KilnCMS.Accounts.Errors.EnrolmentProofRequired do
  @moduledoc """
  Adding a second factor was refused because the site requires one, the
  deadline has passed, and this session has not proved it reads the account's
  email (#2247, owner decision 1b; `KilnCMS.Accounts.EnrolmentProof`).

  Its own type so the page can say what to do (confirm the emailed code)
  rather than "that code isn't valid". Forbidden-class: no value of the
  action's arguments would be accepted without the proof.
  """
  use Splode.Error, fields: [], class: :forbidden

  @impl true
  def message(_error),
    do: "confirm the emailed code before adding a second factor to this account"
end
