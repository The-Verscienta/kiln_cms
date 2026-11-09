defmodule KilnCMS.Security.Errors.PostureBusy do
  @moduledoc """
  A Security posture report refused because the site already has as many
  running as it may (#2252, `KilnCMS.Security.Posture.with_slot/2`). Not a
  refusal of the caller: the same request succeeds once one finishes. Its own
  type, so the page can say "busy" rather than "no permission".
  """
  use Splode.Error, fields: [], class: :invalid

  @impl true
  def message(_error), do: "this site's security posture checks are already running"
end
