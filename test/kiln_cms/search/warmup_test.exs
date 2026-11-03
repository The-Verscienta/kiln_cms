defmodule KilnCMS.Search.WarmupTest do
  @moduledoc """
  The boot latch that keeps a node out of rotation until search is warm
  (#2166). What reads it — `/live`, `/up`, `/ready` — is covered in
  `KilnCMSWeb.HealthWarmupTest`.
  """
  # async: false — the latch is node-global, and the search env is too.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Search.Warmup

  defmodule CountingEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      if pid = Application.get_env(:kiln_cms, :warmup_test_pid), do: send(pid, {:embedded, text})
      Process.sleep(Application.get_env(:kiln_cms, :warmup_test_delay, 0))
      {:ok, List.duplicate(0.1, 384)}
    end
  end

  defp put_env(module, overrides) do
    base = Application.get_env(:kiln_cms, module, [])
    Application.put_env(:kiln_cms, module, Keyword.merge(base, overrides))
  end

  setup do
    search = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    warmup = Application.get_env(:kiln_cms, Warmup, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Search, search)
      Application.put_env(:kiln_cms, Warmup, warmup)
      Application.delete_env(:kiln_cms, :warmup_test_pid)
      Application.delete_env(:kiln_cms, :warmup_test_delay)
      Warmup.put_ready(true)
    end)

    Warmup.put_ready(false)
    Application.put_env(:kiln_cms, :warmup_test_pid, self())
    :ok
  end

  test "with nothing to warm, the latch opens as the child starts" do
    put_env(KilnCMS.Search, semantic: false, rerank: false)

    assert Warmup.init([]) == :ignore
    assert Warmup.ready?()
  end

  test "with semantic search on, it opens only after a search has run" do
    put_env(KilnCMS.Search, semantic: true, embedder: CountingEmbedder)
    Application.put_env(:kiln_cms, :warmup_test_delay, 200)

    capture_log(fn ->
      pid = start_supervised!(Warmup)
      ref = Process.monitor(pid)

      assert_receive {:embedded, "warm up"}, 1_000
      refute Warmup.ready?()

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end)

    assert Warmup.ready?()
  end

  test "a warm-up that outlasts its timeout opens the latch anyway" do
    put_env(KilnCMS.Search, semantic: true, embedder: CountingEmbedder)
    put_env(Warmup, timeout: 100)
    Application.put_env(:kiln_cms, :warmup_test_delay, 5_000)

    log =
      capture_log(fn ->
        pid = start_supervised!(Warmup)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      end)

    assert Warmup.ready?()
    assert log =~ "search warm-up passed 100 ms, serving anyway"
  end

  test "a warm-up that fails opens the latch anyway" do
    put_env(KilnCMS.Search, semantic: true, embedder: KilnCMS.Search.Embedder.Bumblebee)

    log =
      capture_log(fn ->
        pid = start_supervised!(Warmup)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      end)

    assert Warmup.ready?()
    # No serving runs in the test env, in either build: the lean one has no
    # ML stack, and the ML one starts no serving with semantic off at boot.
    assert log =~ "search warm-up failed, serving anyway"
  end
end
