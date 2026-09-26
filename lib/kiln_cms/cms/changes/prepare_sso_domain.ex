defmodule KilnCMS.CMS.Changes.PrepareSsoDomain do
  @moduledoc """
  Normalises a new `KilnCMS.CMS.SiteSsoDomain` and gives it its verification
  token.

  The domain is compared with the domain half of an asserted email address at
  every sign-in, so it is stored the way that comparison reads it: trimmed,
  lower-case, without a trailing dot. A bare TLD or a single label
  (`localhost`) is refused — neither is a domain anyone's mail is in — and so is
  anything with an `@`, which is an admin pasting an address.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.SiteSso.DomainCheck

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :domain) do
      domain when is_binary(domain) ->
        normalized = DomainCheck.normalize(domain)

        if DomainCheck.valid_domain?(normalized) do
          changeset
          |> Ash.Changeset.force_change_attribute(:domain, normalized)
          |> Ash.Changeset.force_change_attribute(
            :verification_token,
            DomainCheck.new_token()
          )
        else
          Ash.Changeset.add_error(changeset,
            field: :domain,
            message: "must be a domain like example.com"
          )
        end

      _missing ->
        changeset
    end
  end
end
