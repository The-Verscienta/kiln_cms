defmodule KilnCMSWeb.SessionPolicyLiveTimeoutTest do
  @moduledoc """
  `/editor/sessions`' "Sign out everyone on every site" (#2491) when the
  sign-out runs past `KilnCMS.Accounts.Sessions.revoke_timeout/0`: the page
  stays up, says it took too long, and nobody is signed out.

  A session committed **outside** the sandbox is held `FOR UPDATE` by another
  transaction (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) until the test
  releases it, so the page's sign-out waits on it past its timeout. What is
  committed is deleted again on exit. Not `async`: the timeout is shortened
  with `Application.put_env/3`, which every test running alongside would see,
  and the sign-out reaches every live session in the database.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts.SignOutEveryone
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo
  alias KilnCMS.Test.Latch

  @password "password1234!"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    start_supervised!({Latch, name: :spl_timeout, listener: self()})
    n = System.unique_integer([:positive])

    held =
      unboxed(fn ->
        user =
          Ash.Seed.seed!(User, %{
            email: "spl-timeout-#{n}@example.com",
            hashed_password: Bcrypt.hash_pwd_salt(@password),
            confirmed_at: DateTime.utc_now(),
            role: :editor
          })

        Ash.Seed.seed!(Token, %{
          jti: "spl-timeout-#{n}",
          subject: "user?id=#{user.id}",
          purpose: "user",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.query!("DELETE FROM tokens WHERE subject = $1", [held.subject])
        Repo.query!("DELETE FROM users WHERE email = $1", ["spl-timeout-#{n}@example.com"])
      end)
    end)

    Application.put_env(:kiln_cms, :sign_out_everyone_timeout, 300)
    on_exit(fn -> Application.delete_env(:kiln_cms, :sign_out_everyone_timeout) end)

    %{org: org("spltimeout"), held: held}
  end

  test "a sign-out past its timeout says so and signs nobody out", %{
    conn: conn,
    org: org,
    held: held
  } do
    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT 1 FROM tokens WHERE jti = $1 FOR UPDATE", [held.jti])
            Latch.enter(:spl_timeout)
            :ok
          end)
        end)
      end)

    assert_receive {:latch_started, :spl_timeout, 1}, 5_000

    {:ok, lv, _html} =
      conn |> org_conn(org) |> log_in(authed_user()) |> live(~p"/editor/sessions")

    html =
      render_submit(lv, "sign_out_everyone", %{
        "sign_out_everyone" => %{"confirmation" => SignOutEveryone.phrase(), "keep_me" => "true"}
      })

    assert html =~ "it took too long and was undone"
    refute html =~ "timed out after"
    refute html =~ "57014"

    assert [_] = Latch.release_all(:spl_timeout)
    assert {:ok, :ok} = Task.await(holder, 10_000)

    assert unboxed(fn ->
             Repo.one!(from(t in Token, where: t.jti == ^held.jti, select: t.purpose))
           end) == "user"

    refute_received {:latch_timeout, _, _}
  end

  # The per-site "Sign out everyone" took the same lock pass and timeout
  # (#2491): its flash says so too, never Ash's own timeout text.
  test "a site's sign-out past its timeout says so and signs nobody out", %{
    conn: conn,
    org: org,
    held: held
  } do
    site_jti = "#{held.jti}-site"

    unboxed(fn ->
      Repo.query!(
        "UPDATE tokens SET org_id = $1 WHERE jti = $2",
        [Ecto.UUID.dump!(org.id), held.jti]
      )
    end)

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT 1 FROM tokens WHERE jti = $1 FOR UPDATE", [held.jti])
            Latch.enter(:spl_timeout)
            :ok
          end)
        end)
      end)

    assert_receive {:latch_started, :spl_timeout, 1}, 5_000

    {:ok, lv, _html} =
      conn |> org_conn(org) |> log_in(authed_user()) |> live(~p"/editor/sessions")

    html = render_submit(lv, "sign_out_all", %{"sign_out_all" => %{"keep_me" => "true"}})

    assert html =~ "it took too long and was undone"
    refute html =~ "timed out after"
    refute html =~ "57014"
    refute html =~ site_jti

    assert [_] = Latch.release_all(:spl_timeout)
    assert {:ok, :ok} = Task.await(holder, 10_000)

    assert unboxed(fn ->
             Repo.one!(from(t in Token, where: t.jti == ^held.jti, select: t.purpose))
           end) == "user"

    refute_received {:latch_timeout, _, _}
  end

  defp authed_user do
    email = "spl-timeout-admin-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
