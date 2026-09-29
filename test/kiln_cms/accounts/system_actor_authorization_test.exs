defmodule KilnCMS.Accounts.SystemActorAuthorizationTest do
  @moduledoc """
  What the accounts domain's own system reads are *authorized* to do, now that
  the tenant list, the default-org fallback and the membership half of a
  data-subject export run as `KilnCMS.Accounts.system/0` instead of
  `authorize?: false` (#1659).

  Every grant has a refusal next to it: the system actor may use
  `Organization`'s plain `read`, and not the request path's tenant resolution
  (`by_slug`, `by_custom_domain`) or any write.

  The migrated reads must fail CLOSED. A refused read is filtered, so it
  answers `[]` or `nil`, and here both answers are dangerous: `[]` org ids
  turns every all-orgs sweep (erasure, audit verification, the scheduler's
  tenant scan) into a silent no-op that reports success, and `nil` reads as
  "the seed row is missing". Each missing-grant test takes the grant away with
  `Accounts.with_actor/2` and asserts an error, never an empty answer.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "asa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org! do
    Ash.Seed.seed!(Organization, %{name: "Other #{uniq()}", slug: "asa-#{uniq()}"})
  end

  defp membership!(user) do
    tier =
      Billing.create_tier!(
        %{
          name: "Supporter",
          slug: "supporter-#{uniq()}",
          audience: hd(Audiences.gated()),
          provider_price_id: "price_#{uniq()}"
        },
        authorize?: false,
        tenant: Accounts.default_org_id()
      )

    Ash.Seed.seed!(Billing.Membership, %{
      org_id: Accounts.default_org_id(),
      user_id: user.id,
      tier_id: tier.id,
      status: :active,
      provider_customer_id: "cus_#{uniq()}",
      provider_subscription_id: "sub_#{uniq()}"
    })
  end

  test "Accounts.system/0 is a system actor labelled :accounts" do
    assert %SystemActor{subsystem: :accounts} = Accounts.system()
  end

  describe "Organization — the tenant list" do
    test "list_org_ids/0 reads every org as the system actor" do
      other = org!()
      ids = Accounts.list_org_ids()

      assert Accounts.default_org_id() in ids
      assert other.id in ids
    end

    test "a refused list raises instead of answering []" do
      _other = org!()

      assert_raise Ash.Error.Forbidden, fn ->
        Accounts.with_actor(nil, fn -> Accounts.list_org_ids() end)
      end
    end

    test "a partial actor (sees some orgs, not all) raises instead of a short list" do
      # A viewer reads the orgs they are a member of; they are a member of none
      # here, so a filtered read would drop every org — including `other`.
      _other = org!()
      viewer = user(:viewer)

      assert_raise Ash.Error.Forbidden, fn ->
        Accounts.with_actor(viewer, fn -> Accounts.list_org_ids() end)
      end
    end
  end

  describe "Organization — the default-org fallback" do
    test "default_org/0 loads the seed org as the system actor" do
      default_id = Accounts.default_org_id()
      assert %Organization{id: ^default_id} = Accounts.default_org()
    end

    test "a refused read answers :error, never nil (\"seed row missing\")" do
      assert Accounts.with_actor(nil, fn -> Accounts.default_org() end) == :error
    end
  end

  describe "Organization — what the system actor may NOT do" do
    test "the request path's tenant resolution is not admitted" do
      other = org!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.get_organization_by_slug(other.slug,
                 actor: Accounts.system(),
                 authorize_with: :error
               )

      # Filtered, not merely erroring under `authorize_with: :error`.
      refute match?(
               {:ok, %Organization{}},
               Accounts.get_organization_by_slug(other.slug,
                 actor: Accounts.system(),
                 not_found_error?: false
               )
             )
    end

    test "creating or editing an org stays platform-admin" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.create_organization(%{name: "Nope", slug: "asa-nope-#{uniq()}"},
                 actor: Accounts.system()
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.update_organization(org!(), %{name: "Renamed"}, actor: Accounts.system())
    end
  end

  describe "data-subject export — the membership half" do
    test "includes the member's memberships, read as the system actor" do
      u = user(:viewer)
      m = membership!(u)

      assert [%{provider_subscription_id: sub}] = Accounts.export_user_data(u).memberships
      assert sub == m.provider_subscription_id
    end

    test "a refused read is logged as an error, not passed off as \"no memberships\"" do
      u = user(:viewer)
      membership!(u)

      {export, log} =
        with_log(fn ->
          Accounts.with_actor(nil, fn -> Accounts.export_user_data(u) end)
        end)

      assert export.memberships == []
      assert log =~ "data-subject export could not read memberships"
    end
  end
end
