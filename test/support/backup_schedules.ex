defmodule KilnCMS.Test.BackupSchedules do
  @moduledoc """
  Fixtures for the in-app backup schedules (#2219, part 2): people of each
  role, and a schedule created through the code interface as a platform admin,
  so every fixture runs the resource's own changes and validations.
  """
  alias KilnCMS.Accounts.{OrgMembership, User}
  alias KilnCMS.Backups

  @doc "A confirmed user with the platform role `role`."
  @spec user(atom()) :: User.t()
  def user(role) do
    Ash.Seed.seed!(User, %{
      email: "sched-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  @doc "An admin of the default org who is not a platform admin."
  @spec site_admin() :: User.t()
  def site_admin do
    editor = user(:editor)

    Ash.Seed.seed!(OrgMembership, %{
      organization_id: KilnCMS.Accounts.default_org_id(),
      user_id: editor.id,
      role: :admin
    })

    editor
  end

  @doc "A platform admin."
  @spec platform_admin() :: User.t()
  def platform_admin, do: user(:admin)

  @doc """
  A daily database schedule at 03:00 UTC starting 2026-01-01, with `attrs`
  merged in, created as `actor` (a fresh platform admin by default).
  """
  @spec schedule!(map(), term()) :: KilnCMS.Backups.Schedule.t()
  def schedule!(attrs \\ %{}, actor \\ nil) do
    attrs =
      Map.merge(
        %{
          components: [:db],
          interval: :daily,
          time_of_day: ~T[03:00:00],
          starts_on: ~D[2026-01-01],
          time_zone: "Etc/UTC"
        },
        attrs
      )

    Backups.create_backup_schedule!(attrs, actor: actor || platform_admin())
  end

  @doc """
  Runs `fun` with `PATH` pointing at an empty directory, so this node finds no
  `pg_dump` (`Backups.availability/0` is `{:error, :no_pg_dump}`), and puts
  `PATH` back after. `PATH` is VM-wide: only for `async: false` modules.
  """
  @spec without_pg_tools((-> result)) :: result when result: term()
  def without_pg_tools(fun) do
    path = System.get_env("PATH")
    empty = Path.join(System.tmp_dir!(), "kiln_nopg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    System.put_env("PATH", empty)

    try do
      fun.()
    after
      System.put_env("PATH", path)
      File.rm_rf!(empty)
    end
  end

  @doc """
  Set columns no action accepts (`baseline_at`, `last_window_at`, the keep
  values), straight in the table: the way a test reaches a state that only
  time, the scheduler or a later release produces.
  """
  @spec force!(KilnCMS.Backups.Schedule.t(), keyword()) :: KilnCMS.Backups.Schedule.t()
  def force!(schedule, fields) do
    import Ecto.Query

    {:ok, id} = Ecto.UUID.dump(schedule.id)

    {1, _} =
      KilnCMS.Repo.update_all(from(s in "backup_schedules", where: s.id == ^id), set: fields)

    Backups.get_backup_schedule!(schedule.id, actor: Backups.system())
  end
end
