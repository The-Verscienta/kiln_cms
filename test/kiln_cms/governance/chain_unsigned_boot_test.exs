defmodule KilnCMS.Governance.ChainUnsignedBootTest do
  @moduledoc """
  Boot advisory when the chain is in use without a signing key (#1056).
  """
  # async: false — mutates `:audit_anchor_every_write` / Provenance config.
  use ExUnit.Case, async: false

  alias KilnCMS.Governance.Chain

  describe "unsigned_while_in_use?/4" do
    test "warns when every-write anchoring is on and there is no key" do
      assert Chain.unsigned_while_in_use?(true, false, true, false)
    end

    test "warns when anchors already exist and there is no key" do
      assert Chain.unsigned_while_in_use?(true, false, false, true)
    end

    test "stays quiet when a signing key is present" do
      refute Chain.unsigned_while_in_use?(true, true, true, true)
    end

    test "stays quiet when anchoring is disabled" do
      refute Chain.unsigned_while_in_use?(false, false, true, true)
    end

    test "stays quiet for a default install that never anchors" do
      refute Chain.unsigned_while_in_use?(true, false, false, false)
    end
  end

  describe "unsigned_while_in_use?/0" do
    setup do
      prev_every = Application.get_env(:kiln_cms, :audit_anchor_every_write)
      prev_enabled = Application.get_env(:kiln_cms, :audit_anchors_enabled)
      prev_prov = Application.get_env(:kiln_cms, KilnCMS.Provenance)

      on_exit(fn ->
        restore(:audit_anchor_every_write, prev_every)
        restore(:audit_anchors_enabled, prev_enabled)
        restore_prov(prev_prov)
      end)

      :ok
    end

    test "fires when every-write is on and the provenance key is unset" do
      Application.put_env(:kiln_cms, :audit_anchors_enabled, true)
      Application.put_env(:kiln_cms, :audit_anchor_every_write, true)
      Application.put_env(:kiln_cms, KilnCMS.Provenance, signing_key: nil)

      assert Chain.unsigned_while_in_use?()
    end

    test "stays quiet when every-write is on and a key resolves" do
      pem = KilnCMS.Keys.generate_rsa_pem()
      var = "KILN_TEST_UNSIGNED_BOOT_#{System.unique_integer([:positive])}"
      System.put_env(var, pem)

      on_exit(fn -> System.delete_env(var) end)

      Application.put_env(:kiln_cms, :audit_anchors_enabled, true)
      Application.put_env(:kiln_cms, :audit_anchor_every_write, true)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Provenance,
        signing_key: {:env, %{"var" => var}}
      )

      refute Chain.unsigned_while_in_use?()
    end
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp restore_prov(nil), do: Application.delete_env(:kiln_cms, KilnCMS.Provenance)
  defp restore_prov(value), do: Application.put_env(:kiln_cms, KilnCMS.Provenance, value)
end
