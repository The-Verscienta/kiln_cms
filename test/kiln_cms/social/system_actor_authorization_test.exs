defmodule KilnCMS.Social.SystemActorAuthorizationTest do
  @moduledoc """
  #1659 batch 6: social auto-posting runs as `KilnCMS.Social.system/0` rather
  than `authorize?: false`.

  Every grant is paired with a refusal. The claim is the "announce once"
  guarantee, so a refused claim must post nothing and must not be read as
  "already announced", which is the answer the dedupe arm gives. Tested with
  the grant taken away (`Social.with_actor(nil, ...)`).
  """
  # async: false: turns the global cache off for one test.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.Social
  alias KilnCMS.Social.Announcer

  setup do
    test = self()

    Req.Test.stub(KilnCMS.Social, fn conn ->
      send(test, :provider_called)
      Req.Test.json(conn, %{"id" => "remote-1", "url" => "https://mastodon.test/@kiln/1"})
    end)

    %{org_id: KilnCMS.Accounts.default_org_id(), actor: user(:admin)}
  end

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sab6-social-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp published_post(ctx) do
    post =
      CMS.create_post!(
        %{title: "A published post", slug: "sab6-social-#{System.unique_integer([:positive])}"},
        actor: ctx.actor
      )

    CMS.publish_post!(post, actor: ctx.actor)
    Ash.reload!(post, authorize?: false, tenant: post.org_id)
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

  defp claim_attrs(account) do
    %{
      account_id: account.id,
      provider: account.provider,
      content_type: "post",
      content_id: Ecto.UUID.generate(),
      content_published_at: DateTime.utc_now(),
      text: "Hello",
      url: "https://example.test/hello"
    }
  end

  defp ledger(ctx), do: Social.list_posts!(actor: ctx.actor, tenant: ctx.org_id)

  describe "Social.Post" do
    test "the system actor claims a row and settles it every way", ctx do
      account = account(ctx)
      system = Social.system()
      opts = [actor: system, tenant: ctx.org_id]

      assert {:ok, post} = Social.claim_post(claim_attrs(account), opts)
      assert {:ok, %{state: :skipped}} = Social.skip_post(post, %{error: "x"}, opts)
      assert {:ok, %{state: :failed}} = Social.fail_post(post, %{error: "x"}, opts)
      assert {:ok, %{state: :unknown}} = Social.unresolved_post(post, %{error: "x"}, opts)

      assert {:ok, %{state: :posted}} =
               Social.succeed_post(post, %{remote_id: "r", remote_url: nil}, opts)
    end

    test "...and may not read or delete one", ctx do
      account = account(ctx)
      system = Social.system()
      {:ok, post} = Social.claim_post(claim_attrs(account), actor: system, tenant: ctx.org_id)

      assert_raise Ash.Error.Forbidden, fn ->
        Social.list_posts!(actor: system, authorize_with: :error, tenant: ctx.org_id)
      end

      refute Ash.can?({post, :destroy}, system, tenant: ctx.org_id)
      assert Ash.can?({post, :destroy}, ctx.actor, tenant: ctx.org_id)
    end

    test "an editor may not claim one", ctx do
      account = account(ctx)

      assert {:error, %Ash.Error.Forbidden{}} =
               Social.claim_post(claim_attrs(account), actor: user(:editor), tenant: ctx.org_id)
    end
  end

  describe "Social.Account" do
    test "the system actor stamps \"last posted\"", ctx do
      account = account(ctx)

      assert {:ok, stamped} =
               Social.record_account_post(account, actor: Social.system(), tenant: ctx.org_id)

      refute is_nil(stamped.last_posted_at)
    end

    test "...and may not mint, edit or delete credentials", ctx do
      account = account(ctx)
      system = Social.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               Social.create_account(
                 %{
                   provider: :mastodon,
                   handle: "evil",
                   instance_url: "https://mastodon.test",
                   credential: "t"
                 },
                 actor: system,
                 tenant: ctx.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Social.update_account(account, %{handle: "evil"},
                 actor: system,
                 tenant: ctx.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Social.destroy_account(account, actor: system, tenant: ctx.org_id)
    end
  end

  describe "fail closed" do
    test "a refused claim posts nothing and is not read as \"already announced\"", ctx do
      record = published_post(ctx)
      account = account(ctx)

      assert {:error, %Ash.Error.Forbidden{}} =
               Social.with_actor(nil, fn ->
                 Announcer.announce(record, account, automation_rule_id: nil)
               end)

      refute_received :provider_called
      assert ledger(ctx) == []
    end

    test "with the grant in place the same announce posts once and settles", ctx do
      record = published_post(ctx)
      account = account(ctx)

      assert {:ok, %{state: :posted}} =
               Announcer.announce(record, account, automation_rule_id: nil)

      assert_received :provider_called
      assert [%{state: :posted}] = ledger(ctx)

      # The account's "last posted" stamp is written as the system actor too.
      stamped = Social.get_account!(account.id, actor: ctx.actor, tenant: ctx.org_id)
      refute is_nil(stamped.last_posted_at)
    end

    # The read inside `configured?/1` runs in Cachex's courier process, which
    # does not see `with_actor/2`'s process-local override, so the cache is
    # switched off for this one.
    test "a refused accounts read answers \"not configured\" and says why", ctx do
      original = Application.get_env(:kiln_cms, KilnCMS.Cache, [])
      Application.put_env(:kiln_cms, KilnCMS.Cache, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Cache, original) end)

      account(ctx)
      assert Social.configured?(ctx.org_id)

      log =
        capture_log(fn ->
          refute Social.with_actor(nil, fn -> Social.configured?(ctx.org_id) end)
        end)

      assert log =~ "could not be read, not announcing"
    end
  end
end
