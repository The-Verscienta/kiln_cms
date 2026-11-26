defmodule KilnCMS.Accounts.PasswordNotice do
  @moduledoc """
  A one-shot "that password is in a known breach" note carried from the moment
  a password is set to the sign-in that follows it (#2240).

  Registration and a password reset run inside upstream AshAuthentication.Phoenix
  components that drop the action's metadata, and both end by signing the
  person in. So `KilnCMS.Accounts.Changes.CheckBreachedPassword` leaves a note
  here when the action result says `password_breach`, and
  `KilnCMSWeb.AuthController` takes it at the matching *password* sign-in
  completion and turns it into a flash. Changing a password and the first-run
  wizard show their warning directly and never use this.

  ## Two kinds of note

  `:set` - the password just set is in a breach (register, reset). `:sign_in`
  - the password an administrator just signed in with is, on a site that
  checks at sign-in under `:warn` (#2407,
  `KilnCMS.Accounts.Preparations.CheckBreachedPasswordAtSignIn`): left by the
  action and taken by the same sign-in's completion. Each has its own
  `message/1`.

  ## What it holds

  The kind, keyed by user id, and nothing else: never the password, a hash,
  an email or an org. It lives in its own small `Cachex` (like the WebAuthn
  challenge store), not the shared content cache, which is bounded and evicts.
  The TTL is short (`ttl/0`, ten minutes by default): a note that is not taken
  by the sign-in right after the password was set is not worth showing later.

  ## Best-effort, by design

  The store is node-local. On a multi-node deployment without sticky routing the
  sign-in may land on a node that never saw the note, and the warning is simply
  not shown; a restart loses pending notes. The password was accepted and the
  check is advisory, so a missed warning is the right way to fail.
  `take/1` is atomic: a note is shown at most once.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  @cache :kiln_cms_password_notices
  @default_ttl :timer.minutes(10)

  @type kind :: :set | :sign_in

  @doc """
  The warning shown wherever a `:set` notice surfaces (a flash), in the
  current locale. One string, so the four places that show it cannot drift.
  """
  @spec message() :: String.t()
  def message, do: message(:set)

  @doc "The warning for a notice of `kind`, in the current locale."
  @spec message(kind()) :: String.t()
  def message(:set) do
    gettext(
      "That password appears in a public data breach. It was accepted, but consider choosing a different one."
    )
  end

  def message(:sign_in) do
    gettext(
      "Your password appears in a public data breach. Change it soon from your account page."
    )
  end

  @doc "The dedicated Cachex instance (supervised)."
  @spec cache() :: atom()
  def cache, do: @cache

  @doc "How long a note waits for the sign-in that takes it, in milliseconds."
  @spec ttl() :: pos_integer()
  def ttl, do: Application.get_env(:kiln_cms, __MODULE__, [])[:ttl] || @default_ttl

  @doc "Leave a `:set` note for `user_id`'s next password sign-in."
  @spec put(Ash.UUID.t()) :: :ok
  def put(user_id), do: put(user_id, :set)

  @doc "Leave a note of `kind` for `user_id`'s next password sign-in."
  @spec put(Ash.UUID.t(), kind()) :: :ok
  def put(user_id, kind) when is_binary(user_id) and kind in [:set, :sign_in] do
    Cachex.put(@cache, user_id, kind, expire: ttl())
    :ok
  end

  @doc """
  Consume the note for `user_id`: its kind once; `false` when absent, taken
  or expired. A bare `true` (written by a node from before the kinds) is a
  `:set` note.
  """
  @spec take(term()) :: kind() | false
  def take(user_id) when is_binary(user_id) do
    case Cachex.take(@cache, user_id) do
      {:ok, kind} when kind in [:set, :sign_in] -> kind
      {:ok, true} -> :set
      _absent -> false
    end
  end

  def take(_user_id), do: false
end
