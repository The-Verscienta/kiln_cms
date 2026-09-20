defmodule KilnCMS.CMS.SiteMailRelay do
  @moduledoc """
  A site's own SMTP relay (#1322): the relay and From address this site's mail
  goes out through, entered by the site's admin at `/editor/site-mail` instead
  of by the operator in `SMTP_*` environment variables.

  The first of the per-site integrations #1322 moves out of the environment,
  and the one that sets the pattern for the rest — see the plan on the issue.
  Read through `KilnCMS.Mail.SiteRelay`, which owns the precedence rule and the
  fail direction; nothing else should read this row.

  ## Which mail it carries

  Mail *about this site*: newsletters and their confirmations, form
  notifications and autoresponders, workflow, task and comment notifications,
  and automation emails. Account mail — sign-in links, password resets,
  confirmations, sign-in alerts — stays on the operator's relay, because an
  account belongs to the deployment, not to any one site.

  ## Who can write it, and what that means

  Org admin, like every `KilnCMS.CMS.OrgSettings` resource. On a hosted
  deployment that is a tenant, which is why two things are stricter here than on
  the operator's `KilnCMS.Mail.Settings`:

    * **The password is database-only.** It is encrypted into
      `password_encrypted` (`KilnCMS.Keys.Vault`) and never read back into a
      form. The env-var and file key providers the operator's settings offer are
      not offered here: a tenant who could point "the SMTP password" at an
      environment variable could send `SECRET_KEY_BASE` to their own relay.
    * **The host is SSRF-checked**, at save and again at every connection
      (`KilnCMS.Webhooks.SafeUrl.resolve_host_pinned/1`): no private, loopback,
      link-local or metadata address. An operator who needs an internal relay
      sets `SMTP_HOST`, which is trusted and unchecked.

  Reads are admin-only too. Nothing here is rendered to a visitor, and the row
  names the site's mail provider and account.

  ## The password on a save

  A blank password keeps the stored one — the form never has it to send back.
  Clearing the username clears the password with it, since a password with no
  username is never sent. `password_encrypted` is left out of the upsert's
  `upsert_fields` on purpose: the page writes an existing row through `:update`,
  and a `:save` that lost a create race must not overwrite the winner's
  password with its own blank.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_mail_relays",
    accept: [:enabled, :host, :port, :security, :username, :from_email, :from_name],
    save_arguments: [{:password, :string, sensitive?: true}],
    save_changes: [KilnCMS.CMS.Changes.StoreRelayPassword],
    read: :admin

  postgres do
    # Ash casts `security` to an atom on read, so an out-of-band write of any
    # other string would crash the read — and with it every mail job for the
    # site. Same guard as `mail_settings.dkim_key_provider`.
    check_constraints do
      check_constraint :security, "site_mail_relay_security_must_be_known",
        check: "security IN ('starttls', 'tls')"
    end
  end

  validations do
    validate present([:host, :from_email]), where: [attribute_equals(:enabled, true)]
    validate KilnCMS.CMS.Validations.RelayHost

    validate match(:from_email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/),
      message: "must be an email address"

    # A mail header. A line break would start a header of the caller's choosing.
    validate match(:from_name, ~r/\A[^\r\n]*\z/), message: "must be on one line"
  end

  attributes do
    # Off keeps the details but sends through the operator's relay again — the
    # way back from a broken relay that does not mean retyping it.
    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # A host name or a public IP address, never `host:port` — the port is its
    # own field. Checked by `Validations.RelayHost`.
    attribute :host, :string,
      public?: true,
      constraints: [max_length: 253]

    attribute :port, :integer do
      default 587
      allow_nil? false
      public? true
      constraints min: 1, max: 65_535
    end

    # `:starttls` upgrades a plain connection (port 587); `:tls` is TLS from the
    # first byte (port 465). There is no unencrypted option: this sends a
    # password across the internet, and the certificate is always verified.
    attribute :security, :atom do
      default :starttls
      allow_nil? false
      public? true
      constraints one_of: [:starttls, :tls]
    end

    attribute :username, :string,
      public?: true,
      constraints: [max_length: 255]

    # Set only by `Changes.StoreRelayPassword`, from the `:password` argument.
    # `Vault.Ciphertext`, not plain `:binary`, so `mix kiln.vault.reencrypt`
    # walks it across a `SECRET_KEY_BASE` rotation (#1487). Same storage, so
    # there is no migration — the type exists to make the column findable.
    attribute :password_encrypted, KilnCMS.Keys.Vault.Ciphertext do
      sensitive? true
      writable? false
    end

    # The address this site's mail is sent from. It has to be one the relay will
    # send for — most providers refuse any other.
    attribute :from_email, :string,
      public?: true,
      constraints: [max_length: 254]

    # Blank means the site's name, from its branding.
    attribute :from_name, :string,
      public?: true,
      constraints: [max_length: 100]
  end
end
