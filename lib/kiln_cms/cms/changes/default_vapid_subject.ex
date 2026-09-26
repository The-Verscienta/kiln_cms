defmodule KilnCMS.CMS.Changes.DefaultVapidSubject do
  @moduledoc """
  A blank VAPID subject (#1560) becomes `mailto:` the acting admin's address.

  RFC 8292 asks for a contact a push service's operator can reach. The admin
  who generated the site's key is the nearest one this site has, and the page
  lets them change it. With no actor (a system write) it stays blank, and
  `KilnCMS.Push.Keys` signs with the deployment's subject instead.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    subject = Ash.Changeset.get_attribute(changeset, :subject)

    case {blank?(subject), context.actor} do
      {true, %{email: email}} when not is_nil(email) ->
        Ash.Changeset.force_change_attribute(changeset, :subject, "mailto:#{email}")

      {true, _no_actor} ->
        Ash.Changeset.force_change_attribute(changeset, :subject, nil)

      {false, _actor} ->
        Ash.Changeset.force_change_attribute(changeset, :subject, String.trim(subject))
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
