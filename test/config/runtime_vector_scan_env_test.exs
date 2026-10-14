defmodule KilnCMS.Config.RuntimeVectorScanEnvTest do
  @moduledoc """
  `KILN_HNSW_EF_SEARCH` and `KILN_VECTOR_SEARCH_EXACT`, read by
  `config/runtime/search.exs`: unset writes nothing (the default repo config is
  untouched), a usable value writes `vector_scan:`, and anything unusable —
  including both at once — refuses to boot. The last is the deliberate
  exception to the keep-the-default-and-warn rule every other variable follows;
  see the fragment's comment.
  """
  # Process environment is VM-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Config.Env

  @fragment Path.expand("../../config/runtime/search.exs", __DIR__)
  @vars ~w(KILN_HNSW_EF_SEARCH KILN_VECTOR_SEARCH_EXACT)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    # The Env readers collect into the process dictionary; drain what a case
    # left so it cannot leak into the next one.
    on_exit(fn -> Env.take_collected() end)
    :ok
  end

  defp read(env) do
    Enum.each(env, fn {var, value} -> System.put_env(var, value) end)

    @fragment
    |> Config.Reader.read!(env: :test)
    |> get_in([:kiln_cms, KilnCMS.Repo, :vector_scan])
  end

  defp refuses(env, pattern) do
    stderr =
      capture_io(:stderr, fn ->
        assert_raise RuntimeError, pattern, fn -> read(env) end
      end)

    Env.take_collected()
    stderr
  end

  test "unset, blank, or exact=false writes nothing" do
    assert read(%{}) == nil
    assert read(%{"KILN_HNSW_EF_SEARCH" => "", "KILN_VECTOR_SEARCH_EXACT" => " "}) == nil
    assert read(%{"KILN_VECTOR_SEARCH_EXACT" => "false"}) == nil
  end

  test "a usable value writes vector_scan" do
    assert read(%{"KILN_HNSW_EF_SEARCH" => " 200 "}) == [ef_search: 200]
    System.delete_env("KILN_HNSW_EF_SEARCH")
    assert read(%{"KILN_VECTOR_SEARCH_EXACT" => "TRUE"}) == [exact: true]
    # exact=false beside an ef_search is not "both".
    assert read(%{"KILN_VECTOR_SEARCH_EXACT" => "off", "KILN_HNSW_EF_SEARCH" => "1000"}) ==
             [ef_search: 1000]
  end

  test "an unusable ef_search refuses to boot" do
    for bad <- ~w(abc 0 -5 200ms) do
      stderr = refuses(%{"KILN_HNSW_EF_SEARCH" => bad}, ~r/KILN_HNSW_EF_SEARCH must be/)
      # The Env reader names the value it could not read before the raise.
      assert stderr =~ "KILN_HNSW_EF_SEARCH is set to"
    end

    # Parses as a count, so it is the range check that refuses it.
    System.put_env("KILN_HNSW_EF_SEARCH", "1001")

    assert_raise ArgumentError, ~r/must be an integer in 1\.\.1000/, fn ->
      read(%{})
    end
  end

  test "an unusable exact refuses to boot" do
    refuses(%{"KILN_VECTOR_SEARCH_EXACT" => "maybe"}, ~r/KILN_VECTOR_SEARCH_EXACT must be/)
  end

  test "both at once refuses to boot" do
    assert_raise ArgumentError, ~r/sets both ef_search and exact/, fn ->
      read(%{"KILN_HNSW_EF_SEARCH" => "200", "KILN_VECTOR_SEARCH_EXACT" => "true"})
    end
  end
end
