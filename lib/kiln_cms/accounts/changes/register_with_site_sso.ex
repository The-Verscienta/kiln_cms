defmodule KilnCMS.Accounts.Changes.RegisterWithSiteSso do
  @moduledoc """
  The body of `User.:register_with_site_sso` (#1561): a new account for an
  address a site's own identity provider vouched for.

    * **System-only.** An actor-carrying call is refused here as well as by the
      action's `forbid_if always()` policy, because the platform-admin bypass
      would otherwise pass that policy. Only `KilnCMS.Accounts.SiteSso.Admission`
      calls this, with `authorize?: false`, after the ID token verified and the
      address passed the site's verified-domain rule.
    * **No password.** The account gets an unguessable random hash; password
      sign-in works only after an explicit reset, as for the operator's SSO
      (`Changes.RegisterWithSso`).
    * **Nothing above `:viewer`.** `role` keeps its default, and no audiences.
      The site's membership row (`:viewer`, on that site only) is written by
      `Admission` once the account exists.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    if context.actor do
      Ash.Changeset.add_error(changeset,
        field: :email,
        message: "is provisioned by a site's sign-in only"
      )
    else
      changeset
      |> Ash.Changeset.force_change_attribute(
        :hashed_password,
        Bcrypt.hash_pwd_salt(32 |> :crypto.strong_rand_bytes() |> Base.encode64())
      )
      |> maybe_set_name(Ash.Changeset.get_argument(changeset, :name))
    end
  end

  defp maybe_set_name(changeset, name) when is_binary(name) and name != "",
    do: Ash.Changeset.change_attribute(changeset, :name, name)

  defp maybe_set_name(changeset, _name), do: changeset
end
