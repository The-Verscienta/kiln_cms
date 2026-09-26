defmodule KilnCMS.CMS.SiteVapidKey do
  @moduledoc """
  A site's own Web Push (VAPID) key pair (#1560), generated at
  `/editor/site-push` rather than pasted into `KILN_VAPID_*`.

  Part of #1322's per-site integrations. Read through `KilnCMS.Push.Keys`,
  which owns the precedence rule, the subscription binding and the fail
  direction; nothing else should read this row.

  ## Generated, never entered

  There is no key field on any form. `:save` creates the row and mints the
  pair on first use (`Changes.MintVapidKey`), the way *Generate* mints the
  DKIM key on `/editor/mail`, and a later `:save` or `:update` only edits the
  subject. `:rotate` is the one action that replaces a pair, and it is its own
  action so the intent is explicit.

  The public half is stored in cleartext: it is handed to every browser that
  subscribes. The private half is encrypted with `KilnCMS.Keys.Vault` into
  `private_key_encrypted`, typed `Vault.Ciphertext` so `mix
  kiln.vault.reencrypt` walks it across a `SECRET_KEY_BASE` rotation.

  ## Rotation drops the subscriptions made against the old key

  A browser's push subscription is bound to the `applicationServerKey` it was
  created with, and a push service rejects a message signed by any other key.
  So `:rotate` (and `:destroy`) deletes this site's subscriptions that were made
  against the key being replaced, in the same transaction
  (`Changes.DropVapidSubscriptions`). Nothing is left to be signed with a key
  it can't verify, and each reviewer re-enables notifications from *Your
  settings*. The page says so, with the device count, before it rotates.

  ## Who can write it

  Org admin, like every `KilnCMS.CMS.OrgSettings` resource, and reads are
  admin-only too.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_vapid_keys",
    accept: [:subject],
    save_changes: [KilnCMS.CMS.Changes.DefaultVapidSubject, KilnCMS.CMS.Changes.MintVapidKey],
    read: :admin

  actions do
    # Replace the pair. Every subscription made against the old public key is
    # deleted with it — see the moduledoc.
    update :rotate do
      description "Replace this site's VAPID key pair, dropping subscriptions bound to the old one."
      require_atomic? false
      accept []

      validate present(:public_key),
        message: "this site has no push key to replace yet"

      change {KilnCMS.CMS.Changes.MintVapidKey, rotate: true}
      change KilnCMS.CMS.Changes.DropVapidSubscriptions
    end
  end

  changes do
    # Removing the pair strands its subscriptions just as rotating does.
    change KilnCMS.CMS.Changes.DropVapidSubscriptions, on: [:destroy]
  end

  validations do
    # RFC 8292 §2.1: a contact the push service's operator can use.
    validate match(:subject, ~r{\A(mailto:[^\s@]+@[^\s@]+|https://[^\s]+)\z}),
      message: "must be a mailto: address or an https:// URL"
  end

  attributes do
    # Base64url, the uncompressed P-256 point (65 bytes). Handed to browsers as
    # `applicationServerKey`, and recorded on each subscription made against it.
    attribute :public_key, :string do
      writable? false
      public? true
      constraints max_length: 100
    end

    # Base64url of the 32-byte scalar, encrypted with `KilnCMS.Keys.Vault`.
    attribute :private_key_encrypted, KilnCMS.Keys.Vault.Ciphertext do
      writable? false
      public? false
      sensitive? true
    end

    # Who a push service's operator contacts about this site's traffic.
    # Defaults to the generating admin's address.
    attribute :subject, :string do
      public? true
      constraints max_length: 254
    end
  end
end
