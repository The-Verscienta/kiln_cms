defmodule KilnCMS.Demo.GuardTest do
  @moduledoc """
  The refusals between a demo reset and a database it must never touch
  (`docs/demo-mode.md`). Each is independent — the accident they prevent is one
  setting being wrong while the others look right — so each is exercised alone,
  against an otherwise-valid target.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Demo.Guard

  @demo %{
    enabled?: true,
    repo_host: "db.internal",
    repo_database: "kiln_demo",
    url: "postgres://kiln:secret@db.internal:5432/kiln_demo?sslmode=require",
    site_host: "demo.kilncms.dev"
  }

  test "a demo database, served at a demo host, through a matching URL, may be reset" do
    assert Guard.check(@demo) == :ok
  end

  describe "enabled with the sentinel" do
    test "off refuses" do
      assert Guard.check(%{@demo | enabled?: false}) == {:error, :disabled}
    end

    test "only the boolean `true` counts — a truthy string does not" do
      assert Guard.check(%{@demo | enabled?: "true"}) == {:error, :disabled}
    end

    test "is reported before any other refusal" do
      production = %{
        @demo
        | enabled?: false,
          repo_database: "kiln_prod",
          site_host: "kilncms.dev"
      }

      assert Guard.check(production) == {:error, :disabled}
    end
  end

  describe "the database is named like a demo" do
    test "a production-looking name refuses" do
      target = %{
        @demo
        | repo_database: "kiln_cms_prod",
          url: "postgres://kiln:secret@db.internal:5432/kiln_cms_prod"
      }

      assert Guard.check(target) == {:error, {:database_not_demo, "kiln_cms_prod"}}
    end

    test "matching is case-insensitive" do
      target = %{
        @demo
        | repo_database: "KILN_DEMO",
          url: "postgres://kiln:secret@db.internal:5432/KILN_DEMO"
      }

      assert Guard.check(target) == :ok
    end
  end

  describe "the site is served like a demo" do
    test "the production host refuses" do
      assert Guard.check(%{@demo | site_host: "kilncms.dev"}) ==
               {:error, {:host_not_demo, "kilncms.dev"}}
    end

    test "an unknown host refuses" do
      assert Guard.check(%{@demo | site_host: nil}) == {:error, {:host_not_demo, nil}}
    end

    test "localhost is allowed, for trying it on a laptop" do
      assert Guard.check(%{@demo | site_host: "localhost"}) == :ok
    end

    test "PHX_HOST's production fallback is not" do
      assert Guard.check(%{@demo | site_host: "example.com"}) ==
               {:error, {:host_not_demo, "example.com"}}
    end
  end

  describe "the tools connect where the application does" do
    test "no URL refuses" do
      assert Guard.check(%{@demo | url: nil}) == {:error, :no_database_url}
    end

    test "a URL naming another database refuses — BACKUP_DATABASE_URL can point anywhere" do
      target = %{@demo | url: "postgres://kiln:secret@db.internal:5432/kiln_prod"}

      assert Guard.check(target) ==
               {:error,
                {:url_mismatch, {"db.internal", "kiln_prod"}, {"db.internal", "kiln_demo"}}}
    end

    test "a URL naming another server refuses, even with the same database name" do
      target = %{@demo | url: "postgres://kiln:secret@prod-db.internal:5432/kiln_demo"}

      assert Guard.check(target) ==
               {:error,
                {:url_mismatch, {"prod-db.internal", "kiln_demo"}, {"db.internal", "kiln_demo"}}}
    end
  end

  describe "check_golden_source/1" do
    test "a snapshot of a demo database may be restored" do
      assert Guard.check_golden_source("kiln_demo") == :ok
    end

    test "a production backup may not — it would publish production's accounts" do
      assert Guard.check_golden_source("kiln_prod") == {:error, {:golden_not_demo, "kiln_prod"}}
    end

    test "an archive that names no source may not" do
      assert Guard.check_golden_source(nil) == {:error, {:golden_not_demo, nil}}
    end
  end
end
