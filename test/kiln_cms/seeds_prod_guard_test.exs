defmodule KilnCMS.SeedsProdGuardTest do
  @moduledoc """
  `priv/repo/seeds.exs` refuses a production database (#1651).

  `mix ecto.setup` against a production `DATABASE_URL` used to create
  `admin@kiln.test` with the password the README publishes. The script now
  refuses `:prod` unless the operator opts in with `ALLOW_PROD_SEEDS=confirm`
  *and* overrides both demo passwords.

  The file is evaluated for real, with `Mix.env/0` flipped to `:prod`: both
  guards sit above the first database call, so a refusal here touches nothing,
  and a guard that moved below one would fail this test with a database error
  rather than pass it.
  """
  # async: false — `Mix.env/1` and `System.put_env/2` are VM-global.
  use ExUnit.Case, async: false

  @seeds Path.expand("../../priv/repo/seeds.exs", __DIR__)
  @env_vars ~w(ALLOW_PROD_SEEDS ADMIN_PASSWORD EDITOR_PASSWORD)

  setup do
    previous_env = Mix.env()
    previous_vars = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)

    Mix.env(:prod)

    on_exit(fn ->
      Mix.env(previous_env)

      Enum.each(previous_vars, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "refuses :prod without ALLOW_PROD_SEEDS=confirm" do
    assert_raise Mix.Error, ~r/Refusing to seed in :prod/, fn -> Code.eval_file(@seeds) end
  end

  test "an opt-in other than the exact word is not an opt-in" do
    System.put_env("ALLOW_PROD_SEEDS", "1")

    assert_raise Mix.Error, ~r/Refusing to seed in :prod/, fn -> Code.eval_file(@seeds) end
  end

  test "opting in still refuses the published demo passwords" do
    System.put_env("ALLOW_PROD_SEEDS", "confirm")

    assert_raise Mix.Error, ~r/published demo passwords/, fn -> Code.eval_file(@seeds) end
  end

  test "overriding one demo password is not enough" do
    System.put_env("ALLOW_PROD_SEEDS", "confirm")
    System.put_env("ADMIN_PASSWORD", "a-real-operator-password")

    assert_raise Mix.Error, ~r/published demo passwords/, fn -> Code.eval_file(@seeds) end
  end
end
