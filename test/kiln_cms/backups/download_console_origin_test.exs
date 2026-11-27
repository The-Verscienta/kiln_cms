defmodule KilnCMS.Backups.DownloadConsoleOriginTest do
  @moduledoc """
  A backup download is refused while the console shares an origin with more
  than one organization's sites (part of #2225, threat model residual 16):
  an org admin's injected script on a site would run same-origin with a
  platform admin's console session there. It fails closed: a node that has
  not counted the organizations yet refuses too.

  `async: false`: it writes `:console_host`, `:tenant_org_tracking` and the
  `KilnCMSWeb.Tenant.OrgCount` verdict, all VM-global, and `KilnCMS.Backups`'
  `:dir`.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMS.Security
  alias KilnCMSWeb.Tenant.OrgCount

  @stamp "20261118-031700"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_dlo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    name = "kiln-db-#{@stamp}.dump"
    File.write!(Path.join([dir, "db", name]), "dump")

    backups = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(backups, :dir, dir))
    console = Application.get_env(:kiln_cms, :console_host)
    tracking = Application.get_env(:kiln_cms, :tenant_org_tracking)
    verdict = OrgCount.verdict()
    Application.delete_env(:kiln_cms, :console_host)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, backups)
      restore(:console_host, console)
      restore(:tenant_org_tracking, tracking)
      OrgCount.put(verdict)
      File.rm_rf!(dir)
    end)

    run =
      %{stamp: @stamp, trigger: "test"}
      |> Backups.start_run!(actor: Backups.system())
      |> Backups.finish_run!(
        %{artifacts: [%{kind: :db, name: name, bytes: 4, verified: true}]},
        actor: Backups.system()
      )

    admin =
      Ash.Seed.seed!(User, %{
        email: "dlo-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    %{run: run, name: name, admin: admin}
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp second_org! do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Second",
      slug: "dlo-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp events(admin),
    do: Security.list_instance_events!(%{type: :backup_downloaded}, actor: admin)

  test "a second organization with no console host refuses both actions, recording nothing", %{
    run: run,
    name: name,
    admin: admin
  } do
    assert {:ok, _} = Backups.check_download(run.id, name, admin)
    assert Backups.download_refusal() == nil

    second_org!()

    assert Backups.download_refusal() == :console_shares_origin
    assert {:error, :console_shares_origin} = Backups.check_download(run.id, name, admin)
    assert {:error, :console_shares_origin} = Backups.download(run.id, name, admin)
    assert events(admin) == []
  end

  test "a console host of its own allows it", %{run: run, name: name, admin: admin} do
    second_org!()
    Application.put_env(:kiln_cms, :console_host, "console.example.test")

    assert Backups.download_refusal() == nil
    assert {:ok, _} = Backups.download(run.id, name, admin)
    assert [_event] = events(admin)
  end

  test "where the node keeps a verdict, only :single allows it", %{
    run: run,
    name: name,
    admin: admin
  } do
    Application.put_env(:kiln_cms, :tenant_org_tracking, true)

    for verdict <- [:unknown, :multi] do
      OrgCount.put(verdict)
      assert {:error, :console_shares_origin} = Backups.check_download(run.id, name, admin)
    end

    OrgCount.put(:single)
    assert {:ok, _} = Backups.check_download(run.id, name, admin)
  end
end
