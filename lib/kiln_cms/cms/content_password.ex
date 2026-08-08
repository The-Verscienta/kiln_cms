defmodule KilnCMS.CMS.ContentPassword do
  @moduledoc """
  Shared-passphrase locking for **published** content (#496) — the WordPress
  "password protected post" / Squarespace lock-page analogue.

  This is deliberately **weak** access control and the docs say so. A shared
  secret typed into a public form has no per-reader identity, no revocation
  beyond rotation, and no audit trail. It exists for editorial convenience — a
  client proposal page, an early-access announcement — and
  `KilnCMS.CMS.Audiences` remains the real access-control axis. The two are
  independent and *compose by AND*: a locked record inside a gated audience
  needs both the audience and the passphrase.

  ## The three values, and why there are three

  Locking a record stores a bcrypt **hash** of the passphrase, plus a
  **fingerprint** — `sha256(hash)`, url-safe base64.

  The fingerprint exists because the hash must never leave the server. A grant
  has to travel back to Kiln on the next request, and a bcrypt hash in a signed
  (but readable) cookie or token would hand an attacker an offline cracking
  target on the strength of one correct guess. The fingerprint is one-way,
  useless for cracking, and identifies *this record's current passphrase*:
  bcrypt salts per record, so two documents sharing a passphrase still have
  different hashes and therefore different fingerprints.

  It also gives rotation for free. A grant names a fingerprint; changing the
  passphrase changes the hash, which changes the fingerprint, which no longer
  matches — so every outstanding grant stops working at the moment of rotation
  **inside the read filter**, not in a controller check somebody could forget.

  ## Grants

  A grant is a `Phoenix.Token` over a fingerprint — signed, short-lived, no
  storage. It is minted only by the unlock endpoints, only after
  `verify/2` returns true.

  On the built-in site the grants live in one signed, http-only cookie
  (`KilnCMSWeb.ContentLock`), which is a **strictly-necessary** cookie the
  visitor creates by typing a passphrase: it carries no visitor identifier and
  nothing that could be joined to one — only which documents this browser has
  unlocked. `docs/data-flows.md` records it.

  Headless callers hold the token themselves and present it per request, the
  same shape as `KilnCMS.CMS.PreviewToken`.
  """

  @salt "content unlock"

  # A grant outlives a reading session but not a working day. Long enough that a
  # reader is not re-prompted while they read; short enough that a leaked link,
  # or a laptop left open, is not an indefinite grant. Rotation cuts it shorter
  # (see the fingerprint above), which is the control an editor actually has.
  @max_age_seconds 60 * 60 * 12

  @doc """
  Hash a passphrase. `nil` and blank return `nil`, meaning "no lock" — so a
  blank field in the editor never stores an empty-string hash that
  `Bcrypt.verify_pass/2` would then be asked to match.
  """
  @spec hash(String.t() | nil) :: String.t() | nil
  def hash(nil), do: nil

  def hash(passphrase) when is_binary(passphrase) do
    case String.trim(passphrase) do
      "" -> nil
      trimmed -> Bcrypt.hash_pwd_salt(trimmed)
    end
  end

  @doc """
  Whether `passphrase` matches `hash`.

  An unlocked record (`hash` is `nil`) still burns a dummy verification before
  answering, so the response time of "this document has no passphrase" is not
  distinguishable from "that passphrase is wrong" — otherwise the unlock
  endpoint doubles as an oracle for which documents are locked.
  """
  @spec verify(String.t() | nil, term()) :: boolean()
  def verify(hash, passphrase) when is_binary(hash) and is_binary(passphrase) do
    Bcrypt.verify_pass(String.trim(passphrase), hash)
  end

  def verify(_hash, _passphrase) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  The fingerprint of a stored hash — the value a grant names. `nil` in, `nil`
  out, so an unlocked record has no fingerprint to match against.
  """
  @spec fingerprint(String.t() | nil) :: String.t() | nil
  def fingerprint(nil), do: nil

  def fingerprint(hash) when is_binary(hash) do
    :crypto.hash(:sha256, hash) |> Base.url_encode64(padding: false)
  end

  @doc "Mint a grant for a fingerprint."
  @spec sign(String.t()) :: String.t()
  def sign(fingerprint) when is_binary(fingerprint) do
    Phoenix.Token.sign(KilnCMSWeb.Endpoint, @salt, fingerprint)
  end

  @doc """
  Verify a grant, returning `{:ok, fingerprint}` or an error (`:invalid` /
  `:expired`).
  """
  @spec verify_grant(term()) :: {:ok, String.t()} | {:error, atom()}
  def verify_grant(token) when is_binary(token) do
    Phoenix.Token.verify(KilnCMSWeb.Endpoint, @salt, token, max_age: @max_age_seconds)
  end

  def verify_grant(_), do: {:error, :invalid}

  @doc "How long a grant stays valid, in seconds."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @max_age_seconds
end
