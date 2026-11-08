defmodule KilnCMS.CMS.UniqueValuesConcurrencyTest do
  @moduledoc """
  The `unique` field constraint under real concurrency (#2276).

  The sandbox cannot show this: its tests share one connection (or sit in an
  uncommitted transaction), so an advisory lock never blocks anyone and a
  loser never sees the winner's commit. This module therefore runs with the
  sandbox in `:auto` mode — every writer gets its own connection and COMMITS —
  and deletes what it made afterwards. Not async, and not a `DataCase`, for
  that reason: nothing else may be reading or writing the sandbox pool while it
  is in `:auto` mode, and `async: false` modules run one at a time.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.CMS
  alias KilnCMS.Repo

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    started = DateTime.utc_now()

    org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "Concurrent",
        slug: "uvc-#{System.unique_integer([:positive])}",
        status: :active
      })

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "uvc-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "sku",
        label: "SKU",
        field_type: :string,
        validation: %{"unique" => true}
      },
      actor: admin,
      tenant: org
    )

    on_exit(fn -> cleanup(org, admin, started) end)

    %{org: org, admin: admin}
  end

  defp slug, do: "uvc-#{System.unique_integer([:positive])}"

  defp input(sku), do: %{title: "P", slug: slug(), custom_fields: %{"sku" => sku}}

  defp count(org, sku) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM posts WHERE org_id = $1 AND custom_fields ->> 'sku' = $2",
        [Ecto.UUID.dump!(org.id), sku]
      )

    n
  end

  # Everything this test committed, child rows first. `org_id` tables are
  # found from the catalog rather than listed; a pass that trips a foreign key
  # leaves that table for the next one.
  defp cleanup(org, admin, started) do
    id = Ecto.UUID.dump!(org.id)

    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND column_name = 'org_id' AND table_name <> 'organizations'"
      )

    Repo.query!("DELETE FROM oban_jobs WHERE inserted_at >= $1", [started])

    _ =
      Enum.reduce_while(1..5, Enum.map(tables, &hd/1), fn _pass, pending ->
        left =
          Enum.filter(pending, fn table ->
            try do
              Repo.query!("DELETE FROM #{table} WHERE org_id = $1", [id])
              false
            rescue
              Postgrex.Error -> true
            end
          end)

        if left == [], do: {:halt, []}, else: {:cont, left}
      end)

    Repo.query!(
      "DELETE FROM posts_versions WHERE version_source_id NOT IN (SELECT id FROM posts)"
    )

    Repo.query!("DELETE FROM organizations WHERE id = $1", [id])
    Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(admin.id)])
  end

  test "of many simultaneous writers of one value, exactly one wins and none crash", %{
    org: org,
    admin: admin
  } do
    results =
      1..8
      |> Task.async_stream(
        fn _ -> CMS.create_post(input("RACE-1"), actor: admin, tenant: org) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    for {:error, error} <- results do
      assert %Ash.Error.Invalid{} = error
      assert Exception.message(error) =~ "SKU (sku) is already in use"
    end

    assert count(org, "RACE-1") == 1
  end

  test "different values do not wait on each other", %{org: org, admin: admin} do
    results =
      1..6
      |> Task.async_stream(
        fn n -> CMS.create_post(input("FREE-#{n}"), actor: admin, tenant: org) end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
  end

  test "batches that overlap in opposite order settle without a crash", %{
    org: org,
    admin: admin
  } do
    bulk = fn skus ->
      CMS.create_post(Enum.map(skus, &input/1),
        actor: admin,
        tenant: org,
        bulk_options: [return_errors?: true, return_records?: true, stop_on_error?: true]
      )
    end

    for round <- 1..6 do
      a = "OPP-#{round}-A"
      b = "OPP-#{round}-B"

      results =
        [[a, b], [b, a]]
        |> Task.async_stream(bulk, max_concurrency: 2, timeout: 30_000)
        |> Enum.map(fn {:ok, result} -> result end)

      # One batch wins whole; the other fails whole, as a validation error
      # (a taken value, or a deadlock victim told to retry) — never a crash.
      assert Enum.count(results, &(&1.status == :success)) == 1

      for %{status: :error} = result <- results do
        assert [%Ash.Error.Invalid{} | _] =
                 result.errors |> List.wrap() |> Enum.map(&Ash.Error.to_ash_error/1)
      end

      assert count(org, a) == 1
      assert count(org, b) == 1
    end
  end
end
