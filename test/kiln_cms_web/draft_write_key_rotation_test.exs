defmodule KilnCMSWeb.DraftWriteKeyRotationTest do
  @moduledoc """
  `POST /api/keys/rotate` (ADR 0012, "Rotation") over HTTP, and reuse
  detection: a rotated-away key presented again after the grace period burns
  its whole lineage and mails the platform admins.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.DataCase, only: [drain_oban: 0]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKeyReuse

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

    test "after the grace period revokes the live key and mails the admins", ctx do
      age(ctx.new_id)

      {conn, _} = rotate("Bearer #{ctx.secret}")
      assert conn.status == 401

      assert [] = live_in(ctx.key.id)
      assert :error = Accounts.actor_from_api_key(ctx.new_secret)

      drain_oban()

      assert_email_sent(fn mail ->
        assert mail.subject =~ "was used after it was rotated"
        assert {_, to} = hd(mail.to)
        to == to_string(ctx.admin.email)
      end)
    end

    test "a dead lineage alarms nobody: repeats send no more mail", ctx do
      age(ctx.new_id)

      assert :reuse_detected = ApiKeyReuse.check(ctx.secret)
      drain_oban()
      assert_email_sent(fn mail -> mail.subject =~ "was used after it was rotated" end)
      # One mail per platform admin: every `mint/1` above seeded one.
      flush_mail()

      for _ <- 1..3 do
        assert :ok = ApiKeyReuse.check(ctx.secret)
        {conn, _} = rotate("Bearer #{ctx.secret}")
        assert conn.status == 401
      end

      drain_oban()
      refute_email_sent()
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

      token = :crypto.strong_rand_bytes(32) <> id

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
