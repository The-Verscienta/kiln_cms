defmodule KilnCMS.Provenance.KeyRegistryTest do
  @moduledoc """
  Scope-lifetime caching of key resolution (#643): `with_cache/1` collapses the
  repeated file reads / PEM parses (and the repeated unreadable-entry warnings)
  a batch of verifications would otherwise do, without a standing cache that
  could keep trusting rotated-out key material.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Provenance.KeyRegistry

  setup do
    prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Provenance, prev || []) end)
    :ok
  end

  # A retired-key file whose contents we control, so a rotation-in-place can be
  # simulated by rewriting it. Returns the path.
  defp retired_key_file! do
    path =
      Path.join(
        System.tmp_dir!(),
        "kiln-keyreg-#{System.pid()}-#{System.unique_integer([:positive])}.pub.pem"
      )

    private = KilnCMS.Keys.generate_rsa_pem() |> KilnCMS.Keys.rsa_private_key() |> elem(1)
    File.write!(path, KilnCMS.Keys.rsa_public_key_pem(private))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp configure(retired_keys) do
    active = KilnCMS.Keys.generate_rsa_pem()
    var = "KILN_TEST_KEYREG_#{System.unique_integer([:positive])}"
    System.put_env(var, active)
    on_exit(fn -> System.delete_env(var) end)

    Application.put_env(:kiln_cms, KilnCMS.Provenance,
      signing_key: {:env, %{"var" => var}},
      retired_keys: retired_keys,
      retired_key_files: []
    )
  end

  describe "with_cache/1" do
    test "resolves retired/0 once inside the scope regardless of call count" do
      path = retired_key_file!()
      configure([{:file, %{"path" => path}}])

      # The key_id is a fingerprint over the file's contents. If resolution were
      # re-run after the file is rewritten mid-scope, the second read would
      # return a different key_id — the cache means it does not.
      {first, second} =
        KeyRegistry.with_cache(fn ->
          [%{key_id: first}] = KeyRegistry.retired()

          other = KilnCMS.Keys.generate_rsa_pem() |> KilnCMS.Keys.rsa_private_key() |> elem(1)
          File.write!(path, KilnCMS.Keys.rsa_public_key_pem(other))

          [%{key_id: second}] = KeyRegistry.retired()
          {first, second}
        end)

      assert first == second
    end

    test "a stale retired path warns once for the whole scope, not once per call" do
      configure([{:file, %{"path" => "/nonexistent/kiln-keyreg-stale.pem"}}])

      log =
        capture_log(fn ->
          KeyRegistry.with_cache(fn ->
            for _ <- 1..25, do: KeyRegistry.retired()
          end)
        end)

      occurrences =
        log
        |> String.split("Skipping unreadable")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1
    end

    test "without a scope, every call re-resolves (a running server stays fresh)" do
      configure([{:file, %{"path" => "/nonexistent/kiln-keyreg-stale.pem"}}])

      log =
        capture_log(fn ->
          for _ <- 1..3, do: KeyRegistry.retired()
        end)

      occurrences =
        log
        |> String.split("Skipping unreadable")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 3
    end

    test "a separate scope re-reads, so content rotated in place is picked up without a restart" do
      path = retired_key_file!()
      configure([{:file, %{"path" => path}}])

      [%{key_id: before}] = KeyRegistry.with_cache(fn -> KeyRegistry.retired() end)

      # Operator rotates the key's contents at the same configured path.
      rotated = KilnCMS.Keys.generate_rsa_pem() |> KilnCMS.Keys.rsa_private_key() |> elem(1)
      File.write!(path, KilnCMS.Keys.rsa_public_key_pem(rotated))

      [%{key_id: after_rotation}] = KeyRegistry.with_cache(fn -> KeyRegistry.retired() end)

      refute before == after_rotation
    end

    test "the cache does not outlive the scope" do
      configure([])
      refute Process.get(KilnCMS.Provenance.KeyRegistry.Cache)
      KeyRegistry.with_cache(fn -> KeyRegistry.retired() end)
      refute Process.get(KilnCMS.Provenance.KeyRegistry.Cache)
    end

    test "the scope is torn down even when the body raises" do
      configure([])

      assert_raise RuntimeError, fn ->
        KeyRegistry.with_cache(fn -> raise "boom" end)
      end

      refute Process.get(KilnCMS.Provenance.KeyRegistry.Cache)
    end

    test "nesting reuses the outer scope rather than tearing it down early" do
      path = retired_key_file!()
      configure([{:file, %{"path" => path}}])

      result =
        KeyRegistry.with_cache(fn ->
          [%{key_id: outer}] = KeyRegistry.retired()

          inner = KeyRegistry.with_cache(fn -> KeyRegistry.retired() end)

          # The inner block's `after` must NOT have deleted the outer cache:
          # a resolution here still succeeds and the outer scope is intact.
          assert Process.get(KilnCMS.Provenance.KeyRegistry.Cache)
          {outer, inner}
        end)

      {outer, [%{key_id: inner}]} = result
      assert outer == inner
      refute Process.get(KilnCMS.Provenance.KeyRegistry.Cache)
    end

    test "current/0 does not cache an error, so a transient read glitch is retried in-scope" do
      # A key source that starts unresolvable (var unset) then becomes readable
      # stands in for a momentary File/env glitch on the first document of a
      # sweep. Caching that error would relabel every current-key signature
      # :unverifiable for the whole run (#643 review, MEDIUM).
      var = "KILN_TEST_KEYREG_TRANSIENT_#{System.unique_integer([:positive])}"
      on_exit(fn -> System.delete_env(var) end)

      Application.put_env(:kiln_cms, KilnCMS.Provenance,
        signing_key: {:env, %{"var" => var}},
        retired_keys: [],
        retired_key_files: []
      )

      result =
        KeyRegistry.with_cache(fn ->
          assert {:error, _} = KeyRegistry.current()
          System.put_env(var, KilnCMS.Keys.generate_rsa_pem())
          KeyRegistry.current()
        end)

      assert {:ok, %{key_id: _}} = result
    end

    test "current/0 DOES cache a success, so a rotation mid-scope is not seen" do
      var = "KILN_TEST_KEYREG_STABLE_#{System.unique_integer([:positive])}"
      System.put_env(var, KilnCMS.Keys.generate_rsa_pem())
      on_exit(fn -> System.delete_env(var) end)

      Application.put_env(:kiln_cms, KilnCMS.Provenance,
        signing_key: {:env, %{"var" => var}},
        retired_keys: [],
        retired_key_files: []
      )

      {first, second} =
        KeyRegistry.with_cache(fn ->
          {:ok, %{key_id: first}} = KeyRegistry.current()
          System.put_env(var, KilnCMS.Keys.generate_rsa_pem())
          {:ok, %{key_id: second}} = KeyRegistry.current()
          {first, second}
        end)

      assert first == second
    end

    test "the value returned is the body's value, uncached path unchanged" do
      configure([])
      assert KeyRegistry.with_cache(fn -> :sentinel end) == :sentinel
      # current/0 resolves the active key the same whether cached or not.
      assert {:ok, %{key_id: cached}} = KeyRegistry.with_cache(fn -> KeyRegistry.current() end)
      assert {:ok, %{key_id: uncached}} = KeyRegistry.current()
      assert cached == uncached
    end
  end
end
