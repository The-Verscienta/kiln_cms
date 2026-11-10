defmodule KilnCMSWeb.DraftWriteKeyRotationTest do
  @moduledoc """
  `POST /api/keys/rotate` (ADR 0012, "Rotation") over HTTP, and reuse
  detection: a rotated-away key presented again after the grace period burns
  its whole lineage and alerts the platform admins (#2245: an
  `api_key_abuse` security alert, or the plain mail when the alert cannot be
  raised).

  `async: false`: the reuse tests turn security alerts on
  (`KilnCMS.Test.SecurityAlerts.enable/0`, an `Application.put_env`).
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.DataCase, only: [drain_oban: 0]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKeyReuse
  alias KilnCMS.Test.SecurityAlerts

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rot-web-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp days(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  defp mint(owner, access \\ :draft_write, rotatable_until \\ :default) do
    window = if rotatable_until == :default, do: days(90), else: rotatable_until

    attrs =
      if access == :draft_write,
        do: %{access: access, rotatable_until: window},
        else: %{access: access}

    {:ok, key} = Accounts.mint_api_key(owner.id, "svc", days(7), attrs, actor: user(:admin))
    {key, Ash.Resource.get_metadata(key, :plaintext_api_key)}
  end

  defp rotate(authorization) do
    conn = build_conn() |> put_req_header("accept", "application/json")

    conn =
      if authorization,
        do: put_req_header(conn, "authorization", authorization),
        else: conn

    conn = post(conn, "/api/keys/rotate")
    {conn, Jason.decode!(conn.resp_body)}
  end

  # Push a successor's mint time back past the reuse grace period.
  defp age(key_id) do
    KilnCMS.Repo.query!(
      "UPDATE api_keys SET created_at = created_at - interval '1 hour' WHERE id = $1",
      [Ecto.UUID.dump!(key_id)]
    )
  end

  defp flush_mail do
    receive do
      {:email, _} -> flush_mail()
    after
      0 -> :ok
    end
  end

  defp sent_mail(acc \\ []) do
    receive do
      {:email, mail} -> sent_mail([mail | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A claim of the current platform window for `kind`, made on a real
  # connection in a transaction left open; the returned function rolls it back.
  defp hold_platform_claim(kind, window) do
    test = self()

    task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(KilnCMS.Repo, fn ->
          claim_and_wait(test, kind, window)
        end)
      end)

    assert_receive :held, 5_000

    fn ->
      send(task.pid, :release)
      Task.await(task)
    end
  end

  defp claim_and_wait(test, kind, window) do
    org_id = Accounts.default_org_id()

    KilnCMS.Repo.transaction(fn ->
      {:ok, _id} =
        KilnCMS.Security.AlertGate.claim("platform", kind, :platform, org_id, nil,
          window_ms: window
        )

      send(test, :held)

      receive do
        :release -> KilnCMS.Repo.rollback(:released)
      end
    end)
  end

  defp reuse_events do
    KilnCMS.Security.list_events!(
      %{type: :api_key_reuse_detected},
      actor: user(:admin),
      tenant: Accounts.default_org_id()
    )
  end

  defp live_in(lineage_id),
    do: Accounts.list_live_api_keys_in_lineage!(lineage_id, authorize?: false)

  test "rotates: 201, the new key once, no-store, and the old key stops working" do
    {key, secret} = mint(user(:viewer))

    {conn, body} = rotate("Bearer #{secret}")

    assert conn.status == 201
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"api_key" => "kiln_" <> _ = new_secret, "rotated_from_id" => from} = body["data"]
    assert from == key.id
    assert body["data"]["rotatable_until"]
    assert body["data"]["expires_at"]

    assert :error = Accounts.actor_from_api_key(secret)
    assert {:ok, _} = Accounts.actor_from_api_key(new_secret)

    # And the new key can rotate in turn.
    {conn, _} = rotate("Bearer #{new_secret}")
    assert conn.status == 201
  end

  test "401 without a key, with a non-kiln bearer, and with a bad key — flag or no flag" do
    for header <- [nil, "Bearer not-a-kiln-key", "Bearer kiln_bogus_x", "Basic abc"] do
      {conn, body} = rotate(header)
      assert conn.status == 401
      assert [%{"code" => "invalid_api_key"}] = body["errors"]
    end
  end

  test "403 for a key that may not rotate" do
    {_, read_secret} = mint(user(:viewer), :read)
    {_, rw_secret} = mint(user(:editor), :read_write)
    {_, no_window} = mint(user(:viewer), :draft_write, nil)

    for secret <- [read_secret, rw_secret, no_window] do
      {conn, body} = rotate("Bearer #{secret}")
      assert conn.status == 403
      assert [%{"code" => "forbidden"}] = body["errors"]
    end
  end

  test "409 when the owner has been promoted since the mint" do
    owner = user(:viewer)
    {_, secret} = mint(owner)
    Ash.Seed.update!(owner, %{role: :editor})

    {conn, body} = rotate("Bearer #{secret}")
    assert conn.status == 409
    assert [%{"code" => "not_rotatable"}] = body["errors"]
  end

  describe "reuse of a rotated-away key" do
    setup do
      SecurityAlerts.enable()
      admin = user(:admin)
      {key, secret} = mint(user(:viewer))

      {_conn, %{"data" => %{"id" => new_id, "api_key" => new_secret}}} =
        rotate("Bearer #{secret}")

      %{admin: admin, key: key, secret: secret, new_id: new_id, new_secret: new_secret}
    end

    test "within the grace period is a plain 401: no lineage burned", ctx do
      {conn, _} = rotate("Bearer #{ctx.secret}")
      assert conn.status == 401

      assert [%{id: id}] = live_in(ctx.key.id)
      assert id == ctx.new_id
      assert {:ok, _} = Accounts.actor_from_api_key(ctx.new_secret)
    end

    test "after the grace period revokes the live key and alerts the admins", ctx do
      age(ctx.new_id)

      {conn, _} = rotate("Bearer #{ctx.secret}")
      assert conn.status == 401

      assert [] = live_in(ctx.key.id)
      assert :error = Accounts.actor_from_api_key(ctx.new_secret)

      # The event, in the default org (the owner has no membership), and
      # nothing about it is mailed until the alert is delivered.
      assert [event] = reuse_events()
      assert event.target_id == ctx.key.id
      assert event.metadata == %{"name" => "svc", "revoked" => 1}
      drain_oban()
      assert sent_mail() == []

      SecurityAlerts.deliver()
      drain_oban()

      # Every platform admin is mailed (`mint/1`'s actor is one too), in no set
      # order, so look through all of them rather than only the first.
      mails = sent_mail()
      assert mails != []
      assert Enum.all?(mails, &(&1.subject =~ "A rotated API key was used again"))

      assert to_string(ctx.admin.email) in Enum.flat_map(
               mails,
               &Enum.map(&1.to, fn {_, to} -> to end)
             )
    end

    test "an alert that cannot be raised falls back to the plain mail", ctx do
      age(ctx.new_id)
      window = KilnCMS.Test.BudgetWindow.fresh_window_ms()
      Application.put_env(:kiln_cms, :security_alert_window_ms, window)
      on_exit(fn -> Application.delete_env(:kiln_cms, :security_alert_window_ms) end)

      # Another transaction holds this window's platform claim and does not
      # end: the reuse's claim times out on its row lock.
      release = hold_platform_claim(:api_key_abuse, window)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :reuse_detected = ApiKeyReuse.check(ctx.secret)
        end)

      release.()

      # The event did not commit without its alert, the lineage still burned,
      # and the admins were mailed directly.
      assert log =~ "mailing the platform admins directly"
      assert reuse_events() == []
      assert [] = live_in(ctx.key.id)
      drain_oban()

      assert_email_sent(fn mail -> mail.subject =~ "was used after it was rotated" end)
    end

    test "a dead lineage alarms nobody: repeats send no more mail", ctx do
      age(ctx.new_id)

      assert :reuse_detected = ApiKeyReuse.check(ctx.secret)
      SecurityAlerts.deliver()
      drain_oban()
      assert_email_sent(fn mail -> mail.subject =~ "A rotated API key was used again" end)
      # One mail per platform admin: every `mint/1` above seeded one.
      flush_mail()

      for _ <- 1..3 do
        assert :ok = ApiKeyReuse.check(ctx.secret)
        {conn, _} = rotate("Bearer #{ctx.secret}")
        assert conn.status == 401
      end

      SecurityAlerts.deliver()
      drain_oban()
      refute_email_sent()
      assert length(reuse_events()) == 1
    end

    test "burns the whole chain, however far it has moved on", ctx do
      {_, %{"data" => %{"id" => third_id, "api_key" => third}}} =
        rotate("Bearer #{ctx.new_secret}")

      age(ctx.new_id)
      age(third_id)

      assert :reuse_detected = ApiKeyReuse.check(ctx.secret)
      assert :error = Accounts.actor_from_api_key(third)
      assert [] = live_in(ctx.key.id)
    end

    test "needs the real secret: a forged key with the same id burns nothing", ctx do
      age(ctx.new_id)

      # Same id, different random bytes, valid CRC.
      <<_::binary-size(32), id::binary-size(16)>> =
        ctx.secret
        |> String.split("_")
        |> Enum.at(1)
        |> AshAuthentication.Base.bindecode62()
        |> elem(1)

      # `encode62` raises on a leading zero byte, so the first byte is never 0
      # (otherwise this fails about 1 run in 256).
      token = <<Enum.random(1..255)>> <> :crypto.strong_rand_bytes(31) <> id

      forged =
        "kiln_#{AshAuthentication.Base.encode62(token)}_" <>
          AshAuthentication.Base.encode62(:erlang.crc32(token))

      assert :ok = ApiKeyReuse.check(forged)
      assert [_live] = live_in(ctx.key.id)
    end
  end

  test "a key an admin revoked (not rotated) burns nothing when presented" do
    owner = user(:viewer)
    {key, secret} = mint(owner)
    {:ok, _} = Accounts.revoke_api_key(key, actor: user(:admin))

    assert :ok = ApiKeyReuse.check(secret)
  end

  test "garbage is not an error" do
    for junk <- ["", "kiln_", "kiln_a_b", "nope", String.duplicate("x", 500)] do
      assert :ok = ApiKeyReuse.check(junk)
    end
  end
end
