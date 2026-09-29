defmodule KilnCMS.Social.Announcer do
  @moduledoc """
  Claims a ledger row, composes the text, and posts it (#497).

  The order is the design. `Social.Post` is inserted first, in `:claimed`, and
  its unique identity is what makes "announce once" true under concurrency —
  two workers race the insert and Postgres picks one. Only the winner calls the
  provider. See `KilnCMS.Social.Post` for why a crash between the two is the
  failure mode worth having.

  ## What is never announced

  Three refusals, each recorded as a `:skipped` ledger row rather than dropped,
  so an operator asking "why didn't this post?" finds the answer in the same
  place as everything else:

    * **Gated content** (`audience != :public`) — an announcement is a push to
      strangers' timelines carrying the title and a link. A members-only
      document is not for strangers.
    * **Passphrase-locked content** (#496) — same reasoning, one step stronger:
      the whole point of the lock is that the URL alone is not enough, and
      broadcasting the URL is the loudest possible way to ignore that.
    * **Non-default locales** — every locale variant's publish emits its own
      event, so without this one article published in three languages posts
      three times. The same guard the newsletter reaction draws, for the same
      reason.

  Draft, scheduled and unpublished content never reaches here at all: the
  reaction is wired to the `published` trigger.
  """
  require Logger

  alias KilnCMS.Social
  alias KilnCMS.Social.Account
  alias KilnCMS.Social.Composer

  @providers %{
    bluesky: KilnCMS.Social.Providers.Bluesky,
    mastodon: KilnCMS.Social.Providers.Mastodon
  }

  @doc "The implementing module for a provider name, or `nil`."
  @spec provider_module(atom()) :: module() | nil
  def provider_module(name), do: Map.get(@providers, name)

  @doc """
  Announce `record` to `account`.

  `opts` takes `:automation_rule_id` (part of the dedupe key) and `:template`.
  Returns `{:ok, post}`, `{:error, :already_announced}` when the claim was
  already taken, or `{:error, reason}`.
  """
  @spec announce(struct(), Account.t(), keyword()) ::
          {:ok, struct()} | {:error, :already_announced | term()}
  def announce(record, account, opts \\ []) do
    with {:ok, module} <- module_for(account),
         {:ok, post} <- claim(record, account, opts, module) do
      case refusal(record) do
        nil -> deliver(post, account, module)
        reason -> skip(post, reason)
      end
    end
  end

  defp module_for(%{provider: provider}) do
    case provider_module(provider) do
      nil -> {:error, {:no_such_provider, provider}}
      module -> {:ok, module}
    end
  end

  # The text is composed BEFORE the claim so the ledger row records exactly what
  # was sent, even for a row that ends up `:skipped` — "what would this have
  # said" is the first question anyone asks about a skip.
  defp claim(record, account, opts, module) do
    url = KilnCMS.Social.canonical_url(record)

    attrs = %{
      account_id: account.id,
      provider: account.provider,
      content_type: record |> KilnCMS.Firing.Engine.public_type() |> to_string(),
      content_id: record.id,
      content_published_at: Map.get(record, :published_at),
      automation_rule_id: opts[:automation_rule_id],
      text: Composer.compose(record, url, module.max_length(), opts[:template]),
      url: url
    }

    # Claimed as `Social.system/0` (#1659). A refused claim is an
    # `Ash.Error.Forbidden`, which falls through to `other` below: nothing is
    # posted, and the rule worker logs the error. It must never be read as
    # "already announced", which is why the dedupe arm matches the unique
    # index by name and nothing broader.
    case Social.claim_post(attrs, actor: Social.system(), tenant: record.org_id) do
      {:ok, post} ->
        {:ok, post}

      # The unique identity refused it: something already claimed this
      # {account, document, publish}. Not an error worth retrying — it is the
      # guarantee working.
      {:error, %Ash.Error.Invalid{errors: errors}} = error ->
        if announce_conflict?(errors), do: {:error, :already_announced}, else: error

      other ->
        other
    end
  end

  # Matched on the CONSTRAINT NAME, not on the error struct and not on the
  # message.
  #
  # Matching the struct alone (`%InvalidAttribute{}`) swallows every ordinary
  # validation failure as "already announced" — a missing required field would
  # read as a successful dedupe and the announcement would vanish with no error
  # anywhere. Matching the message ("has already been taken") is a English
  # string that a locale or an Ash release can change underneath this.
  #
  # The constraint name is the one part of the signal that is ours.
  @announce_index "social_posts_announce_once_index"

  defp announce_conflict?(errors) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{private_vars: vars} when is_list(vars) ->
        vars[:constraint_type] == :unique and vars[:constraint] == @announce_index

      _other ->
        false
    end)
  end

  defp deliver(post, account, module) do
    announcement = %{text: post.text, url: post.url, idempotency_key: post.id}

    case module.post(account, announcement) do
      {:ok, %{id: id} = result} ->
        account
        |> Social.record_account_post(actor: Social.system(), tenant: account.org_id)
        |> log_unrecorded(post, "the account's last-posted stamp")

        post
        |> Social.succeed_post(%{remote_id: id, remote_url: result[:url]},
          actor: Social.system(),
          tenant: post.org_id
        )
        |> log_unrecorded(post, "the success")

      {:error, {:failed, reason}} ->
        post
        |> Social.fail_post(%{error: reason}, actor: Social.system(), tenant: post.org_id)
        |> log_unrecorded(post, "the failure")

      # Ambiguous: the post may exist. Recorded and left alone — see the ledger's
      # moduledoc for why this is never retried.
      {:error, :unknown} ->
        Logger.warning(
          "Social post to #{account.provider} for #{post.content_type}/#{post.content_id} " <>
            "did not resolve — recorded as unknown, not retried"
        )

        post
        |> Social.unresolved_post(%{error: "no confirmation from provider"},
          actor: Social.system(),
          tenant: post.org_id
        )
        |> log_unrecorded(post, "the unknown outcome")
    end
  end

  defp skip(post, reason) do
    post
    |> Social.skip_post(%{error: reason}, actor: Social.system(), tenant: post.org_id)
    |> log_unrecorded(post, "the skip")
  end

  # The settling writes run as `Social.system/0` (#1659). One that fails leaves
  # the row `:claimed`, which still holds the dedupe key, so nothing can post
  # twice; but the ledger no longer says what happened, so say it here. The
  # result is passed through unchanged.
  defp log_unrecorded({:ok, _record} = ok, _post, _what), do: ok

  defp log_unrecorded({:error, error} = failed, post, what) do
    Logger.error(
      "Social post #{post.id} (#{post.content_type}/#{post.content_id}): " <>
        "#{what} not recorded on the ledger: " <> Exception.message(error)
    )

    failed
  end

  defp refusal(record) do
    cond do
      Map.get(record, :audience, :public) != :public ->
        "not announced: the document is audience-gated"

      not is_nil(Map.get(record, :access_password_hash)) ->
        "not announced: the document is passphrase-locked"

      Map.get(record, :locale, KilnCMS.I18n.default_locale()) != KilnCMS.I18n.default_locale() ->
        "not announced: not the default locale variant"

      true ->
        nil
    end
  end
end
