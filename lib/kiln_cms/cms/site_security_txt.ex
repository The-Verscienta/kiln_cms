defmodule KilnCMS.CMS.SiteSecurityTxt do
  @moduledoc """
  A site's `/.well-known/security.txt` (RFC 9116, #1873): where a security
  researcher reports a vulnerability in *this* site, and the terms they report
  under.

  Per org, like branding: each Kiln site is its own publication with its own
  host, and the people who answer for one tenant's security are not the people
  who answer for another's. Served by `KilnCMSWeb.SecurityTxtController`
  through `KilnCMS.SecurityTxt`, which caches the row and renders the file;
  edited at `/editor/security-txt` (`KilnCMSWeb.SecurityTxtLive`).

  ## No row, no file

  There is no operator default underneath this one. A contact address is a
  promise that somebody reads it, and a deployment-wide value would make that
  promise on every tenant's behalf. A site with no row — or a row with no
  `contacts` — answers 404, which RFC 9116 treats as "this site has no
  security.txt", rather than a file without the one field it requires.

  ## Public read

  The row is the file, and the file is served to anyone, so the read policy is
  `:public` (the `SiteBranding` reasoning). Writes are org-admin, as on every
  `KilnCMS.CMS.OrgSettings` resource: a security contact is a statement made
  on the whole site's behalf.

  ## The file is line-oriented

  Every value is written verbatim after a `Field: ` prefix, one per line, so a
  value carrying a line break would forge a field of its own — a `Contact:`
  that routes reports to someone else, or an `Expires:` that outlives the one
  the admin set. `KilnCMS.CMS.Validations.SecurityTxt` holds every value to a
  single line of printable ASCII at write time, and `KilnCMS.SecurityTxt.render/2`
  re-checks it at render time for a row that reached the table some other way.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_security_txt",
    accept: [
      :contacts,
      :expires_on,
      :policy_url,
      :preferred_languages,
      :encryption_url,
      :acknowledgments_url
    ],
    read: :public,
    admin_columns: [:contacts, :expires_on, :updated_at]

  # After COMMIT, like every delivery-facing settings bust — see the change.
  changes do
    change KilnCMS.CMS.Changes.BustSecurityTxt, on: [:create, :update, :destroy]
  end

  validations do
    validate KilnCMS.CMS.Validations.SecurityTxt
  end

  attributes do
    # `mailto:`, `https://` or `tel:` URIs, in the order the admin listed them
    # — RFC 9116 §2.5.3 says the first is the preferred one. Ten is far more
    # than any site lists and keeps the file (and the form) bounded.
    attribute :contacts, {:array, :string} do
      allow_nil? true
      public? true
      constraints max_length: 10, items: [max_length: KilnCMS.Limits.url()]
    end

    # `Expires` is required by the RFC. A date rather than a timestamp: the
    # file says the last second of that day, UTC, which is the precision an
    # admin is actually choosing at.
    attribute :expires_on, :date do
      allow_nil? true
      public? true
    end

    attribute :policy_url, :string do
      allow_nil? true
      public? true
      constraints max_length: KilnCMS.Limits.url()
    end

    # BCP 47 tags (`en`, `pt-BR`), in the admin's order of preference.
    attribute :preferred_languages, {:array, :string} do
      allow_nil? true
      public? true
      constraints max_length: 10, items: [max_length: 35]
    end

    # Where the researcher finds a key to encrypt the report with: an `https://`
    # URL, or an `openpgp4fpr:` fingerprint / `dns:` URI (RFC 9116 §2.5.4).
    attribute :encryption_url, :string do
      allow_nil? true
      public? true
      constraints max_length: KilnCMS.Limits.url()
    end

    attribute :acknowledgments_url, :string do
      allow_nil? true
      public? true
      constraints max_length: KilnCMS.Limits.url()
    end
  end
end
