defmodule KilnCMS.Social.ReactionTest do
  @moduledoc """
  The `:social_post` automation reaction end to end (#497): publish a document
  and watch the announcement come out the other side of the real event → rule →
  Oban chain, rather than by calling the announcer directly.

  The unit tests in `KilnCMS.Social.AnnouncerTest` prove the announcer behaves;
  these prove it is actually *wired* — a reaction that is never reached looks
  identical to one that works, from the announcer's point of view.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Automation
  alias KilnCMS.CMS
  alias KilnCMS.Social

  setup do
    Req.Test.stub(KilnCMS.Social, fn conn ->
      Req.Test.json(conn, %{"id" => "remote-1", "url" => "https://mastodon.test/@kiln/1"})
    end)

    org_id = KilnCMS.Accounts.default_org_id()
    Social.bust(org_id)
    on_exit(fn -> Social.bust(org_id) end)

    %{org_id: org_id, actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "react-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp account(ctx) do
    Social.create_account!(
      %{
        provider: :mastodon,
        handle: "kiln",
        instance_url: "https://mastodon.test",
        credential: "a-token"
      },
      actor: ctx.actor,
      tenant: ctx.org_id
    )
  end

  defp rule(ctx, config \\ %{"provider" => "mastodon"}) do
    Automation.create_rule!(
      %{
        name: "Announce",
        trigger_event: :published,
        action: :social_post,
        config: config
      },
      actor: ctx.actor,
      tenant: ctx.org_id
    )
  end

  defp publish(ctx, attrs \\ %{}) do
    post =
      CMS.create_post!(
        Map.merge(
          %{title: "Announce me", slug: "react-#{System.unique_integer([:positive])}"},
          attrs
        ),
        actor: ctx.actor
      )

    CMS.publish_post!(post, actor: ctx.actor)
    drain_oban()
    post
  end

  defp ledger(ctx), do: Social.list_posts!(authorize?: false, tenant: ctx.org_id)

  test "publishing announces to the configured account", ctx do
    account(ctx)
    rule(ctx)

    post = publish(ctx)

    assert [entry] = ledger(ctx)
    assert entry.state == :posted
    assert entry.content_id == post.id
    assert entry.remote_id == "remote-1"
    assert entry.text =~ "Announce me"
  end

  test "a re-fire of the same publish does not announce twice", ctx do
    account(ctx)
    rule(ctx)

    post = publish(ctx)

    # An in-place edit of a live record re-fires and re-emits `post.updated`;
    # a redelivered Oban job replays `post.published`. Neither may re-announce.
    KilnCMS.Automation.handle_event(
      "post.published",
      %{"id" => post.id, "slug" => post.slug, "title" => post.title},
      ctx.org_id
    )

    drain_oban()

    assert length(ledger(ctx)) == 1
  end

  test "nothing is announced when no account is configured", ctx do
    rule(ctx)

    publish(ctx)

    assert ledger(ctx) == []
  end

  test "a rule naming an unknown provider announces nothing", ctx do
    account(ctx)
    rule(ctx, %{"provider" => "myspace"})

    publish(ctx)

    # Refused at the string→atom boundary rather than turned into an atom, so a
    # typo in a config map cannot mint one.
    assert ledger(ctx) == []
  end

  test "a disabled account is not announced to", ctx do
    ctx |> account() |> Social.update_account!(%{enabled: false}, actor: ctx.actor)
    rule(ctx)

    publish(ctx)

    assert ledger(ctx) == []
  end

  test "a locked document is recorded as skipped, not posted", ctx do
    account(ctx)
    rule(ctx)

    publish(ctx, %{access_password: "shared secret"})

    assert [entry] = ledger(ctx)
    assert entry.state == :skipped
  end

  test "the rule's template is used", ctx do
    account(ctx)
    rule(ctx, %{"provider" => "mastodon", "template" => "New: {{title}} {{url}}"})

    publish(ctx)

    assert [entry] = ledger(ctx)
    assert String.starts_with?(entry.text, "New: Announce me http")
  end
end
