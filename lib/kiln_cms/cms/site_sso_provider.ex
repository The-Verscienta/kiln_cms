defmodule KilnCMS.CMS.SiteSsoProvider do
  @moduledoc """
  A site's own single sign-on provider (#1561): the OpenID Connect issuer,
  client id and client secret this site's sign-in page offers, entered by the
  site's admin at `/editor/site-sso` instead of by the operator in `OIDC_*`
  environment variables.

  The last of the per-site integrations #1322 moves out of the environment.
  Read through `KilnCMS.Accounts.SiteSso`, which owns the fail direction and the
  whole sign-in flow; nothing else should read this row.

  ## What a site's provider may vouch for

  Accounts belong to the deployment, not to a site, so a provider a site admin
  chose is not trusted for every address it asserts. It is honoured **only**
  for email addresses in a domain this site has verified by DNS
  (`KilnCMS.CMS.SiteSsoDomain`), and never for an account that holds access on
  any other site. `KilnCMS.Accounts.SiteSso.Admission` is that rule.

  ## Who can write it, and what that means

  Org admin, like every `KilnCMS.CMS.OrgSettings` resource. Two things are
  stricter than on the operator's `OIDC_*` settings, for the same reasons as
  `KilnCMS.CMS.SiteMailRelay`:

    * **The client secret is database-only and write-only.** It is encrypted
      into `client_secret_encrypted` (`KilnCMS.Keys.Vault`) and never read back
      into a form. There is no env-var or file option: a tenant who could point
      "the client secret" at an environment variable could send
      `SECRET_KEY_BASE` to their own token endpoint.
    * **The issuer is SSRF-checked** (`Validations.SsoIssuer`), because
      discovery fetches it: `https://` only, and no private, loopback,
      link-local or metadata address. Every fetch the sign-in makes — discovery,
      the token endpoint, the signing keys — goes through `KilnCMS.SafeFetch`
      again, since the discovery document names the other two and DNS can change
      after a save.

  Reads are admin-only too. The row names the site's identity provider and its
  client registration; the sign-in page learns only whether to draw a button,
  and its label, through `KilnCMS.Accounts.SiteSso.sign_in_option/1`.

  ## The secret on a save

  A blank secret keeps the stored one — the form never has it to send back.
  `client_secret_encrypted` is left out of the upsert's `upsert_fields` on
  purpose, exactly as `SiteMailRelay.password_encrypted` is: the page writes an
  existing row through `:update`, and a `:save` that lost a create race must not
  overwrite the winner's secret with its own blank.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_sso_providers",
    accept: [:enabled, :issuer, :client_id, :label],
    save_arguments: [{:client_secret, :string, sensitive?: true}],
    save_changes: [KilnCMS.CMS.Changes.StoreSsoClientSecret],
    read: :admin

  validations do
    validate present([:issuer, :client_id]), where: [attribute_equals(:enabled, true)]
    validate KilnCMS.CMS.Validations.SsoIssuer

    # Drawn on the sign-in page as the button's text.
    validate match(:label, ~r/\A[^\r\n<>]*\z/), message: "must be on one line, without < or >"
  end

  attributes do
    # Off keeps the details but takes the button off the sign-in page — the way
    # back from a broken provider that does not mean retyping it.
    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # The provider's issuer URL, exactly as its discovery document states it
    # (`KilnCMS.Accounts.SiteSso` refuses a document whose `issuer` differs).
    # Discovery is at `<issuer>/.well-known/openid-configuration`.
    attribute :issuer, :string,
      public?: true,
      constraints: [max_length: 2048]

    attribute :client_id, :string,
      public?: true,
      constraints: [max_length: 512]

    # Set only by `Changes.StoreSsoClientSecret`, from the `:client_secret`
    # argument. `Vault.Ciphertext`, not plain `:binary`, so
    # `mix kiln.vault.reencrypt` walks it across a `SECRET_KEY_BASE` rotation
    # (#1487).
    attribute :client_secret_encrypted, KilnCMS.Keys.Vault.Ciphertext do
      sensitive? true
      writable? false
    end

    # The sign-in button's text, e.g. "Acme staff". Blank reads "Single sign-on".
    attribute :label, :string,
      public?: true,
      constraints: [max_length: 80]
  end
end
