defmodule Mix.Tasks.Kiln.FederationTest do
  @moduledoc """
  `mix kiln.federation status|enable|disable|rekey` (#491, #1487) — the only way to turn a
  site's fediverse identity on, since phase 1 has no admin screen.

  The task had no test at all. The claim worth holding it to is the one its
  moduledoc makes in bold: **the origin is permanent**. An actor id is a site's
  permanent name in the fediverse — remote servers store it, deduplicate on it
  and deliver to it — so re-enabling must never mint a different one, whatever
  `--origin` says the second time. A task that silently re-minted would strand
  every existing follower, and nothing on the screen would say so.

  The other half is the deployment gate: the site row is only one of the two
  switches, and enabling while `KILN_FEDERATION_ENABLED` is unset must say so
  rather than leave an operator announcing a handle that 404s.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Federation.Follower
  alias KilnCMS.Federation.SiteFederation
  alias KilnCMS.OrgFixtures
  alias Mix.Tasks.Kiln.Federation

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  defp output do
    collect([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp collect(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect([line | acc])
      {:mix_shell, :error, [line]} -> collect([line | acc])
    after
      0 -> acc
    end
  end

  defp settings(org_id) do
    case Ash.read!(SiteFederation, authorize?: false, tenant: org_id) do
      [settings] -> settings
      [] -> nil
    end
  end

  defp with_deployment_flag(value) do
    original = Application.get_env(:kiln_cms, KilnCMS.Federation, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Federation, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Federation,
      Keyword.put(original, :enabled, value)
    )
  end

  describe "status" do
    test "a site that never enabled federation says so, and mints nothing" do
      Federation.run(["status"])

      assert output() =~ "Site:       not configured (never enabled)"
      assert settings(KilnCMS.Accounts.default_org_id()) == nil
    end

    test "an enabled site reports its handle, actor and follower count" do
      org = OrgFixtures.org("fedstatus")
      Federation.run(["enable", "--org-id", org.id, "--origin", "https://fed.example.com"])

      Ash.Seed.seed!(Follower, %{
        org_id: org.id,
        actor_uri: "https://remote.example/users/someone",
        inbox_uri: "https://remote.example/users/someone/inbox"
      })

      Federation.run(["status", "--org-id", org.id])
      out = output()

      assert out =~ "Site:       enabled"
      assert out =~ "Handle:     @#{org.slug}@fed.example.com"
      assert out =~ "Actor:      https://fed.example.com/actor"
      assert out =~ "Followers:  1"
    end

    test "the deployment gate is the first line, either way" do
      with_deployment_flag(false)
      Federation.run(["status"])
      assert output() =~ ~r/\ADeployment: DISABLED — every federation route 404s/

      with_deployment_flag(true)
      Federation.run(["status"])
      assert output() =~ ~r/\ADeployment: enabled \(KILN_FEDERATION_ENABLED\)/
    end
  end

  describe "enable" do
    test "mints the identity, prints the handle, and turns the site on" do
      org = OrgFixtures.org("fedenable")

      Federation.run(["enable", "--org-id", org.id, "--origin", "https://kiln.example.com"])
      out = output()

      assert out =~ "Federation enabled for this site."
      assert out =~ "Handle: @#{org.slug}@kiln.example.com"
      assert out =~ "Actor:  https://kiln.example.com/actor"

      settings = settings(org.id)
      assert settings.enabled
      assert settings.origin == "https://kiln.example.com"
      assert settings.username == org.slug
    end

    test "the handle defaults to the org's slug, and --username overrides it" do
      org = OrgFixtures.org("fedname")

      Federation.run(["enable", "--org-id", org.id, "--origin", "https://a.example.com"])
      assert output() =~ "Handle: @#{org.slug}@a.example.com"

      other = OrgFixtures.org("fedname2")

      Federation.run([
        "enable",
        "--org-id",
        other.id,
        "--origin",
        "https://b.example.com",
        "--username",
        "newsroom"
      ])

      assert output() =~ "Handle: @newsroom@b.example.com"
    end

    test "with the deployment flag off, it says the routes still 404" do
      with_deployment_flag(false)
      org = OrgFixtures.org("fedgate")

      Federation.run(["enable", "--org-id", org.id, "--origin", "https://c.example.com"])

      # Enabling the site row alone is half the gate. Without this line an
      # operator would announce a handle that answers 404 to every visitor.
      assert output() =~ "KILN_FEDERATION_ENABLED is not set"
    end

    test "with the deployment flag on, there is no warning to ignore" do
      with_deployment_flag(true)
      org = OrgFixtures.org("fedgateon")

      Federation.run(["enable", "--org-id", org.id, "--origin", "https://d.example.com"])

      refute output() =~ "KILN_FEDERATION_ENABLED is not set"
    end
  end

  describe "the identity is permanent (the moduledoc's promise)" do
    test "re-enabling keeps the original actor id, whatever --origin says" do
      org = OrgFixtures.org("fedpermanent")
      Federation.run(["enable", "--org-id", org.id, "--origin", "https://first.example.com"])
      minted = settings(org.id)

      Federation.run(["disable", "--org-id", org.id])

      Federation.run([
        "enable",
        "--org-id",
        org.id,
        "--origin",
        "https://moved.example.com",
        "--username",
        "renamed"
      ])

      again = settings(org.id)

      # Remote servers cached the first actor id. Re-minting here would strand
      # every follower, silently — moving domains is a migration, not a flag.
      assert again.id == minted.id
      assert again.origin == "https://first.example.com"
      assert again.username == minted.username
      assert again.enabled
      assert output() =~ "Handle: @#{org.slug}@first.example.com"
    end

    test "each site keeps its own identity" do
      one = OrgFixtures.org("fedone")
      two = OrgFixtures.org("fedtwo")

      Federation.run(["enable", "--org-id", one.id, "--origin", "https://one.example.com"])
      Federation.run(["enable", "--org-id", two.id, "--origin", "https://two.example.com"])

      assert settings(one.id).origin == "https://one.example.com"
      assert settings(two.id).origin == "https://two.example.com"
    end
  end

  describe "disable" do
    test "turns the site off but keeps the identity for its followers" do
      org = OrgFixtures.org("feddisable")
      Federation.run(["enable", "--org-id", org.id, "--origin", "https://e.example.com"])
      minted = settings(org.id)

      Federation.run(["disable", "--org-id", org.id])
      out = output()

      assert out =~ "Federation disabled."
      assert out =~ "re-enabling restores the same handle and key"

      after_disable = settings(org.id)
      refute after_disable.enabled
      assert after_disable.origin == minted.origin
      assert after_disable.username == minted.username
    end

    test "a site that never enabled it is a no-op, not an error" do
      org = OrgFixtures.org("fednever")

      Federation.run(["disable", "--org-id", org.id])

      assert output() =~ "never enabled for this site; nothing to do"
      assert settings(org.id) == nil
    end
  end

  describe "rekey (#1487)" do
    test "replaces the key, keeps the handle, and queues the actor Update" do
      org = OrgFixtures.org("fedrekey")
      Federation.run(["enable", "--org-id", org.id, "--origin", "https://r.example.com"])
      minted = settings(org.id)

      Federation.run(["rekey", "--org-id", org.id])
      out = output()

      assert out =~ "Re-keyed."
      # The honest caveat: an Update is a request, not a guarantee.
      assert out =~ "Some remote servers may keep the old key"

      rekeyed = settings(org.id)
      assert rekeyed.origin == minted.origin
      assert rekeyed.username == minted.username
      refute rekeyed.public_key_pem == minted.public_key_pem

      assert [_job] =
               Oban.Job
               |> KilnCMS.Repo.all()
               |> Enum.filter(
                 &(&1.worker == "KilnCMS.Federation.ActorUpdateWorker" and
                     &1.args["org_id"] == org.id)
               )
    end

    test "a site that never enabled federation has nothing to re-key" do
      org = OrgFixtures.org("fedrekeynever")

      assert_raise Mix.Error, ~r/never enabled/, fn ->
        Federation.run(["rekey", "--org-id", org.id])
      end
    end

    test "status says when the key is unreadable, the fault nothing else shows" do
      org = OrgFixtures.org("fedkeyline")
      Federation.run(["enable", "--org-id", org.id, "--origin", "https://k.example.com"])

      Federation.run(["status", "--org-id", org.id])
      assert output() =~ "Key:        readable"

      KilnCMS.Repo.query!(
        "UPDATE site_federation SET private_key_encrypted = $1 WHERE id = $2",
        [
          KilnCMS.Keys.Vault.encrypt("pem", "another-secret-" <> String.duplicate("q", 64)),
          Ecto.UUID.dump!(settings(org.id).id)
        ]
      )

      Federation.run(["status", "--org-id", org.id])
      assert output() =~ "Key:        UNREADABLE"
    end
  end

  describe "arguments" do
    test "an unknown subcommand prints the usage" do
      assert_raise Mix.Error, ~r/Usage: mix kiln.federation status\|enable\|disable\|rekey/, fn ->
        Federation.run(["sync"])
      end
    end

    test "no subcommand prints the usage too" do
      assert_raise Mix.Error, ~r/Usage: mix kiln.federation/, fn -> Federation.run([]) end
    end

    test "an unknown switch is refused rather than ignored" do
      assert_raise OptionParser.ParseError, fn ->
        Federation.run(["status", "--org", "whatever"])
      end
    end
  end
end
