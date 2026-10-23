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
  alias KilnCMS.Search.VectorScan

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
    assert read(%{"KILN_HNSW_EF_SEARCH" => " 200 "}) == [ef_search: 200, exact: false]
    System.delete_env("KILN_HNSW_EF_SEARCH")
    assert read(%{"KILN_VECTOR_SEARCH_EXACT" => "TRUE"}) == [ef_search: nil, exact: true]
    # exact=false beside an ef_search is not "both".
    assert read(%{"KILN_VECTOR_SEARCH_EXACT" => "off", "KILN_HNSW_EF_SEARCH" => "1000"}) ==
             [ef_search: 1000, exact: false]
  end

  # #2019: runtime config is deep-merged over compiled config key by key, so an
  # env value that wrote only its own key merged with a compiled `vector_scan:`
  # of the other mode into both keys, and every boot raised.
  test "the env var's mode replaces a compiled vector_scan of the other mode" do
    merged = fn compiled, env ->
      runtime = [kiln_cms: [{KilnCMS.Repo, [vector_scan: read(env)]}]]

      [kiln_cms: [{KilnCMS.Repo, [vector_scan: compiled]}]]
      |> Config.Reader.merge(runtime)
      |> get_in([:kiln_cms, KilnCMS.Repo, :vector_scan])
      |> VectorScan.normalize!()
    end

    assert merged.([ef_search: 150], %{"KILN_VECTOR_SEARCH_EXACT" => "true"}) == :exact
    System.delete_env("KILN_VECTOR_SEARCH_EXACT")
    assert merged.([exact: true], %{"KILN_HNSW_EF_SEARCH" => "200"}) == {:ef_search, 200}
    assert merged.([ef_search: 150], %{"KILN_HNSW_EF_SEARCH" => "200"}) == {:ef_search, 200}
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
