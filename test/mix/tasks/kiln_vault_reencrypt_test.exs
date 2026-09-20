defmodule Mix.Tasks.Kiln.Vault.ReencryptTest do
  @moduledoc """
  `mix kiln.vault.reencrypt` (#1487): the operator's end of the walk
  `KilnCMS.Keys.ReencryptTest` covers. What this holds the task to is the
  interface — the old secret comes from a variable *named* on the command
  line, never the command line itself; a dry run says "would"; and a value
  that opens under no secret given is a non-zero exit, not a quiet pass an
  operator would retire the old secret on.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.FederationFixtures
  alias KilnCMS.Keys.Vault
  alias Mix.Tasks.Kiln.Vault.Reencrypt

  @var "KILN_TEST_OLD_SECRET_KEY_BASE"
  @old "old-secret-key-base-" <> String.duplicate("o", 64)
  @new "new-secret-key-base-" <> String.duplicate("n", 64)

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    endpoint = Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint)
    vault = Application.get_env(:kiln_cms, Vault)

    on_exit(fn ->
      Mix.shell(previous_shell)
      System.delete_env(@var)
      Application.put_env(:kiln_cms, KilnCMSWeb.Endpoint, endpoint)

      if vault,
        do: Application.put_env(:kiln_cms, Vault, vault),
        else: Application.delete_env(:kiln_cms, Vault)
    end)

    use_secret(@old)
    settings = FederationFixtures.enable_site!(KilnCMS.Accounts.default_org_id())
    use_secret(@new)

    %{settings: settings}
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

  defp output, do: collect([]) |> Enum.reverse() |> Enum.join("\n")

  defp collect(acc) do
    receive do
      {:mix_shell, _level, [line]} -> collect([line | acc])
    after
      0 -> acc
    end
  end

  defp stored_key(settings) do
    %{rows: [[value]]} =
      KilnCMS.Repo.query!("SELECT private_key_encrypted FROM site_federation WHERE id = $1", [
        Ecto.UUID.dump!(settings.id)
      ])

    value
  end

  test "reads the old secret from the variable it is named, and re-encrypts", ctx do
    System.put_env(@var, @old)

    Reencrypt.run(["--old-secret-key-base-env", @var])

    assert output() =~ ~r/site_federation\.private_key_encrypted: \d+ re-encrypted/
    assert {:ok, _pem} = Vault.decrypt(stored_key(ctx.settings), @new)
  end

  test "--dry-run says what it would do and writes nothing", ctx do
    System.put_env(@var, @old)
    before = stored_key(ctx.settings)

    Reencrypt.run(["--dry-run", "--old-secret-key-base-env", @var])

    assert output() =~ ~r/site_federation\.private_key_encrypted: \d+ would re-encrypt/
    assert stored_key(ctx.settings) == before
  end

  test "a named variable that is unset is refused before anything runs" do
    System.delete_env(@var)

    assert_raise Mix.Error, ~r/#{@var} is not set/, fn ->
      Reencrypt.run(["--old-secret-key-base-env", @var])
    end
  end

  # Without the old secret the actor key opens under nothing, so the task must
  # fail — this is exactly the state in which retiring the old secret loses data.
  test "values no given secret opens make the task exit non-zero and stay untouched", ctx do
    before = stored_key(ctx.settings)

    assert_raise Mix.Error, ~r/left untouched/, fn -> Reencrypt.run([]) end

    out = output()
    assert out =~ "No old secret given"
    assert out =~ "unreadable: site_federation.private_key_encrypted id=#{ctx.settings.id}"
    assert stored_key(ctx.settings) == before
  end

  test "the secret itself is not an accepted argument" do
    assert_raise OptionParser.ParseError, fn ->
      Reencrypt.run(["--old-secret-key-base", @old])
    end
  end
end
