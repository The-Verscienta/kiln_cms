defmodule KilnCMS.Accounts.SignOutEveryoneLockTest do
  @moduledoc """
  "Sign out everyone on every site" (#2491) against a session being used at
  the same moment.

  `Sessions.record_use/3` bumps a session and its remember-me row in one
  statement, which locks them in jti order. The sign-out takes every row it
  will revoke in one pass, in the same order, before it writes, so the two
  queue behind each other instead of each holding a row the other wants.
  Revoking the sessions first and the remember-me rows second would hold the
  session while waiting for its cookie: a deadlock, and Postgres would roll
  the whole sign-out back mid-incident.

  The other writer here holds the remember-me row (the lower jti) until the
  test releases it, then takes the session row, as a jti-ordered writer does.
  Held past `Sessions.revoke_timeout/0`, the sign-out gives up, undoes
  everything and says it timed out.

  Not `async` for a second reason: the timeout test shortens the timeout
  with `Application.put_env/3`, which every test running alongside would see.

  Run **outside** the sandbox (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on
  real connections whose writes commit, for the reason
  `KilnCMS.Accounts.ErasureRaceTest` gives: inside the sandbox a row lock
  never makes anything wait. What it commits is deleted again on exit. Not
  `async`, so no other test runs alongside: the sign-out reaches every live
  session in the database.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.SignOutEveryone
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Repo
  alias KilnCMS.Test.Latch

  @moduletag :capture_log

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp uniq, do: System.unique_integer([:positive])

  defp seed_user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "soe-lock-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("soe-lock-123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp seed_token(user, org, jti, purpose, attrs \\ %{}) do
    Ash.Seed.seed!(
      Token,
      Map.merge(
        %{
          jti: jti,
          subject: "user?id=#{user.id}",
          purpose: purpose,
          org_id: org.id,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        attrs
      )
    )
  end

  setup do
    start_supervised!({Latch, name: :soe_lock, listener: self()})
    n = uniq()

    ctx =
      unboxed(fn ->
        org =
          Ash.Seed.seed!(Accounts.Organization, %{
            name: "soe lock",
            slug: "soe-lock-#{n}",
            status: :active
          })

        platform = seed_user(:admin)
        victim = seed_user(:editor)

        # The cookie sorts before its session, so a jti-ordered writer takes
        # the cookie first.
        cookie = seed_token(victim, org, "soe-lock-a-#{n}", Token.remember_me_purpose())

        session =
          seed_token(victim, org, "soe-lock-b-#{n}", Token.user_purpose(), %{
            remember_me_jti: cookie.jti
          })

        %{org: org, platform: platform, victim: victim, session: session, cookie: cookie}
      end)

    on_exit(fn -> unboxed(fn -> cleanup(ctx) end) end)
    ctx
  end

  defp sign_out_everyone(actor) do
    Accounts.sign_out_everyone_on_every_site(
      %{confirmation: SignOutEveryone.phrase(), except_session_jti: nil},
      actor: actor
    )
  end

  defp purpose(jti),
    do:
      unboxed(fn ->
        Repo.one!(from(t in Token, where: t.jti == ^jti, select: t.purpose))
      end)

  test "a session used while it runs neither fails it nor is missed", ctx do
    use_opts = [org_id: ctx.org.id]

    # The other writer: the cookie's row taken (and held), then the session's.
    writer =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            :ok = Sessions.record_use(ctx.cookie.jti, %{}, use_opts)
            Latch.enter(:soe_lock)
            :ok = Sessions.record_use(ctx.session.jti, %{}, use_opts)
          end)
        end)
      end)

    assert_receive {:latch_started, :soe_lock, 1}, 5_000

    sign_out = Task.async(fn -> unboxed(fn -> sign_out_everyone(ctx.platform) end) end)
    refute Task.yield(sign_out, 300), "the sign-out did not wait for the held cookie"

    assert [_] = Latch.release_all(:soe_lock)
    assert {:ok, :ok} = Task.await(writer, 10_000)

    assert {:ok, count} = Task.await(sign_out, 10_000)
    assert count >= 1
    assert purpose(ctx.session.jti) == "revocation"
    assert purpose(ctx.cookie.jti) == "revocation"
    refute_received {:latch_timeout, _, _}
  end

  test "held past its timeout, it revokes nothing and says it timed out", ctx do
    Application.put_env(:kiln_cms, :sign_out_everyone_timeout, 300)
    on_exit(fn -> Application.delete_env(:kiln_cms, :sign_out_everyone_timeout) end)

    writer =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            :ok = Sessions.record_use(ctx.cookie.jti, %{}, org_id: ctx.org.id)
            Latch.enter(:soe_lock)
            :ok
          end)
        end)
      end)

    assert_receive {:latch_started, :soe_lock, 1}, 5_000

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             unboxed(fn -> sign_out_everyone(ctx.platform) end)

    assert [%Ash.Error.Invalid.Timeout{timeout: 300}] = errors

    assert [_] = Latch.release_all(:soe_lock)
    assert {:ok, :ok} = Task.await(writer, 10_000)

    assert purpose(ctx.session.jti) == Token.user_purpose()
    assert purpose(ctx.cookie.jti) == Token.remember_me_purpose()
    refute_received {:latch_timeout, _, _}
  end

  defp cleanup(ctx) do
    users = Enum.map([ctx.platform.id, ctx.victim.id], &Ecto.UUID.dump!/1)
    subjects = Enum.map([ctx.platform.id, ctx.victim.id], &"user?id=#{&1}")

    Repo.query!("DELETE FROM instance_security_events WHERE actor_id = ANY($1)", [users])
    Repo.query!("DELETE FROM tokens WHERE subject = ANY($1)", [subjects])
    Repo.query!("DELETE FROM users WHERE id = ANY($1)", [users])
    Repo.query!("DELETE FROM organizations WHERE id = $1", [Ecto.UUID.dump!(ctx.org.id)])
  end
end
