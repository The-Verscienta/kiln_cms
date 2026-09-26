defmodule KilnCMS.Mail.SiteSuppressionTest do
  @moduledoc """
  Per-site bounce suppression (#1562): a site's own relay's recipient rejects
  land on that site's list (`KilnCMS.Mail.SiteSuppressedRecipient`), and that
  list stops only that site's mail.

  What each group pins:

    * **whose word, which list** — a site relay's reject naming the recipient
      writes the site's list and never the instance-wide one; the operator's
      relay writes the instance-wide list and never a site's; a refusal of our
      side (AUTH, the session) or a reject that doesn't name the recipient
      writes neither.
    * **isolation** — site A's entry never stops site B's mail, the operator's
      account mail, or anything without a site.
    * **authorization** — the list is read and cleared by that site's admins
      only; nobody writes it but the pipeline.
    * **the delivery panel** — a site's recent failures are its own, bounces
      only, by domain.
  """
  use KilnCMS.DataCase, async: true

  import Swoosh.Email, except: [from: 2]

  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Mail
  alias KilnCMS.Mail.DeliveryWorker

  defmodule ErrorAdapter do
    use Swoosh.Adapter

    def deliver(_email, config), do: {:error, Keyword.fetch!(config, :error)}
  end

  @dead "dead@example.com"

  # A RCPT reject in the mail transaction, naming the recipient.
  @recipient_reject {:send,
                     {:permanent_failure, ~c"smtp.example.com",
                      "550 5.1.1 <dead@example.com>: Recipient address rejected"}}

  setup do
    %{site_a: KilnCMS.OrgFixtures.org("supp-a"), site_b: KilnCMS.OrgFixtures.org("supp-b")}
  end

  defp relay!(org) do
    CMS.save_site_mail_relay!(
      %{host: "smtp.example.com", port: 587, from_email: "news@site.example"},
      tenant: org,
      authorize?: false
    )
  end

  defp email(to \\ @dead) do
    new()
    |> Swoosh.Email.from({"KilnCMS", "cms@operator.example"})
    |> to(to)
    |> subject("Hello")
    |> text_body("Hi")
  end

  defp deliver(opts), do: Mail.deliver_for_worker(email(), [adapter: ErrorAdapter] ++ opts)

  defp site_list(org),
    do: Mail.list_site_suppressed_recipients!(tenant: org, authorize?: false)

  describe "whose word, which list" do
    test "a site relay's recipient reject goes on that site's list, not the instance's",
         %{site_a: a, site_b: b} do
      relay!(a)

      assert {:cancel, _reason} = deliver(org_id: a.id, error: @recipient_reject)

      assert [entry] = site_list(a)
      assert to_string(entry.email) == @dead
      # The stored reason is redacted like every other bounce reason.
      refute entry.reason =~ @dead
      assert entry.last_failure_at

      refute Mail.suppressed?(@dead)
      assert site_list(b) == []
    end

    test "a repeat reject refreshes the one entry", %{site_a: a} do
      relay!(a)

      deliver(org_id: a.id, error: @recipient_reject)

      deliver(
        org_id: a.id,
        error: {:send, {:permanent_failure, ~c"smtp.example.com", "550 5.2.1 disabled"}}
      )

      assert [entry] = site_list(a)
      assert entry.reason =~ "5.2.1"
    end

    test "the operator's relay still writes the instance-wide list, never a site's",
         %{site_a: a} do
      # Site A has no relay of its own: its mail goes through the operator's,
      # and the operator's word is the instance-wide list's.
      assert {:cancel, _reason} = deliver(org_id: a.id, error: @recipient_reject)

      assert Mail.suppressed?(@dead)
      assert site_list(a) == []
    end

    test "a site relay refusing us suppresses nobody", %{site_a: a} do
      relay!(a)

      for reason <- [
            {:no_more_hosts, {:permanent_failure, ~c"smtp.example.com", :auth_failed}},
            {:no_more_hosts,
             {:permanent_failure, ~c"smtp.example.com", "554 5.7.1 go away <dead@example.com>"}},
            {:send, {:permanent_failure, ~c"smtp.example.com", "535 5.7.8 bad credentials"}}
          ] do
        assert_raise Mail.TransientDeliveryError, fn ->
          deliver(org_id: a.id, error: reason)
        end
      end

      assert site_list(a) == []
      refute Mail.suppressed?(@dead)
    end

    test "a reject that doesn't name the recipient cancels without suppressing", %{site_a: a} do
      relay!(a)

      for reply <- ["550 Message rejected as spam", "552 5.3.4 Message too big"] do
        assert {:cancel, _reason} =
                 deliver(org_id: a.id, error: {:send, {:permanent_failure, ~c"h", reply}})
      end

      assert site_list(a) == []
    end
  end

  describe "isolation" do
    setup %{site_a: a} do
      relay!(a)
      {:cancel, _reason} = deliver(org_id: a.id, error: @recipient_reject)
      :ok
    end

    test "site A's entry stops site A's mail only", %{site_a: a, site_b: b} do
      assert Mail.suppressed?(@dead, org_id: a.id)
      assert Mail.suppressed?("DEAD@Example.com", org_id: a.id)

      refute Mail.suppressed?(@dead, org_id: b.id)
      # No site — account mail: sign-in links, password resets.
      refute Mail.suppressed?(@dead)
      refute Mail.suppressed?(@dead, org_id: nil)
    end

    test "enqueue! skips it for site A and queues it for site B and for account mail",
         %{site_a: a, site_b: b} do
      :ok = Mail.enqueue!(email(), org_id: a.id)
      refute_enqueued(worker: DeliveryWorker, args: %{"org_id" => a.id})

      :ok = Mail.enqueue!(email(), org_id: b.id)
      assert_enqueued(worker: DeliveryWorker, args: %{"org_id" => b.id})

      :ok = Mail.enqueue!(put_to(email(), [{"", @dead}]))

      assert Enum.any?(
               all_enqueued(worker: DeliveryWorker),
               &(&1.args["to"] == ["", @dead] and not Map.has_key?(&1.args, "org_id"))
             )
    end

    test "the newsletter worker skips it for site A's campaign, not site B's",
         %{site_a: a, site_b: b} do
      assert {:cancel, "recipient suppressed (bounced)"} = perform_newsletter(a)

      # Site B's campaign gets past the suppression check to the delivery step
      # (where this bare seeded send has no fired artifact to mail).
      assert {:cancel, "no fired :web artifact" <> _rest} = perform_newsletter(b)
    end

    test "the operator's list still stops a site's mail", %{site_b: b} do
      {:ok, _} = Mail.suppress_recipient(%{email: "gone@example.com"}, authorize?: false)
      assert Mail.suppressed?("gone@example.com", org_id: b.id)
    end
  end

  describe "authorization" do
    test "a site's admins read and clear its list; its editors see nothing",
         %{site_a: a} do
      relay!(a)
      deliver(org_id: a.id, error: @recipient_reject)

      admin = member(a, :admin)
      editor = member(a, :editor)

      assert {:ok, []} = Mail.list_site_suppressed_recipients(actor: editor, tenant: a)
      assert [entry] = Mail.list_site_suppressed_recipients!(actor: admin, tenant: a)

      refute Mail.can_unsuppress_site_recipient?(editor, entry, tenant: a)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.unsuppress_site_recipient(entry, actor: editor, tenant: a)

      assert :ok = Mail.unsuppress_site_recipient(entry, actor: admin, tenant: a)
      refute Mail.suppressed?(@dead, org_id: a.id)
    end

    test "one site's admin can't read or clear another site's list", %{site_a: a, site_b: b} do
      relay!(b)
      deliver(org_id: b.id, error: @recipient_reject)
      [entry] = site_list(b)

      admin_a = member(a, :admin)

      assert {:ok, []} = Mail.list_site_suppressed_recipients(actor: admin_a, tenant: b)
      refute Mail.can_unsuppress_site_recipient?(admin_a, entry, tenant: b)
      # Read under their own site, site B's row simply isn't there.
      assert {:ok, []} = Mail.list_site_suppressed_recipients(actor: admin_a, tenant: a)
    end

    test "nobody but the pipeline writes it — not even the site's admin", %{site_a: a} do
      admin = member(a, :admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.suppress_site_recipient(%{email: "anyone@example.com"},
                 actor: admin,
                 tenant: a
               )
    end
  end

  describe "recent_site_delivery_failures/1" do
    test "lists this site's bounces by domain, and nothing else", %{site_a: a, site_b: b} do
      domain = "boom-#{System.unique_integer([:positive])}.test"

      subscriber =
        Ash.Seed.seed!(KilnCMS.Newsletter.Subscriber, %{
          org_id: a.id,
          email: "reader@news-#{domain}",
          status: :confirmed
        })

      bounce = "{:cancel, \"permanent delivery failure: 550 [address redacted]\"}"

      job!(a, "mail", "cancelled", %{"to" => ["", "dead@#{domain}"]}, bounce)
      job!(a, "newsletter", "cancelled", %{"subscriber_id" => subscriber.id}, bounce)
      job!(a, "mail", "discarded", %{"to" => ["", "slow@gaveup-#{domain}"]}, "timeout")
      # Cancelled for a reason that isn't delivery: not a failure.
      job!(a, "newsletter", "cancelled", %{"subscriber_id" => subscriber.id}, "not confirmed")
      # Another site's bounce.
      job!(b, "mail", "cancelled", %{"to" => ["", "x@other-#{domain}"]}, bounce)

      domains = a.id |> Mail.recent_site_delivery_failures() |> Enum.map(& &1.domain)

      assert Enum.sort(domains) ==
               Enum.sort([domain, "news-#{domain}", "gaveup-#{domain}"])

      refute Enum.any?(Mail.recent_site_delivery_failures(b.id), &(&1.domain =~ "news-"))
    end
  end

  defp perform_newsletter(org) do
    send =
      Ash.Seed.seed!(KilnCMS.Newsletter.NewsletterSend, %{
        org_id: org.id,
        content_type: "post",
        content_id: Ecto.UUID.generate(),
        subject: "Issue 1",
        status: :sending
      })

    subscriber =
      Ash.Seed.seed!(KilnCMS.Newsletter.Subscriber, %{
        org_id: org.id,
        email: @dead,
        status: :confirmed
      })

    perform_job(KilnCMS.Newsletter.MailWorker, %{
      "newsletter_send_id" => send.id,
      "subscriber_id" => subscriber.id,
      "org_id" => org.id
    })
  end

  defp job!(org, queue, state, args, error) do
    KilnCMS.Repo.insert!(%Oban.Job{
      worker: "KilnCMS.Mail.DeliveryWorker",
      queue: queue,
      state: state,
      args: Map.put(args, "org_id", org.id),
      errors: [%{"error" => error}],
      attempted_at: DateTime.utc_now()
    })
  end

  defp member(org, tier) do
    user =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "supp-#{tier}-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })

    user
  end
end
