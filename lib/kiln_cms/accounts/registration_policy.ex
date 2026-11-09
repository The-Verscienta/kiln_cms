defmodule KilnCMS.Accounts.RegistrationPolicy do
  @moduledoc """
  Whether a self-registration on a site waits for a site admin's approval
  (#2251): the site's `KilnCMS.CMS.SiteRegistration` row, or "no" for a site
  without one. There is no operator default: the site decides.

  `settings/1` answers both of the row's switches in one read: a password
  sign-up (`approval_required`) and a new account from the site's own single
  sign-on (`approval_for_site_sso`, #2514). They are independent.
  `approval_required/1` is the first alone.

  ## Failing closed

  The row is read as `KilnCMS.OrgSettings.system(:registrations)` with
  `authorize_with: :error`, so a refused read is an error and not "no row". An
  unreadable row (a refusal, the table missing mid-deploy, a pool timeout) is
  logged and answered `{:error, :unavailable}`, and the registration is refused
  with a retryable error. Answering "no approval needed" instead would let in,
  unreviewed, exactly the sign-ups a site that turned approval on meant to hold.

  Not cached: a changed setting applies to the next registration. Read on the
  caller's process (the registration's `before_transaction` hook), before the
  create's transaction opens.
  """

  alias KilnCMS.Accounts

  @typedoc "A site's registration switches, as `settings/1` reads them."
  @type settings :: %{approval_required: boolean(), approval_for_site_sso: boolean()}

  @doc """
  `{:ok, true}` when a registration on `org` (an org id, an `Organization`, or
  `nil` for the default org) must wait for approval, `{:ok, false}` when it need
  not, `{:error, :unavailable}` when the site's setting could not be read.
  """
  @spec approval_required(Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          {:ok, boolean()} | {:error, :unavailable}
  def approval_required(org) do
    with {:ok, settings} <- settings(org), do: {:ok, settings.approval_required}
  end

  @doc """
  Both of `org`'s switches, `{:ok, settings}`, every one `false` for a site
  with no row; `{:error, :unavailable}` when the row could not be read.
  """
  @spec settings(Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          {:ok, settings()} | {:error, :unavailable}
  def settings(org) do
    actor = KilnCMS.OrgSettings.system(:registrations)

    resolved =
      KilnCMS.OrgSettings.resolve_uncached(Accounts.org_id(org),
        read:
          &KilnCMS.CMS.list_site_registration(
            tenant: &1,
            actor: actor,
            authorize_with: :error
          ),
        # `nil` is reserved for "could not read", so "no row" is its own value.
        build: fn
          nil ->
            {:ok, %{approval_required: false, approval_for_site_sso: false}}

          row ->
            {:ok,
             %{
               approval_required: row.approval_required == true,
               approval_for_site_sso: row.approval_for_site_sso == true
             }}
        end,
        label: "registration approval"
      )

    resolved || {:error, :unavailable}
  end
end
