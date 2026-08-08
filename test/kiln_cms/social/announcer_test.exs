defmodule KilnCMS.Social.AnnouncerTest do
  @moduledoc """
  Social auto-posting (#497): the at-most-once guarantee, what is never
  announced, and how each provider's outcomes land in the ledger.

  The at-most-once tests are the load-bearing ones. A duplicate announcement
  cannot be quietly undone — it is on the operator's public timeline in front of
  their audience — so "posted twice" is a worse bug here than "posted never".
  """
  use KilnCMS.DataCase, async: false

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.Social
  alias KilnCMS.Social.Announcer
  alias KilnCMS.Social.Providers.Bluesky

  setup do
    Req.Test.stub(KilnCMS.Social, fn conn -> Req.Test.json(conn, %{}) end)
    %{org_id: KilnCMS.Accounts.default_org_id(), actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "social-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "social-#{System.unique_integer([:positive])}"

  defp published_post(ctx, attrs \\ %{}) do
    post =
      CMS.create_post!(
        Map.merge(%{title: "A published post", slug: slug()}, attrs),
        actor: ctx.actor
      )

    CMS.publish_post!(post, actor: ctx.actor)
    Ash.reload!(post, authorize?: false, tenant: post.org_id)
  end

  defp account(ctx, attrs \\ %{}) do
    Social.create_account!(
      Map.merge(
        %{
          provider: :mastodon,
          handle: "kiln",
          instance_url: "https://mastodon.test",
          credential: "a-token"
        },
        attrs
      ),
      actor: ctx.actor,
      tenant: ctx.org_id
    )
  end

  defp ledger(ctx) do
    Social.list_posts!(authorize?: false, tenant: ctx.org_id)
  end

  # ── At most once ────────────────────────────────────────────────────────────

  describe "at most once" do
    test "a second announce for the same publish is refused", ctx do
      record = published_post(ctx)
      account = account(ctx)

      assert {:ok, _post} = Announcer.announce(record, account, automation_rule_id: nil)

      # Same {rule, account, document, publish}: the unique identity refuses the
      # claim, so the provider is never called a second time.
      assert {:error, :already_announced} =
               Announcer.announce(record, account, automation_rule_id: nil)

      assert length(ledger(ctx)) == 1
    end

    test "a genuinely new publish announces again", ctx do
      record = published_post(ctx)
      account = account(ctx)

      assert {:ok, _} = Announcer.announce(record, account, automation_rule_id: nil)

      # `content_published_at` is part of the key, so a fresh publish is a
      # different claim — an unpublish/republish cycle is a real announcement.
      republished = %{record | published_at: DateTime.utc_now()}
      assert {:ok, _} = Announcer.announce(republished, account, automation_rule_id: nil)

      assert length(ledger(ctx)) == 2
    end

    test "the claim exists BEFORE the request goes out", ctx do
      record = published_post(ctx)
      account = account(ctx)
      test_pid = self()

      # The ordering is the guarantee. Asked from inside the request itself:
      # if the row were written afterwards, two concurrent workers would both
      # pass a check-then-act and both post.
      Req.Test.stub(KilnCMS.Social, fn conn ->
        send(
          test_pid,
          {:claimed_rows,
           length(
             Social.list_posts!(
               authorize?: false,
               tenant: KilnCMS.Accounts.default_org_id()
             )
           )}
        )

        Req.Test.json(conn, %{"id" => "1"})
      end)

      Announcer.announce(record, account, automation_rule_id: nil)

      assert_received {:claimed_rows, 1}
    end

    test "two announces for the same publish post once, whatever the rule", ctx do
      record = published_post(ctx)
      account = account(ctx)

      assert {:ok, _} =
               Announcer.announce(record, account, automation_rule_id: Ash.UUID.generate())

      # Two rules pointed at the same account are still one document and one
      # publish — the duplicate this exists to prevent.
      assert {:error, :already_announced} =
               Announcer.announce(record, account, automation_rule_id: Ash.UUID.generate())

      assert length(ledger(ctx)) == 1
    end

    test "a real validation error is NOT reported as a duplicate", ctx do
      account = account(ctx)
      # A cast failure on `content_id` — an `InvalidAttribute`, exactly like a
      # unique-constraint violation, but not this one.
      record = %{published_post(ctx) | id: "not-a-uuid"}

      result = Announcer.announce(record, account, automation_rule_id: nil)

      # The regression this pins: conflict detection used to match any
      # `InvalidAttribute`, so an ordinary validation failure came back as
      # `:already_announced` — the announcement vanished and the ledger showed
      # a successful dedupe that never happened.
      refute result == {:error, :already_announced}
      assert {:error, _} = result
      assert ledger(ctx) == []
    end
  end

  # ── What is never announced ─────────────────────────────────────────────────

  describe "refusals" do
    test "audience-gated content is skipped, not posted", ctx do
      record = published_post(ctx, %{audience: :member})

      assert {:ok, post} = Announcer.announce(record, account(ctx), automation_rule_id: nil)

      assert post.state == :skipped
      assert post.error =~ "audience-gated"
    end

    test "passphrase-locked content is skipped, not posted", ctx do
      record = published_post(ctx, %{access_password: "shared secret"})

      assert {:ok, post} = Announcer.announce(record, account(ctx), automation_rule_id: nil)

      # #496: the point of the lock is that the URL alone is not enough, and
      # broadcasting the URL is the loudest way to ignore that.
      assert post.state == :skipped
      assert post.error =~ "passphrase-locked"
    end

    test "a non-default locale variant is skipped", ctx do
      record = published_post(ctx, %{locale: "fr"})

      assert {:ok, post} = Announcer.announce(record, account(ctx), automation_rule_id: nil)

      # Otherwise one article published in three languages posts three times.
      assert post.state == :skipped
      assert post.error =~ "default locale"
    end

    test "a skip still records what would have been posted", ctx do
      record = published_post(ctx, %{audience: :member, title: "Members only"})

      assert {:ok, post} = Announcer.announce(record, account(ctx), automation_rule_id: nil)

      assert post.text =~ "Members only"
    end
  end

  # ── Provider outcomes ───────────────────────────────────────────────────────

  describe "outcomes" do
    test "a successful post records the remote id", ctx do
      Req.Test.stub(KilnCMS.Social, fn conn ->
        Req.Test.json(conn, %{"id" => "12345", "url" => "https://mastodon.test/@kiln/12345"})
      end)

      assert {:ok, post} =
               Announcer.announce(published_post(ctx), account(ctx), automation_rule_id: nil)

      assert post.state == :posted
      assert post.remote_id == "12345"
      assert post.remote_url == "https://mastodon.test/@kiln/12345"
      assert post.posted_at
    end

    test "a 4xx is a definite failure, safe to re-trigger", ctx do
      Req.Test.stub(KilnCMS.Social, fn conn -> Plug.Conn.send_resp(conn, 422, "nope") end)

      assert {:ok, post} =
               Announcer.announce(published_post(ctx), account(ctx), automation_rule_id: nil)

      assert post.state == :failed
    end

    test "a 5xx is UNKNOWN, not failed — it may have posted", ctx do
      Req.Test.stub(KilnCMS.Social, fn conn -> Plug.Conn.send_resp(conn, 503, "later") end)

      assert {:ok, post} =
               Announcer.announce(published_post(ctx), account(ctx), automation_rule_id: nil)

      # Calling this `:failed` is what turns one timeout into two posts: an
      # operator (or a retry) would re-trigger something that already landed.
      assert post.state == :unknown
    end

    test "a transport failure is UNKNOWN for the same reason", ctx do
      Req.Test.stub(KilnCMS.Social, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:ok, post} =
               Announcer.announce(published_post(ctx), account(ctx), automation_rule_id: nil)

      assert post.state == :unknown
    end

    test "an account whose credential cannot be decrypted fails, and posts nothing", ctx do
      account = account(ctx)

      # Simulates a restored backup or a rotated secret_key_base: the account row
      # survives, the credential does not.
      broken = %{account | credential_encrypted: <<0, 1, 2>>}

      assert {:ok, post} =
               Announcer.announce(published_post(ctx), broken, automation_rule_id: nil)

      assert post.state == :failed
    end
  end

  # ── Bluesky facets ──────────────────────────────────────────────────────────

  describe "Bluesky link facets" do
    test "offsets are BYTES, not characters" do
      url = "https://example.test/x"
      # An em dash is 3 bytes and 1 character. A character-offset implementation
      # passes every ASCII test anyone writes by hand and then silently points
      # the link at the wrong span on the first title with punctuation in it.
      text = "A — title\n\n" <> url

      assert [%{"index" => %{"byteStart" => start, "byteEnd" => stop}}] =
               Bluesky.link_facets(text, url)

      assert start == byte_size("A — title\n\n")
      assert stop == start + byte_size(url)
      refute start == String.length("A — title\n\n")
      assert binary_part(text, start, stop - start) == url
    end

    test "no facet when the URL is not in the text" do
      assert Bluesky.link_facets("no link here", "https://example.test/x") == []
    end

    test "no facet for an empty URL" do
      assert Bluesky.link_facets("some text", "") == []
    end
  end
end
