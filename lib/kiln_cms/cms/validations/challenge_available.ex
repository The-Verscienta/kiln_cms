defmodule KilnCMS.CMS.Validations.ChallengeAvailable do
  @moduledoc """
  Refuses switching a form's human verification on (`Form.challenge`
  `:always`, #2249) while no form can ask for one: no usable provider, the
  kill switch on, or the operator's `CHALLENGE_FORMS=false`
  (`KilnCMS.Challenge.forms_available?/1`).

  Saving it anyway would leave a form the admin believes is protected and a
  page that draws nothing. The setting is clamped on every read regardless
  (`KilnCMS.Challenge.form_required?/2`), so this is about telling the admin
  the truth at the moment they ask, not about enforcement.

  Only when the changeset is *changing* `challenge`: a form switched on while
  it was available can still be renamed or deactivated after the operator
  turns forms off, the same rule `KilnCMS.CMS.Validations.EmbedCeiling`
  follows for a stale allowlist.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Challenge

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :challenge) and
         Ash.Changeset.get_attribute(changeset, :challenge) == :always and
         not Challenge.forms_available?(Challenge.config()) do
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :challenge,
         message:
           "can't be turned on: human verification isn't available on this deployment. " <>
             "Ask the operator to configure it."
       )}
    else
      :ok
    end
  end

  @impl true
  def describe(_opts),
    do: [message: "can't be turned on while human verification is unavailable", vars: []]
end
