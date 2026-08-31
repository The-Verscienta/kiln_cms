defmodule KilnCMS.Billing.WebhooksTest do
  @moduledoc """
  The resolution ladder that turns a verified provider event into the membership
  it concerns (`KilnCMS.Billing.Webhooks`).

  `KilnCMSWeb.BillingWebhookControllerTest` drives the receiver end to end and,
  in doing so, exercises rung 1 — self-describing metadata — thoroughly. That
  leaves the rungs below it, which exist precisely because **Stripe sends the
  same identifier in several different shapes** depending on the event: a
  subscription id is the object's own `id` on `customer.subscription.*`, a
  nested object on a checkout session, and a bare string on an invoice. A
  fallback clause that never runs in a test is the failure mode itself, and the
  blast radius is somebody's paid access silently not being granted.

  Two properties are worth stating before the tests, because they shape what can
  be asserted:

    * **The ladder is ordered, and the order is the point.** Metadata is checked
      first because it is the only rung verified against our own row; the two
      below it trust an identifier alone. A regression that reordered them would
      still resolve most events correctly, so the tests below pin the order
      directly rather than inferring it.
    * **`resolve/1` flattens every failure to `:unresolvable`.** Its `with` only
      matches `{:ignored, _}`, so `:ambiguous_customer` — the deliberate refusal
      to guess between two tiers — is indistinguishable from "nothing matched"
      at the call site. The log line is the only place that distinction survives,
      so the ambiguity tests assert on it there.

  One branch is deliberately left uncovered: `verify/3`'s **org** mismatch. The
  read above it is tenant-filtered by the very `org_id` being compared, so a row
  found under org A can never carry org B and the comparison cannot be reached
  through `resolve/1`. It is not dead code to delete — the two rungs below it
  are `multitenancy :bypass`, and this one would become live the moment that
  read followed — but no honest test reaches it, and the test below pins what an
  event claiming the wrong org actually does (it is refused one step earlier, as
  not-found).
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Webhooks
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp member do
    Ash.Seed.seed!(User, %{
      email: "hook-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp tier(price_id \\ nil) do
    Billing.create_tier!(
      %{
        name: "Supporter",
        slug: "supporter-#{uniq()}",
        audience: @gated,
        provider_price_id: price_id || "price_#{uniq()}"
      },
      authorize?: false,
      tenant: org_id()
    )
  end

  defp membership(attrs \\ %{}) do
    Ash.Seed.seed!(
      Billing.Membership,
      Map.merge(
        %{
          org_id: org_id(),
          user_id: member().id,
          tier_id: tier().id,
          status: :active
        },
        attrs
      )
    )
  end

  # An event carrying `object` as its data object — the only shape `resolve/1`
  # reads, and the shape every Stripe event has.
  defp event(object), do: %{"data" => %{"object" => object}}

  describe "rung 1: metadata" do
    test "resolves the membership the metadata names" do
      m = membership()

      assert {:ok, resolved} =
               Webhooks.resolve(
                 event(%{"metadata" => %{"membership_id" => m.id, "org_id" => m.org_id}})
               )

      assert resolved.id == m.id
    end

    test "wins over the subscription and customer ids in the same event" do
      named = membership()

      # The same event also carries identifiers pointing at a *different*
      # membership. Metadata is the only rung verified against our own row, so
      # it has to be the one that answers — a reordering would still resolve
      # most real events and would be invisible without this.
      other =
        membership(%{
          provider_subscription_id: "sub_#{uniq()}",
          provider_customer_id: "cus_#{uniq()}"
        })

      assert {:ok, resolved} =
               Webhooks.resolve(
                 event(%{
                   "metadata" => %{"membership_id" => named.id, "org_id" => named.org_id},
                   "subscription" => other.provider_subscription_id,
                   "customer" => other.provider_customer_id
                 })
               )

      assert resolved.id == named.id
      refute resolved.id == other.id
    end

    test "metadata claiming a different org than the row's is refused" do
      m = membership()

      other_org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Other",
          slug: "other-#{uniq()}",
          status: :active
        })

      assert {:ignored, :unresolvable} =
               Webhooks.resolve(
                 event(%{"metadata" => %{"membership_id" => m.id, "org_id" => other_org.id}})
               )
    end

    test "a membership_id naming nothing falls through to the rungs below it" do
      m = membership(%{provider_subscription_id: "sub_#{uniq()}"})

      assert {:ok, resolved} =
               Webhooks.resolve(
                 event(%{
                   "metadata" => %{"membership_id" => Ecto.UUID.generate()},
                   "subscription" => m.provider_subscription_id
                 })
               )

      assert resolved.id == m.id
    end
  end

  describe "rung 2: subscription id, in each shape Stripe sends it" do
    setup do
      sub = "sub_#{uniq()}"
      %{sub: sub, membership: membership(%{provider_subscription_id: sub})}
    end

    test "the subscription object's own id (customer.subscription.*)", ctx do
      assert {:ok, resolved} =
               Webhooks.resolve(event(%{"object" => "subscription", "id" => ctx.sub}))

      assert resolved.id == ctx.membership.id
    end

    test "a nested subscription object (expanded checkout session)", ctx do
      assert {:ok, resolved} = Webhooks.resolve(event(%{"subscription" => %{"id" => ctx.sub}}))
      assert resolved.id == ctx.membership.id
    end

    test "a bare subscription string (invoice)", ctx do
      assert {:ok, resolved} = Webhooks.resolve(event(%{"subscription" => ctx.sub}))
      assert resolved.id == ctx.membership.id
    end

    test "an id belonging to no membership falls through rather than erroring" do
      assert {:ignored, :unresolvable} =
               Webhooks.resolve(event(%{"subscription" => "sub_#{uniq()}"}))
    end

    test "an object whose `id` is not a subscription is not read as one" do
      # `%{"object" => "invoice", "id" => "in_…"}` must not be mistaken for a
      # subscription id — only `"object" => "subscription"` licenses that read.
      m = membership(%{provider_subscription_id: "in_#{uniq()}"})

      assert {:ignored, :unresolvable} =
               Webhooks.resolve(
                 event(%{"object" => "invoice", "id" => m.provider_subscription_id})
               )
    end
  end

  describe "rung 3: customer id" do
    test "a bare customer string resolves a sole membership" do
      cus = "cus_#{uniq()}"
      m = membership(%{provider_customer_id: cus})

      assert {:ok, resolved} = Webhooks.resolve(event(%{"customer" => cus}))
      assert resolved.id == m.id
    end

    test "a nested customer object resolves the same way" do
      cus = "cus_#{uniq()}"
      m = membership(%{provider_customer_id: cus})

      assert {:ok, resolved} = Webhooks.resolve(event(%{"customer" => %{"id" => cus}}))
      assert resolved.id == m.id
    end

    test "a customer with no membership is ignored, not an error" do
      assert {:ignored, :unresolvable} = Webhooks.resolve(event(%{"customer" => "cus_#{uniq()}"}))
    end
  end

  describe "two tiers for one customer" do
    setup do
      cus = "cus_#{uniq()}"
      user = member()
      wanted_price = "price_#{uniq()}"
      wanted_tier = tier(wanted_price)

      wanted =
        membership(%{
          user_id: user.id,
          tier_id: wanted_tier.id,
          provider_customer_id: cus
        })

      _other = membership(%{user_id: user.id, provider_customer_id: cus})

      %{cus: cus, price: wanted_price, wanted: wanted}
    end

    test "the event's price id picks the tier — subscription shape", ctx do
      assert {:ok, resolved} =
               Webhooks.resolve(
                 event(%{
                   "customer" => ctx.cus,
                   "items" => %{"data" => [%{"price" => %{"id" => ctx.price}}]}
                 })
               )

      assert resolved.id == ctx.wanted.id
    end

    test "the event's price id picks the tier — invoice line shape", ctx do
      assert {:ok, resolved} =
               Webhooks.resolve(
                 event(%{
                   "customer" => ctx.cus,
                   "lines" => %{"data" => [%{"price" => %{"id" => ctx.price}}]}
                 })
               )

      assert resolved.id == ctx.wanted.id
    end

    test "the event's price id picks the tier — legacy plan shape", ctx do
      assert {:ok, resolved} =
               Webhooks.resolve(event(%{"customer" => ctx.cus, "plan" => %{"id" => ctx.price}}))

      assert resolved.id == ctx.wanted.id
    end

    test "no price id refuses to guess between them", ctx do
      log =
        capture_log(fn ->
          assert {:ignored, :unresolvable} = Webhooks.resolve(event(%{"customer" => ctx.cus}))
        end)

      # `resolve/1` flattens the reason, so the refusal is only legible here —
      # and "2 memberships, none singled out" is what an operator needs to see
      # to know this was a deliberate refusal rather than an unknown customer.
      assert log =~ "2 memberships match this customer"
    end

    test "a price id for a tier neither of them holds refuses too", ctx do
      unheld = tier().provider_price_id

      log =
        capture_log(fn ->
          assert {:ignored, :unresolvable} =
                   Webhooks.resolve(event(%{"customer" => ctx.cus, "plan" => %{"id" => unheld}}))
        end)

      assert log =~ "does not single one out"
    end

    test "a price id matching no tier at all refuses too", ctx do
      log =
        capture_log(fn ->
          assert {:ignored, :unresolvable} =
                   Webhooks.resolve(
                     event(%{"customer" => ctx.cus, "plan" => %{"id" => "price_#{uniq()}"}})
                   )
        end)

      assert log =~ "does not single one out"
    end
  end

  describe "org_id/1" do
    test "is the resolved membership's own org, not the event's claim" do
      m = membership(%{provider_subscription_id: "sub_#{uniq()}"})

      # The row wins: every write downstream is scoped to what this returns, so
      # a hostile or stale `org_id` in the payload must not steer it.
      assert Webhooks.org_id(
               event(%{
                 "subscription" => m.provider_subscription_id,
                 "metadata" => %{"org_id" => Ecto.UUID.generate()}
               })
             ) == m.org_id
    end

    test "falls back to the metadata org when nothing resolves" do
      claimed = Ecto.UUID.generate()

      assert Webhooks.org_id(
               event(%{"customer" => "cus_#{uniq()}", "metadata" => %{"org_id" => claimed}})
             ) == claimed
    end

    test "is nil when the event says nothing either way" do
      assert Webhooks.org_id(event(%{"customer" => "cus_#{uniq()}"})) == nil
    end
  end

  describe "malformed events" do
    test "an event with no data object is ignored rather than raising" do
      assert {:ignored, :unresolvable} = Webhooks.resolve(%{"type" => "ping"})
      assert {:ignored, :unresolvable} = Webhooks.resolve(%{"data" => %{}})
      assert {:ignored, :unresolvable} = Webhooks.resolve(%{"data" => %{"object" => "nope"}})
      assert Webhooks.org_id(%{"type" => "ping"}) == nil
    end

    test "a non-string subscription id is ignored rather than raising" do
      # `subscription_id/1`'s nested-object clause has no `is_binary` guard, so
      # a payload carrying `{"subscription": {"id": 123}}` reaches the read with
      # an integer and Ash answers `{:error, _}`. Same reasoning as the
      # malformed metadata below: it has to become an ignore, not a 500.
      assert {:ignored, :unresolvable} =
               Webhooks.resolve(event(%{"subscription" => %{"id" => 123}}))
    end

    test "metadata that is not a map is ignored rather than raising" do
      assert {:ignored, :unresolvable} = Webhooks.resolve(event(%{"metadata" => "nope"}))
    end

    test "metadata ids that are not UUIDs are ignored rather than raising" do
      # Both of these make Ash return `{:error, _}` rather than an empty read —
      # a malformed id is an invalid argument, and a malformed org is an invalid
      # tenant. Neither may escape as an exception: the receiver answers 500,
      # and a 500 makes the provider retry for days and then disable the
      # endpoint (see the moduledoc). Ignoring is the whole point.
      assert {:ignored, :unresolvable} =
               Webhooks.resolve(event(%{"metadata" => %{"membership_id" => "not-a-uuid"}}))

      m = membership()

      assert {:ignored, :unresolvable} =
               Webhooks.resolve(
                 event(%{"metadata" => %{"membership_id" => m.id, "org_id" => "not-a-uuid"}})
               )
    end

    test "a malformed membership_id still lets the rungs below it answer" do
      m = membership(%{provider_subscription_id: "sub_#{uniq()}"})

      assert {:ok, resolved} =
               Webhooks.resolve(
                 event(%{
                   "metadata" => %{"membership_id" => "not-a-uuid"},
                   "subscription" => m.provider_subscription_id
                 })
               )

      assert resolved.id == m.id
    end
  end
end
