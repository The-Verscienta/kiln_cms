defmodule KilnCMS.LimitsTest do
  @moduledoc """
  Every public string attribute in the tree is either bounded (#542) or named
  here as deliberately unbounded.

  This is the part that makes the sweep stick. Adding an unbounded
  `public?: true` string attribute now fails the build until somebody either
  gives it a ceiling from `KilnCMS.Limits` or adds it below with a reason — so
  the next one is a decision rather than an oversight.

  Adding a row here is cheap and entirely legitimate. The point is only that it
  cannot happen by accident.
  """
  use ExUnit.Case, async: true

  # Server-derived, provider-derived, or diagnostic. None of these carries text
  # a user typed, and a ceiling would turn an internal invariant into a runtime
  # failure — a hash that outgrew its bound, or a ledger row refused because the
  # remote error it is recording was long, which is exactly when you want the
  # row most.
  #
  # Grouped by why:
  #
  #   * `content_type` / `resource_type` / `target_type` / `event` / `purpose` /
  #     `strategy` — internal type and verb names, written from a fixed set.
  #   * `chain_hash` / `signature` / `root` / `*_digest` / `attribution_hash` /
  #     `content_hash` / `key_id` / `jti` — cryptographic material and
  #     identifiers, fixed-width by construction.
  #   * `provider_*_id` / `type` on billing — Stripe's identifiers, whose format
  #     is Stripe's to change.
  #   * `*_error` / `failure_reason` / `witness` — diagnostics. Refusing to
  #     record an outcome because its explanation was long is the wrong failure.
  #   * `public_key_pem` / `dkim_public_key` — PEM blocks, server-generated.
  #   * `block_key` / `ancestor_context` — internal search index, derived from
  #     content that is itself bounded.
  #   * `server_ip` / `subject` — server-observed.
  @unbounded [
    {KilnCMS.Accounts.Token, :jti},
    {KilnCMS.Accounts.Token, :purpose},
    {KilnCMS.Accounts.Token, :subject},
    {KilnCMS.Accounts.UserIdentity, :strategy},
    {KilnCMS.Analytics.ContentView, :content_type},
    {KilnCMS.Analytics.ContentViewDay, :content_type},
    {KilnCMS.Analytics.FunnelStep, :content_type},
    {KilnCMS.Analytics.ReferrerDay, :content_type},
    {KilnCMS.Automation.Rule, :content_type},
    {KilnCMS.Billing.MembershipEvent, :provider_event_id},
    {KilnCMS.Billing.MembershipTier, :provider_price_id},
    {KilnCMS.Billing.Settings, :provider_account_id},
    {KilnCMS.Billing.Settings, :verification_error},
    {KilnCMS.Billing.WebhookEvent, :error},
    {KilnCMS.Billing.WebhookEvent, :provider_event_id},
    {KilnCMS.Billing.WebhookEvent, :type},
    {KilnCMS.CMS.ChainCheckpoint, :key_id},
    {KilnCMS.CMS.ChainCheckpoint, :prev_checkpoint_digest},
    {KilnCMS.CMS.ChainCheckpoint, :root},
    {KilnCMS.CMS.ChainCheckpoint, :signature},
    {KilnCMS.CMS.ChainCheckpoint, :witness},
    {KilnCMS.CMS.ChainCheckpoint, :witness_error},
    {KilnCMS.CMS.ChainCheckpointEntry, :chain_hash},
    {KilnCMS.CMS.ChainCheckpointEntry, :resource_type},
    {KilnCMS.CMS.Comment, :content_type},
    {KilnCMS.CMS.Consent, :content_type},
    {KilnCMS.CMS.ContentRelease, :failure_reason},
    {KilnCMS.CMS.FieldDefinition, :target_type},
    {KilnCMS.CMS.HistoryAnchor, :attribution_hash},
    {KilnCMS.CMS.HistoryAnchor, :chain_hash},
    {KilnCMS.CMS.HistoryAnchor, :key_id},
    {KilnCMS.CMS.HistoryAnchor, :prev_anchor_digest},
    {KilnCMS.CMS.HistoryAnchor, :resource_type},
    {KilnCMS.CMS.HistoryAnchor, :signature},
    {KilnCMS.CMS.MenuItem, :target_type},
    {KilnCMS.CMS.Redirect, :target_type},
    {KilnCMS.CMS.ReleaseItem, :content_type},
    {KilnCMS.CMS.Task, :content_type},
    {KilnCMS.CMS.WebhookDelivery, :event},
    {KilnCMS.CMS.WebhookDelivery, :last_error},
    {KilnCMS.Experiments.Experiment, :content_type},
    {KilnCMS.Experiments.Experiment, :goal_content_type},
    {KilnCMS.Federation.Delivery, :last_error},
    {KilnCMS.Federation.SiteFederation, :public_key_pem},
    {KilnCMS.Mail.Settings, :dkim_public_key},
    {KilnCMS.Mail.Settings, :server_ip},
    {KilnCMS.Newsletter.NewsletterSend, :content_type},
    {KilnCMS.Search.BlockEmbedding, :ancestor_context},
    {KilnCMS.Search.BlockEmbedding, :block_key},
    {KilnCMS.Search.BlockEmbedding, :content_hash},
    {KilnCMS.Social.Post, :content_type},
    {KilnCMS.Social.Post, :error},
    {KilnCMS.Social.Post, :remote_id}
  ]

  test "every public string attribute is bounded, or listed as deliberately not" do
    unbounded =
      for domain <- Application.get_env(:kiln_cms, :ash_domains, []),
          resource <- Ash.Domain.Info.resources(domain),
          attribute <- Ash.Resource.Info.attributes(resource),
          attribute.public?,
          attribute.type == Ash.Type.String,
          is_nil(Keyword.get(attribute.constraints || [], :max_length)),
          do: {resource, attribute.name}

    unexpected = Enum.uniq(unbounded) -- @unbounded

    assert unexpected == [],
           """
           These public string attributes have no `max_length` and are not on the
           deliberately-unbounded list:

           #{Enum.map_join(unexpected, "\n", fn {r, a} -> "  #{inspect(r)}.#{a}" end)}

           Give each one a ceiling from `KilnCMS.Limits`, or add it to
           `@unbounded` in this file with the reason it does not need one.
           """
  end

  test "the list has no stale entries" do
    bounded_now =
      for {resource, name} <- @unbounded,
          attribute = Ash.Resource.Info.attribute(resource, name),
          is_nil(attribute) or not is_nil(Keyword.get(attribute.constraints || [], :max_length)),
          do: {resource, name}

    # A row that has since been bounded (or deleted) is worse than useless: it
    # silently exempts a name that may come back on a different attribute.
    assert bounded_now == [],
           "These are on the deliberately-unbounded list but no longer need to be: " <>
             inspect(bounded_now)
  end

  test "the ceilings are ordered and distinct" do
    assert KilnCMS.Limits.all() == Enum.sort(Enum.uniq(KilnCMS.Limits.all()))
    assert KilnCMS.Limits.identifier() < KilnCMS.Limits.line()
    assert KilnCMS.Limits.line() < KilnCMS.Limits.url()
    assert KilnCMS.Limits.url() < KilnCMS.Limits.paragraph()
  end
end
