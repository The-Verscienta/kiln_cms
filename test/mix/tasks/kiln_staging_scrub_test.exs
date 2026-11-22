defmodule Mix.Tasks.Kiln.Staging.ScrubTest do
  @moduledoc """
  `mix kiln.staging.scrub` refuses when `DATABASE_URL` names a server or database other
  than the one the repo is configured for (#2977): only the prod config reads
  the variable, so under `MIX_ENV=dev` the task would scrub the dev database
  instead of the clone.

  `async: false`: one test sets `DATABASE_URL`, which is VM-global.
  """
  use KilnCMS.DataCase, async: false

  alias Mix.Tasks.Kiln.Staging.Scrub, as: Task

  # The shape config/dev.exs has.
  @dev [hostname: "localhost", database: "kiln_cms_dev"]

  describe "check_database_url!/2" do
    test "passes with no DATABASE_URL: the configured database is the target" do
      assert Task.check_database_url!(nil, @dev) == :ok
      assert Task.check_database_url!("", @dev) == :ok
    end

    test "passes when DATABASE_URL names the configured server and database" do
      assert Task.check_database_url!(
               "ecto://stage:pw@stage-db:5432/kiln_staging?ssl=false",
               url: "ecto://stage:pw@stage-db/kiln_staging"
             ) == :ok

      # localhost, 127.0.0.1 and ::1 are one server.
      for host <- ["localhost", "127.0.0.1", "[::1]"] do
        assert Task.check_database_url!("postgres://dev@#{host}/kiln_cms_dev", @dev) == :ok
      end
    end

    test "refuses when DATABASE_URL names another database" do
      error =
        assert_raise Mix.Error, fn ->
          Task.check_database_url!("postgres://stage:stage-pw@localhost/kiln_staging", @dev)
        end

      assert error.message =~ "DATABASE_URL names kiln_staging@localhost:5432"
      assert error.message =~ "configured for kiln_cms_dev@localhost:5432"
      assert error.message =~ "MIX_ENV=prod"
      refute error.message =~ "stage-pw"
    end

    test "refuses when DATABASE_URL names the same database on another server" do
      error =
        assert_raise Mix.Error, fn ->
          Task.check_database_url!("postgres://dev:dev-pw@db.example/kiln_cms_dev", @dev)
        end

      assert error.message =~ "DATABASE_URL names kiln_cms_dev@db.example:5432"
      refute error.message =~ "dev-pw"

      assert_raise Mix.Error, fn ->
        Task.check_database_url!("postgres://dev@localhost:5433/kiln_cms_dev", @dev)
      end
    end
  end

  test "run/1 refuses before it changes anything" do
    user =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "task-scrub-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    previous = System.get_env("DATABASE_URL")
    System.put_env("DATABASE_URL", "postgres://stage@stage-db/kiln_staging_elsewhere")

    on_exit(fn ->
      if previous,
        do: System.put_env("DATABASE_URL", previous),
        else: System.delete_env("DATABASE_URL")
    end)

    assert_raise Mix.Error, ~r/Refusing to scrub: DATABASE_URL names/, fn ->
      Task.run(["--yes", "--force"])
    end

    assert %{anonymized_at: nil} = KilnCMS.Accounts.get_user!(user.id, authorize?: false)
  end
end
