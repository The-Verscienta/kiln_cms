defmodule KilnCMS.Accounts.Errors.SignOutNotRecorded do
  @moduledoc """
  "Sign out everyone on every site" (#2491) rolled back because the instance
  security log wrote no event for it (`KilnCMS.Security.Recorder.record/2`
  returned `:skipped`, as it does for an acting account already anonymized).
  Nothing was revoked. Its own type, so the page can say why rather than
  "try again".
  """
  use Splode.Error, fields: [], class: :unknown

  @impl true
  def message(_error), do: "the sign-out could not be recorded in the instance security log"
end
