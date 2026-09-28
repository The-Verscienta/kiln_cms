defmodule KilnCMS.Accounts.OrgSlugTest do
  @moduledoc """
  `Organization.slug` is a DNS label (#1710).

  Tenant resolution downcases the request host and matches the slug exactly,
  so a slug stored as `Acme` or `my_site` was unreachable at its subdomain.
  New writes are normalized and checked; rows stored before that are reported
  by `mix kiln.org_slugs`, and downcased by `--fix` only where that is all it
  takes and it clashes with nothing.

  `async: false`: the console-host tests put application env, and the audit
  reads the whole organizations table.
  """
  use KilnCMS.DataCase, async: false

  # Creating a second org through the action logs the multi-org advisories
  # (#1661, #1662), and `--fix` logs each rename.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgSlug
  alias KilnCMS.Accounts.OrgSlugAudit
  alias KilnCMSWeb.Tenant

  defp n, do: System.unique_integer([:positive])

  defp create(slug),
    do: Accounts.create_organization(%{name: "Org", slug: slug}, authorize?: false)

  defp slug_error(result) do
    assert {:error, %Ash.Error.Invalid{errors: errors}} = result
    assert [%{field: :slug, message: message}] = errors
    message
  end

  # Rows stored before the rule existed: raw SQL, so no action (and no
  # validation) is involved.
  defp legacy_org!(slug) do
    id = Ecto.UUID.generate()

    KilnCMS.Repo.query!(
      """
      INSERT INTO organizations (id, name, slug, status, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'active', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [Ecto.UUID.dump!(id), "Legacy #{slug}", slug]
    )

    Accounts.get_organization!(id, authorize?: false)
  end

  defp stored_slug(id), do: Accounts.get_organization!(id, authorize?: false).slug

  defp console_host!(host) do
    previous = Application.get_env(:kiln_cms, :console_host)
    Application.put_env(:kiln_cms, :console_host, host)
    on_exit(fn -> Application.put_env(:kiln_cms, :console_host, previous) end)
  end

  describe "OrgSlug" do
    test "normalize/1 trims and downcases" do
      assert OrgSlug.normalize("  Acme-Site ") == "acme-site"
      assert OrgSlug.normalize(nil) == nil
    end

    test "check/1 accepts DNS labels, 1 to 63 characters" do
      for ok <- ["a", "acme", "a1", "my-site", "x--y", "9lives", String.duplicate("a", 63)] do
        assert OrgSlug.check(ok) == :ok, "expected #{inspect(ok)} to be a label"
      end
    end

    test "check/1 refuses what can't be a host label" do
      for bad <- [
            "",
            "Acme",
            "my_site",
            "a.b",
            "-lead",
            "trail-",
            "sp ace",
            "ü",
            String.duplicate("a", 64)
          ] do
        assert OrgSlug.check(bad) == {:error, :format}, "expected #{inspect(bad)} refused"
      end
    end

    test "check/1 refuses the reserved labels" do
      for reserved <- ~w(www console api mail) do
        assert OrgSlug.check(reserved) == {:error, :reserved}
      end
    end

    test "the console host's first label is reserved when it sits under the base host" do
      console_host!("admin." <> Tenant.base_host())
      assert "admin" in OrgSlug.reserved()
      assert OrgSlug.check("admin") == {:error, :reserved}
    end

    test "a console host outside the base host reserves nothing extra" do
      console_host!("admin.elsewhere.test")
      assert OrgSlug.reserved() == ~w(www console api mail)
    end
  end

  describe "the create action" do
    test "downcases and trims the slug it stores" do
      slug = "Acme-#{n()}"
      assert {:ok, org} = create("  #{slug} ")
      assert org.slug == String.downcase(slug)
    end

    test "a mixed-case slug is reachable at the host a browser sends" do
      assert {:ok, org} = create("Mixed-#{n()}")
      host = "#{org.slug}.#{Tenant.base_host()}"

      assert {:ok, resolved} = Tenant.fetch_org(host)
      assert resolved.id == org.id
    end

    test "refuses a slug that can't be a host label, with a clear message" do
      for bad <- [
            "my_site_#{n()}",
            "a.b#{n()}",
            "-lead#{n()}",
            "trail#{n()}-",
            "x#{String.duplicate("y", 63)}"
          ] do
        assert slug_error(create(bad)) =~ "lowercase letters, digits or hyphens"
      end
    end

    test "refuses a reserved slug" do
      assert slug_error(create("WWW")) == "is reserved"
      assert slug_error(create("api")) == "is reserved"
    end

    test "refuses the console host's label" do
      console_host!("admin." <> Tenant.base_host())
      assert slug_error(create("admin")) == "is reserved"
    end
  end

  describe "the update action" do
    test "normalizes a new slug" do
      {:ok, org} = create("upd-#{n()}")
      slug = "Renamed-#{n()}"

      assert {:ok, updated} =
               Accounts.update_organization(org, %{slug: slug}, authorize?: false)

      assert updated.slug == String.downcase(slug)
    end

    test "refuses an invalid new slug" do
      {:ok, org} = create("upd-#{n()}")

      assert Accounts.update_organization(org, %{slug: "bad_#{n()}"}, authorize?: false)
             |> slug_error() =~ "lowercase letters"
    end

    test "leaves a legacy slug alone when something else changes" do
      org = legacy_org!("Legacy_#{n()}")

      assert {:ok, updated} =
               Accounts.update_organization(org, %{name: "Renamed"}, authorize?: false)

      assert updated.name == "Renamed"
      assert updated.slug == org.slug
    end
  end

  describe "OrgSlugAudit" do
    test "sorts legacy slugs into fixable and manual" do
      i = n()
      fixable = legacy_org!("Fixme-#{i}")
      format = legacy_org!("my_site_#{i}")
      reserved = legacy_org!("Www")
      {:ok, _taken} = create("clash-#{i}")
      clash = legacy_org!("Clash-#{i}")
      twin_a = legacy_org!("Twin-#{i}")
      twin_b = legacy_org!("TWIN-#{i}")

      %{fixable: fixable_list, manual: manual} = OrgSlugAudit.report()
      by_id = Map.new(fixable_list ++ manual, &{&1.org.id, &1})

      assert %{fix: "fixme-" <> _, blocked: nil, problem: :format} = by_id[fixable.id]
      assert Enum.any?(fixable_list, &(&1.org.id == fixable.id))

      assert %{fix: nil, blocked: :format} = by_id[format.id]
      assert %{fix: nil, blocked: :reserved, problem: :format} = by_id[reserved.id]
      assert %{fix: nil, blocked: {:collision, ["clash-" <> _]}} = by_id[clash.id]
      assert %{fix: nil, blocked: {:collision, [other_a]}} = by_id[twin_a.id]
      assert other_a == twin_b.slug
      assert %{fix: nil, blocked: {:collision, [other_b]}} = by_id[twin_b.id]
      assert other_b == twin_a.slug

      for org <- [format, reserved, clash, twin_a, twin_b] do
        assert Enum.any?(manual, &(&1.org.id == org.id))
      end
    end

    test "a valid slug is not reported" do
      {:ok, org} = create("fine-#{n()}")
      %{fixable: fixable, manual: manual} = OrgSlugAudit.report()
      refute Enum.any?(fixable ++ manual, &(&1.org.id == org.id))
    end

    test "the report alone changes nothing and exits non-zero" do
      org = legacy_org!("Report-#{n()}")
      test_pid = self()

      assert {:error, message} =
               OrgSlugAudit.run_and_report([], &send(test_pid, {:line, &1}))

      assert message =~ "can't be a hostname"
      assert_received {:line, "Organizations whose slug can't be a hostname: " <> _}
      assert_received {:line, "  \"Report-" <> _}
      assert stored_slug(org.id) == org.slug
    end

    test "--fix downcases the fixable rows, logs each, and leaves the rest" do
      i = n()
      fixable = legacy_org!("Fixme-#{i}")
      format = legacy_org!("my_site_#{i}")
      {:ok, _taken} = create("clash-#{i}")
      clash = legacy_org!("Clash-#{i}")

      log =
        capture_log(fn ->
          assert {:error, _still} = OrgSlugAudit.run_and_report([fix: true], fn _ -> :ok end)
        end)

      assert stored_slug(fixable.id) == "fixme-#{i}"
      assert log =~ "downcased from #{inspect(fixable.slug)} to \"fixme-#{i}\""

      # Not a label even downcased, or would clash: the operator's call.
      assert stored_slug(format.id) == format.slug
      assert stored_slug(clash.id) == clash.slug
      refute log =~ clash.slug
    end

    test "reports nothing once every slug is a label" do
      org = legacy_org!("Only-#{n()}")
      assert {:ok, [fixed]} = OrgSlugAudit.fix()
      assert fixed.id == org.id

      assert OrgSlugAudit.warning(OrgSlugAudit.report()) == nil
      assert :ok = OrgSlugAudit.run_and_report([], fn _ -> :ok end)
    end

    test "warning/1 names the slugs and the task" do
      assert OrgSlugAudit.warning(%{fixable: [], manual: []}) == nil
      org = legacy_org!("Warn-#{n()}")

      message = OrgSlugAudit.warning(OrgSlugAudit.report())
      assert message =~ inspect(org.slug)
      assert message =~ "mix kiln.org_slugs"
    end
  end

  describe "mix kiln.org_slugs" do
    setup do
      previous = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(previous) end)
    end

    test "raises while anything is left, and --fix clears a fixable row" do
      org = legacy_org!("Task-#{n()}")

      assert_raise Mix.Error, ~r/can't be a hostname/, fn ->
        Mix.Tasks.Kiln.OrgSlugs.run([])
      end

      assert_received {:mix_shell, :info, ["  " <> line]}
      assert line =~ "with --fix"

      assert :ok = Mix.Tasks.Kiln.OrgSlugs.run(["--fix"])
      assert stored_slug(org.id) == String.downcase(org.slug)
    end
  end
end
