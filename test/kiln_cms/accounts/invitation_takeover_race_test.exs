defmodule KilnCMS.Accounts.InvitationTakeoverRaceTest do
  @moduledoc """
  An invitation's takeover of an unconfirmed account (#2453) against a
  request the stranger's session had in flight, committed by another
  transaction at the same moment: the user-row lock
  (`KilnCMS.Accounts.Changes.GuardAccountTakeover`) makes the request wait
  for the takeover, and then refuses it.

  The sandbox runs every test on one connection inside one transaction, where
  a row lock never makes anything wait, so these run **outside** it
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on real connections whose
  writes commit, as `KilnCMS.Accounts.RegistrationErasureRaceTest` does. The
  takeover holds inside its transaction, after it has the row, on
  `KilnCMS.Test.Latch`; the request is shown to be waiting, then the takeover
  is released. Everything committed is deleted again on exit: the site (and
  every row scoped to it), the invitation, the accounts and what hangs off
  them. No platform admin is committed: the invitation is seeded, at the
  editor tier, which needs no standing inviter.

  The rules themselves are `KilnCMS.Accounts.InvitationTakeoverCredentialsTest`.
  """
  use ExUnit.Case, async: false

  import KilnCMS.PasskeyFixtures, only: [enroll: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AccountTakenOver
  alias KilnCMS.Accounts.Invitation
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo
  alias KilnCMS.Test.Latch

  @moduletag :capture_log

  @old_password "squatter-password-456"
  @password "invitee-password-123"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp uniq, do: System.unique_integer([:positive])

  setup do
    test_pid = self()
    start_supervised!({Latch, name: :takeover_race, listener: test_pid})

    {site, squatter, token} =
      unboxed(fn ->
        site =
          Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
            name: "takeover race",
            slug: "takeover-race-#{uniq()}",
            status: :active
          })

        email = "takeover-race-#{uniq()}@example.com"

        squatter =
          Ash.Seed.seed!(User, %{
            email: email,
            hashed_password: Bcrypt.hash_pwd_salt(@old_password),
            confirmed_at: nil,
            role: :viewer
          })

        token = Invitations.generate_token()

        Ash.Seed.seed!(Invitation, %{
          organization_id: site.id,
          email: email,
          role: :editor,
          token_hash: Invitations.hash(token),
          expires_at: Invitations.expiry(DateTime.utc_now()),
          last_sent_at: DateTime.utc_now(),
          sent_count: 1
        })

        {site, squatter, token}
      end)

    on_exit(fn -> unboxed(fn -> cleanup(site.id, squatter.id) end) end)

    %{squatter: squatter, token: token}
  end

  # The takeover, holding inside its transaction once it has the account's
  # row (its own lock and its UPDATE), before anything is forgotten, until
  # released.
  defp held_takeover(squatter, token) do
    held =
      squatter
      |> Ash.Changeset.new()
      |> Ash.Changeset.after_action(fn _changeset, user ->
        Latch.enter(:takeover_race)
        {:ok, user}
      end)

    Task.async(fn ->
      unboxed(fn ->
        Accounts.accept_invitation_with_password(
          held,
          %{token: token, password: @password, password_confirmation: @password},
          authorize?: false
        )
      end)
    end)
  end

  # Once the takeover is holding the row, start `request` and show it waits;
  # then let the takeover commit. Returns the request's task.
  defp race(request) do
    assert_receive {:latch_started, :takeover_race, 1}, 5_000
    task = Task.async(fn -> unboxed(request) end)
    refute Task.yield(task, 300), "the request did not wait for the takeover"
    assert [_] = Latch.release_all(:takeover_race)
    task
  end

  defp passkeys(user) do
    %{rows: [[count]]} =
      unboxed(fn ->
        Repo.query!("SELECT count(*) FROM passkeys WHERE user_id = $1", [
          Ecto.UUID.dump!(user.id)
        ])
      end)

    count
  end

  defp taken_over?({:error, %{errors: errors}}),
    do: Enum.any?(errors, &match?(%AccountTakenOver{}, &1))

  defp taken_over?(_result), do: false

  defp sign_in(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    unboxed(fn ->
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(email), "password" => password},
        []
      )
    end)
  end

  test "a passkey registration waits for the takeover, then is refused", ctx do
    takeover = held_takeover(ctx.squatter, ctx.token)
    register = race(fn -> enroll(ctx.squatter, "race-cred-#{uniq()}") end)

    assert {:ok, _} = Task.await(takeover)
    assert taken_over?(Task.await(register))
    refute_received {:latch_timeout, _, _}

    assert passkeys(ctx.squatter) == 0
  end

  test "a password change waits for the takeover, then is refused", ctx do
    takeover = held_takeover(ctx.squatter, ctx.token)

    change =
      race(fn ->
        Accounts.change_password(
          ctx.squatter,
          %{
            current_password: @old_password,
            password: "stranger-again-789",
            password_confirmation: "stranger-again-789"
          },
          actor: ctx.squatter
        )
      end)

    assert {:ok, _} = Task.await(takeover)
    assert taken_over?(Task.await(change))
    refute_received {:latch_timeout, _, _}

    assert {:ok, _} = sign_in(ctx.squatter.email, @password)
    assert {:error, _} = sign_in(ctx.squatter.email, "stranger-again-789")
  end

  # Everything the tests committed: rows scoped to the site (a foreign key
  # between two scoped tables can refuse a delete until the other is emptied,
  # so loop until a pass makes no progress), the site's invitation and
  # memberships, the site, then the account and what hangs off it.
  defp cleanup(org_id, user_id) do
    org = Ecto.UUID.dump!(org_id)
    user = Ecto.UUID.dump!(user_id)

    %{rows: tables} =
      Repo.query!("""
      SELECT table_name FROM information_schema.columns
      WHERE column_name = 'org_id' AND table_schema = 'public'
      """)

    sweep(Enum.map(tables, &hd/1), org, 10)
    Repo.query!("DELETE FROM invitations WHERE organization_id = $1", [org])
    Repo.query!("DELETE FROM org_memberships WHERE organization_id = $1", [org])
    Repo.query!("DELETE FROM organizations WHERE id = $1", [org])
    Repo.query!("DELETE FROM oban_jobs WHERE args::text ~ ANY($1)", [[org_id, user_id]])

    Repo.query!("DELETE FROM security_events WHERE actor_id = $1 OR target_id = $1", [user])

    for table <- ~w(passkeys push_subscriptions user_identities api_keys org_memberships) do
      Repo.query!(~s|DELETE FROM "#{table}" WHERE user_id = $1|, [user])
    end

    Repo.query!("DELETE FROM tokens WHERE subject ~ $1", [user_id])
    Repo.query!("DELETE FROM users WHERE id = $1", [user])
  end

  defp sweep([], _org, _passes), do: :ok
  defp sweep(_tables, _org, 0), do: :ok

  defp sweep(tables, org, passes) do
    left =
      Enum.reject(tables, fn table ->
        match?({:ok, _}, Repo.query(~s|DELETE FROM "#{table}" WHERE org_id = $1|, [org]))
      end)

    sweep(left, org, passes - 1)
  end
end
