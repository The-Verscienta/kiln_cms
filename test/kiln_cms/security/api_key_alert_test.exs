defmodule KilnCMS.Security.ApiKeyAlertTest do
  @moduledoc """
  API keys and the platform's alerts (#2245): a minted key is `new_api_key`
  and a rotation is not; a reused key is `api_key_abuse`, recorded in the key
  owner's own site when it has exactly one, else the default org — never the
  site a request names.

  `async: false`: alerts are turned on (`KilnCMS.Test.SecurityAlerts.enable/0`,
  an `Application.put_env`).
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKeyReuse
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.AuthEvents
  alias KilnCMS.Security.Recorder
  alias KilnCMS.Test.SecurityAlerts

  @moduletag :capture_log

  setup do
    SecurityAlerts.enable()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "keys-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp ctx(org_id), do: AuthEvents.context(Plug.Test.conn(:get, "/"), org_id)
  defp days(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  defp mint(owner, minter, org_id) do
    {:ok, key} =
      Accounts.mint_api_key(
        owner.id,
        "svc",
        days(7),
        %{access: :draft_write, rotatable_until: days(90)},
        actor: minter,
        context: ctx(org_id)
      )

    {key, Ash.Resource.get_metadata(key, :plaintext_api_key)}
  end

  defp kinds, do: Enum.map(SecurityAlerts.dispatches(), &{&1["scope"], &1["kind"]})

  # A rotated-away key, its successor aged past the reuse grace.
  defp rotated(owner, org_id) do
    {key, secret} = mint(owner, user(:admin), org_id)
    {:ok, actor} = Accounts.actor_from_api_key(secret)
    {:ok, successor} = Accounts.rotate_api_key(actor: actor, context: ctx(org_id))

    Repo.query!(
      "UPDATE api_keys SET created_at = created_at - interval '1 hour' WHERE id = $1",
      [Ecto.UUID.dump!(successor.id)]
    )

    Repo.query!("DELETE FROM security_alert_dispatches")
    {key, secret}
  end

  defp reuse_events(org_id) do
    # authorize?: false — reading the log back in a test.
    Security.list_events!(tenant: org_id, authorize?: false)
    |> Enum.filter(&(&1.type == :api_key_reuse_detected))
  end

  test "minting a key alerts every platform admin, muted or not; rotating does not" do
    muted = user(:admin, %{notify_on_security_alert: false})
    {_key, secret} = mint(user(:viewer), user(:admin), Accounts.default_org_id())

    assert kinds() == [{"platform", "new_api_key"}]

    SecurityAlerts.deliver()
    assert muted.id in (Notification |> Repo.all() |> Enum.map(& &1.user_id))

    Repo.query!("DELETE FROM security_alert_dispatches")
    {:ok, actor} = Accounts.actor_from_api_key(secret)
    {:ok, _} = Accounts.rotate_api_key(actor: actor, context: ctx(Accounts.default_org_id()))
    assert kinds() == []
  end

  test "a reused key of an owner with one site is recorded in that site" do
    org = org("keys-owner")
    owner = user(:viewer)

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: owner.id,
      role: :viewer
    })

    {key, secret} = rotated(owner, org.id)

    # The request names another site; it does not choose where this goes.
    other = org("keys-spoofed")
    assert :reuse_detected = ApiKeyReuse.check(secret, ctx(other.id))

    assert [event] = reuse_events(org.id)
    assert event.target_id == key.id
    assert reuse_events(other.id) == []
    assert kinds() == [{"platform", "api_key_abuse"}]

    SecurityAlerts.deliver()
    bells = Repo.all(Notification)
    assert bells != []
    assert Enum.all?(bells, &(&1.org_id == Accounts.default_org_id()))
  end

  test "a reused key of an owner with no site, or several, is recorded in the default org" do
    owner = user(:viewer)

    for org <- [org("keys-a"), org("keys-b")] do
      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: org.id,
        user_id: owner.id,
        role: :viewer
      })
    end

    {_key, secret} = rotated(owner, Accounts.default_org_id())
    assert :reuse_detected = ApiKeyReuse.check(secret, ctx(Accounts.default_org_id()))
    assert [_event] = reuse_events(Accounts.default_org_id())
  end

  # B1 (#2245): a window is claimed per kind, so a key over a rate limit has a
  # kind of its own. Were it `api_key_abuse`, its claim would take the window
  # and a stolen key's reuse in that window would wait for the summary.
  test "a key over a rate limit does not use up the reuse alert's window" do
    platform = user(:admin)
    org_id = Accounts.default_org_id()
    key_id = Ecto.UUID.generate()

    trip = fn ->
      {:ok, _} =
        Recorder.record(:api_key_rate_limited,
          tenant: org_id,
          target_type: "api_key",
          target_id: key_id,
          metadata: %{"name" => "svc", "bucket" => "api"}
        )
    end

    trip.()
    assert kinds() == [{"platform", "api_key_rate_limited"}]

    {:ok, _} =
      Recorder.record(:api_key_reuse_detected,
        tenant: org_id,
        target_type: "api_key",
        target_id: key_id,
        metadata: %{"name" => "svc", "revoked" => 2}
      )

    trip.()

    assert Enum.sort(kinds()) == [
             {"platform", "api_key_abuse"},
             {"platform", "api_key_rate_limited"}
           ]

    SecurityAlerts.deliver()

    excerpts =
      Notification
      |> Repo.all()
      |> Enum.filter(&(&1.user_id == platform.id))
      |> Enum.map(& &1.excerpt)
      |> Enum.sort()

    assert excerpts == ["A rotated API key was used again", "An API key hit a rate limit"]
  end

  test "an unknown, forged or junk key records nothing" do
    for junk <- ["", "kiln_", "kiln_a_b", String.duplicate("x", 500)],
        do: assert(:ok = ApiKeyReuse.check(junk, %{}))

    assert reuse_events(Accounts.default_org_id()) == []
    assert kinds() == []
  end
end
