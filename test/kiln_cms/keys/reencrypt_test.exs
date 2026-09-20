defmodule KilnCMS.Keys.ReencryptTest do
  @moduledoc """
  The vault re-encryption walk (#1487), against real rows written by the real
  actions: a federating site's actor key and a pasted billing secret, stored
  under one `secret_key_base` and then walked across to another.

  The properties an operator relies on: every value moves, a second run is a
  no-op, a dry run writes nothing, and a value that opens under no secret it
  was given is reported and left byte-for-byte alone.

  Assertions are by row id, not by column totals: the walk reads whole tables,
  and a test database is not guaranteed to hold only this test's rows.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Billing
  alias KilnCMS.Federation.SiteFederation
  alias KilnCMS.FederationFixtures
  alias KilnCMS.Keys.Reencrypt
  alias KilnCMS.Keys.Vault

  @old "old-secret-key-base-" <> String.duplicate("o", 64)
  @new "new-secret-key-base-" <> String.duplicate("n", 64)

  setup do
    endpoint = Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint)
    vault = Application.get_env(:kiln_cms, Vault)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMSWeb.Endpoint, endpoint)

      if vault,
        do: Application.put_env(:kiln_cms, Vault, vault),
        else: Application.delete_env(:kiln_cms, Vault)
    end)

    # Everything below is written under the OLD secret, by the real actions.
    use_secret(@old)
    org_id = KilnCMS.Accounts.default_org_id()
    federation = FederationFixtures.enable_site!(org_id)
    {:ok, actor_pem} = Vault.decrypt(federation.private_key_encrypted, @old)

    {:ok, billing} =
      Billing.store_billing_secret(Billing.ensure_settings!(), :secret_key, "sk_test_rotate",
        authorize?: false
      )

    # Then the deployment restarts with the NEW one.
    use_secret(@new)

    %{org_id: org_id, federation: federation, actor_pem: actor_pem, billing: billing}
  end

  defp use_secret(secret) do
    endpoint = Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint)

    Application.put_env(
      :kiln_cms,
      KilnCMSWeb.Endpoint,
      Keyword.put(endpoint, :secret_key_base, secret)
    )

    Application.put_env(:kiln_cms, Vault, previous_secret_key_bases: [])
  end

  defp report(reports, table, column),
    do: Enum.find(reports, &(&1.table == table and &1.column == column))

  defp stored(table, column, id) do
    %{rows: [[value]]} =
      KilnCMS.Repo.query!(
        "SELECT #{column} FROM #{table} WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    value
  end

  test "moves every value to the current secret, and a second run changes nothing", ctx do
    # Before: the rotated deployment cannot open what it stored.
    assert SiteFederation.private_key_pem(ctx.federation) == nil

    reports = Reencrypt.run(old_secret_key_bases: [@old])

    federation = report(reports, "site_federation", "private_key_encrypted")
    billing = report(reports, "billing_settings", "secret_key_encrypted")
    assert federation.rotated >= 1
    assert billing.rotated >= 1
    refute ctx.federation.id in federation.unreadable
    refute ctx.billing.id in billing.unreadable
    # The webhook secret was never pasted: counted, not touched.
    assert report(reports, "billing_settings", "webhook_secret_encrypted").empty >= 1

    # After: both open under the NEW secret alone, with the same plaintext.
    assert {:ok, pem} =
             Vault.decrypt(
               stored("site_federation", "private_key_encrypted", ctx.federation.id),
               @new
             )

    assert pem == ctx.actor_pem

    assert {:ok, "sk_test_rotate"} =
             Vault.decrypt(
               stored("billing_settings", "secret_key_encrypted", ctx.billing.id),
               @new
             )

    # And the running app reads them again, with no rotation window configured.
    assert {:ok, "sk_test_rotate"} = KilnCMS.Keys.fetch(:billing_secret_key)

    # Idempotent: nothing is left under the old secret, so nothing moves.
    before = stored("site_federation", "private_key_encrypted", ctx.federation.id)
    second = Reencrypt.run(old_secret_key_bases: [@old])

    assert Enum.all?(second, &(&1.rotated == 0))
    assert report(second, "site_federation", "private_key_encrypted").current >= 1
    assert stored("site_federation", "private_key_encrypted", ctx.federation.id) == before
  end

  test "the old secret defaults to the configured rotation window", ctx do
    Application.put_env(:kiln_cms, Vault, previous_secret_key_bases: [@old])

    Reencrypt.run()

    assert {:ok, _pem} =
             Vault.decrypt(
               stored("site_federation", "private_key_encrypted", ctx.federation.id),
               @new
             )
  end

  test "a dry run classifies without writing", ctx do
    before = stored("site_federation", "private_key_encrypted", ctx.federation.id)

    reports = Reencrypt.run(old_secret_key_bases: [@old], dry_run: true)

    assert report(reports, "site_federation", "private_key_encrypted").rotated >= 1
    assert stored("site_federation", "private_key_encrypted", ctx.federation.id) == before
    assert {:ok, _} = Vault.decrypt(before, @old)
  end

  # Overwriting ciphertext nobody can open today would destroy the one copy the
  # right old secret could still recover.
  test "a value no given secret opens is reported by id and never written", ctx do
    # Written under a THIRD secret the run is never told about.
    lost = Vault.encrypt("unrecoverable", "a-third-secret-" <> String.duplicate("x", 64))

    KilnCMS.Repo.query!(
      "UPDATE site_federation SET private_key_encrypted = $1 WHERE id = $2",
      [lost, Ecto.UUID.dump!(ctx.federation.id)]
    )

    reports = Reencrypt.run(old_secret_key_bases: [@old])

    assert ctx.federation.id in report(reports, "site_federation", "private_key_encrypted").unreadable
    assert stored("site_federation", "private_key_encrypted", ctx.federation.id) == lost

    # The operator-facing wrapper turns that into an error, not a quiet pass.
    assert {:error, message} =
             Reencrypt.run_and_report([dry_run: true], fn _line -> :ok end)

    assert message =~ "left untouched"
  end

  describe "old_secrets/1" do
    test "reads the variable it is named, and refuses unset or blank" do
      var = "KILN_TEST_OLD_SECRET_KEY_BASE"
      System.delete_env(var)
      on_exit(fn -> System.delete_env(var) end)

      assert {:error, "#{var} is not set"} == Reencrypt.old_secrets(var)

      System.put_env(var, "  ")
      assert {:error, "#{var} is blank"} == Reencrypt.old_secrets(var)

      System.put_env(var, @old)
      assert {:ok, [@old]} == Reencrypt.old_secrets(var)
    end
  end
end
