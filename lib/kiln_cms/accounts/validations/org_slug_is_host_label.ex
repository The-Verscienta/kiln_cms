defmodule KilnCMS.Accounts.Validations.OrgSlugIsHostLabel do
  @moduledoc """
  Refuse an organization slug that could never be reached as a host (#1710):
  not a DNS label, or one of the labels the system keeps for its own hosts.
  The rule is `KilnCMS.Accounts.OrgSlug.check/1`; this only reports it.

  Only a slug being *set* is checked — the actions gate it on
  `changing(:slug)` — so an org stored before the rule existed can still have
  its name or status changed. `mix kiln.org_slugs` lists those rows.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Accounts.OrgSlug

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      slug when is_binary(slug) ->
        case OrgSlug.check(slug) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, InvalidAttribute.exception(field: :slug, message: OrgSlug.message(reason))}
        end

      # A missing slug is `allow_nil?: false`'s error to report, not this one's.
      _other ->
        :ok
    end
  end
end
