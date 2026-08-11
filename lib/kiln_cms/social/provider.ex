defmodule KilnCMS.Social.Provider do
  @moduledoc """
  What a social network has to implement to be postable from Kiln (#497).

  Two implementations ship in core — `KilnCMS.Social.Providers.Bluesky` and
  `KilnCMS.Social.Providers.Mastodon` — chosen because their APIs are open,
  stable, free, and need no app-review process. X, LinkedIn and Facebook are
  deliberately **not** here: their APIs are volatile, paid and gated behind
  review, so they belong in a plugin implementing this behaviour rather than in
  a core module whose breakage every deployment inherits.

  ## The contract is narrow on purpose

  `post/2` takes a composed string and a canonical URL and answers with a remote
  id. There is no threading, no media upload, no scheduling and no editing,
  because the reaction that calls this exists to *announce* a publish. Anything
  richer is a social-media tool, and Kiln is not one.

  ## `{:error, :unknown}` means "we do not know", and that matters

  A provider must distinguish three outcomes, because the caller's at-most-once
  guarantee is built on the distinction:

    * `{:ok, result}` — posted; `result.id` is the remote id.
    * `{:error, {:failed, reason}}` — definitely **not** posted. The request was
      refused before anything was created (bad credentials, malformed body, a
      4xx). Safe to surface as a failure the operator can fix and re-trigger.
    * `{:error, :unknown}` — the request may or may not have created a post. A
      timeout after the bytes went out, a 5xx, a connection reset mid-response.

  `:unknown` must never be retried automatically. A duplicate announcement is
  worse than a missing one: the missing one is invisible, and the duplicate is
  on the operator's public timeline, in front of their audience, forever. The
  ledger records it as `:unknown` and waits for a human.

  A provider that cannot tell the difference should answer `:unknown` — guessing
  `:failed` is what turns one timeout into two posts.
  """

  @typedoc """
  A composed announcement: the text as it will appear, the canonical URL, and
  the ledger row's id.

  The id travels with the announcement so a provider that supports server-side
  idempotency (Mastodon does) can hand it over — it is a property of *this
  attempt*, not of the account, and putting it on the account would have made
  two concurrent posts share a key.
  """
  @type announcement :: %{text: String.t(), url: String.t(), idempotency_key: String.t()}

  @typedoc "Where the announcement landed."
  @type result :: %{id: String.t(), url: String.t() | nil}

  @typedoc """
  `{:failed, reason}` is a definite non-post; `:unknown` means the request may
  have succeeded and must not be retried without a human.
  """
  @type error :: {:failed, String.t()} | :unknown

  @doc "Post an announcement using this account's stored credential."
  @callback post(account :: struct(), announcement()) :: {:ok, result()} | {:error, error()}

  @doc """
  Check that an account's credentials work, without posting anything.

  Called from the settings UI so an operator finds out their app password is
  wrong when they save it, rather than the next time they publish.
  """
  @callback verify(account :: struct()) :: :ok | {:error, String.t()}

  @doc "The longest post this provider accepts, in characters."
  @callback max_length() :: pos_integer()
end
