defmodule KilnCMS.CMS.Validations.PayloadLink do
  @moduledoc """
  Keeps the payload-link actions (`ContentLink.:create_link`, `:update_link`,
  `:destroy_link`, R8) off reference edges.

  A `kind: :reference` edge is a copy of a `:reference` custom field's value
  (`KilnCMS.CMS.ContentLinks`). Writing it directly would leave the field and
  its edge disagreeing — the stale-snapshot problem D23 rules out — so a
  create may not name that kind, and an update or delete may not touch an
  edge that has a `field`. The field itself is the way in.
  """
  use Ash.Resource.Validation

  @message "is a reference field's connection — change the field instead " <>
             "(add/remove/move references, or PATCH custom_fields)"

  @impl true
  def validate(changeset, _opts, _context) do
    reference? =
      Ash.Changeset.get_attribute(changeset, :kind) == :reference or
        not is_nil(Ash.Changeset.get_attribute(changeset, :field))

    if reference?, do: {:error, field: :kind, message: @message}, else: :ok
  end
end
