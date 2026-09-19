defmodule KilnCMS.Billing.MembershipWebhooksTest do
  @moduledoc """
  `membership.activated` / `membership.canceled` outbound webhooks.

  What these pin, in order of what would hurt most if it broke:

    * **the events follow access** — every status pair is checked against
      `Membership.entitling?/1`, so a renewal or a dunning retry never tells a
      provisioner to provision (or tear down) twice;
    * **a transition that rolls back leaves no job** — the event cannot
      announce access the member was never given;
    * **the email is not stored in the job**, only read when it runs.

  `async: false`: webhook endpoints and Oban jobs are drained globally.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query

  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Membership
  alias KilnCMS.Billing.MembershipWebhooks
  alias KilnCMS.Billing.MembershipWebhookWorker
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Webhooks

  doctest KilnCMS.Billing.MembershipWebhooks

  @gated hd(Audiences.gated())
  @statuses [nil, :incomplete, :active, :past_due, :canceled, :comped]

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user(role \\ :viewer) do
    Ash.Seed.seed!(User, %{
      email: "member-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp tier do
    Billing.create_tier!(
      %{
        name: "Hosted Starter",
        slug: "hosted-#{System.unique_integer([:positive])}",
        audience: @gated,
        provider_price_id: "price_#{System.unique_integer([:positive])}"
      },
      authorize?: false,
      tenant: org_id()
    )
  end

  defp membership(user, tier, status) do
    Ash.Seed.seed!(Membership, %{
      org_id: org_id(),
      user_id: user.id,
      tier_id: tier.id,
      status: status
    })
  end

  defp apply_state(membership, status) do
    Billing.apply_provider_state!(membership, %{status: status},
      authorize?: false,
      tenant: org_id()
    )
  end

  defp endpoint(admin, events \\ MembershipWebhooks.events()) do
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook", events: events},
      actor: admin
    )
  end

  defp stub_capture do
    test_pid = self()

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:delivered, Map.new(conn.req_headers), body})
      send(test_pid, {:raw, Map.new(conn.req_headers), body})
      Req.Test.json(conn, %{ok: true})
    end)
  end

  defp delivered do
    KilnCMS.DataCase.drain_oban()

    Stream.repeatedly(fn ->
      receive do
        {:delivered, headers, body} -> {headers["x-kilncms-event"], Jason.decode!(body)}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  describe "event_for/2 — every status pair" do
    test "fires exactly on the edges of access" do
      for from <- @statuses, to <- @statuses -- [nil] do
        expected =
          case {Membership.entitling?(from), Membership.entitling?(to)} do
            {false, true} -> "membership.activated"
            {true, false} -> "membership.canceled"
            _ -> nil
          end

        assert MembershipWebhooks.event_for(from, to) == expected,
               "#{inspect(from)} -> #{inspect(to)}"
      end
    end

    test "the cases a provisioner cares about, by name" do
      # Spelled out as well as derived: the table above would stay green if
      # `entitling?/1` itself drifted, and these are the promises the docs make.
      assert MembershipWebhooks.event_for(:incomplete, :active) == "membership.activated"
      assert MembershipWebhooks.event_for(nil, :comped) == "membership.activated"
      assert MembershipWebhooks.event_for(:canceled, :active) == "membership.activated"
      assert MembershipWebhooks.event_for(:past_due, :canceled) == "membership.canceled"
      assert MembershipWebhooks.event_for(:comped, :canceled) == "membership.canceled"
      # Renewal, dunning, recovery from dunning, abandoned checkout: silent.
      assert MembershipWebhooks.event_for(:active, :active) == nil
      assert MembershipWebhooks.event_for(:active, :past_due) == nil
      assert MembershipWebhooks.event_for(:past_due, :active) == nil
      assert MembershipWebhooks.event_for(:incomplete, :canceled) == nil
    end
  end

  describe "delivery" do
    setup do
      stub_capture()
      %{admin: user(:admin), member: user(), tier: tier()}
    end

    test "activation delivers a signed membership.activated with the member and tier", ctx do
      hook = endpoint(ctx.admin)
      m = membership(ctx.member, ctx.tier, :incomplete)

      apply_state(m, :active)

      assert [{"membership.activated", %{"event" => "membership.activated", "data" => data}}] =
               delivered()

      assert data["membership_id"] == m.id
      assert data["user_id"] == ctx.member.id
      assert data["email"] == to_string(ctx.member.email)
      assert data["status"] == "active"
      assert data["previous_status"] == "incomplete"
      assert data["org_id"] == org_id()
      assert data["activated_at"]

      assert data["tier"] == %{
               "id" => ctx.tier.id,
               "slug" => ctx.tier.slug,
               "name" => "Hosted Starter",
               "audience" => to_string(@gated)
             }

      # `event_id` is the audit row for the same transition, so a receiver can
      # dedupe a redelivery and an operator can trace one to the other.
      [event] = Billing.membership_events!(m.id, authorize?: false, tenant: org_id())
      assert data["event_id"] == event.id

      delivery =
        KilnCMS.Repo.one!(
          from d in "webhook_deliveries",
            where: d.endpoint_id == type(^hook.id, :binary_id),
            select: d.payload
        )

      assert delivery["email"] == to_string(ctx.member.email)

      assert_received {:raw, headers, raw}
      assert headers["x-kilncms-signature"] == Webhooks.signature(hook.secret, raw)
    end

    test "renewal and dunning are silent; the provider giving up is membership.canceled",
         ctx do
      endpoint(ctx.admin)
      m = membership(ctx.member, ctx.tier, :active)

      m = apply_state(m, :active)
      m = apply_state(m, :past_due)
      assert delivered() == []

      apply_state(m, :canceled)

      assert [
               {"membership.canceled",
                %{"data" => %{"status" => "canceled", "previous_status" => "past_due"}}}
             ] =
               delivered()
    end

    test "an abandoned checkout never granted anything, so says nothing", ctx do
      endpoint(ctx.admin)
      m = membership(ctx.member, ctx.tier, :incomplete)

      apply_state(m, :canceled)

      assert delivered() == []
    end

    test "comping activates and uncomping cancels", ctx do
      endpoint(ctx.admin)

      comped =
        Billing.comp_membership!(%{user_id: ctx.member.id, tier_id: ctx.tier.id},
          actor: ctx.admin,
          tenant: org_id()
        )

      assert [{"membership.activated", %{"data" => %{"status" => "comped"}}}] = delivered()

      Billing.uncomp_membership!(comped, actor: ctx.admin, tenant: org_id())

      assert [{"membership.canceled", %{"data" => %{"previous_status" => "comped"}}}] =
               delivered()
    end

    test "only endpoints subscribed to the event receive it", ctx do
      endpoint(ctx.admin, ["membership.canceled"])
      m = membership(ctx.member, ctx.tier, :incomplete)

      apply_state(m, :active)

      assert delivered() == []
    end

    test "another site's endpoint never hears this site's members", ctx do
      other = KilnCMS.OrgFixtures.org("other")

      CMS.create_webhook_endpoint!(
        %{url: "https://example.test/other", events: MembershipWebhooks.events()},
        actor: ctx.admin,
        tenant: other.id
      )

      m = membership(ctx.member, ctx.tier, :incomplete)
      apply_state(m, :active)

      assert delivered() == []
    end
  end

  describe "the outbox" do
    test "a transition that rolls back leaves no job; one that commits leaves one" do
      # Run inside an outer transaction so the rollback is ours to trigger. That
      # nesting means this cannot tell an in-transaction enqueue from an
      # after-commit one — both roll back here. What it pins is the promise
      # receivers rely on: no event for access that was never granted.
      m = membership(user(), tier(), :incomplete)

      {:error, :rolled_back} =
        KilnCMS.Repo.transaction(fn ->
          apply_state(m, :active)
          assert_enqueued(worker: MembershipWebhookWorker)
          KilnCMS.Repo.rollback(:rolled_back)
        end)

      refute_enqueued(worker: MembershipWebhookWorker)

      apply_state(m, :active)
      assert_enqueued(worker: MembershipWebhookWorker)
    end

    test "the job stores ids and statuses, never the email" do
      member = user()
      m = membership(member, tier(), :incomplete)

      apply_state(m, :active)

      [job] = all_enqueued(worker: MembershipWebhookWorker)
      refute inspect(job.args) =~ to_string(member.email)

      assert %{
               "event" => "membership.activated",
               "membership_id" => id,
               "from_status" => "incomplete",
               "to_status" => "active"
             } = job.args

      assert id == m.id
    end
  end

  test "both events are selectable on an endpoint" do
    assert "membership.activated" in CMS.WebhookEndpoint.events(org_id())
    assert "membership.canceled" in CMS.WebhookEndpoint.events(org_id())
  end
end
