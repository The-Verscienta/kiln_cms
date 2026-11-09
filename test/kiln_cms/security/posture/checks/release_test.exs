defmodule KilnCMS.Security.Posture.Checks.ReleaseTest do
  @moduledoc """
  `core.release` (#2252), answered from `Kiln.Updates`' cache only. A cold
  cache starts one background check (stubbed with `Req.Test`, so nothing
  leaves the machine) and answers unknown at once.

  `async: false`: the cache is `:persistent_term` and the switch application
  env, both node-wide.
  """
  use ExUnit.Case, async: false

  # The background check's failed answer is logged at debug; keep it quiet.
  @moduletag :capture_log

  import KilnCMS.PostureFixtures, only: [context: 1]
  import KilnCMS.Test.Eventually, only: [eventually: 1]

  alias KilnCMS.Security.Posture.Checks.Release

  setup do
    original = Application.get_env(:kiln_cms, Kiln.Updates, [])
    Kiln.Updates.clear_cache()

    on_exit(fn ->
      Application.put_env(:kiln_cms, Kiln.Updates, original)
      Kiln.Updates.clear_cache()
    end)

    %{original: original}
  end

  defp run, do: Release.run(context(nil))

  test "current passes" do
    Kiln.Updates.put_cache({:ok, :current})
    assert %{status: :pass, facts: %{behind: false}} = run()
  end

  test "behind any release warns, naming it" do
    Kiln.Updates.put_cache(
      {:ok,
       {:behind,
        %{
          version: Version.parse!("99.0.0"),
          tag: "v99.0.0",
          url: "https://github.com/The-Verscienta/kiln_cms/releases/tag/v99.0.0",
          published_at: nil,
          highlights: []
        }}}
    )

    result = run()
    assert result.status == :warn
    assert result.summary =~ "99.0.0"
    assert result.facts == %{behind: true, latest: "99.0.0"}
    assert result.fix_path == "/editor/system"
  end

  test "a failed check is unknown, never a pass" do
    Kiln.Updates.put_cache({:error, {:http_status, 403}})
    assert %{status: :unknown} = run()
  end

  test "a cold cache answers unknown at once and warms the cache in the background" do
    test = self()

    Req.Test.stub(Kiln.Updates, fn conn ->
      send(test, :update_request)
      Plug.Conn.send_resp(conn, 503, "")
    end)

    result = run()
    assert result.status == :unknown
    assert result.summary =~ "reopen this page in a minute"
    assert result.facts == %{pending: true}

    # The background check made the request and cached its (failed) answer.
    assert_receive :update_request, 2000
    eventually(fn -> Kiln.Updates.cached() != nil end)
    assert %{status: :unknown, facts: facts} = run()
    refute Map.has_key?(facts, :pending)
  end

  test "a warm cache makes no request" do
    Req.Test.stub(Kiln.Updates, fn conn ->
      flunk("an update request was made: #{conn.request_path}")
    end)

    Kiln.Updates.put_cache({:ok, :current})
    assert %{status: :pass} = run()
    assert Kiln.Updates.warm() == :cached
  end

  test "a check already in flight is not started again" do
    # Stand in for a running warmer by holding its name.
    holder = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(holder, Kiln.Updates.warmer_name())
    on_exit(fn -> Process.exit(holder, :kill) end)

    Req.Test.stub(Kiln.Updates, fn conn -> flunk("second request: #{conn.request_path}") end)

    assert %{status: :unknown, facts: %{pending: true}} = run()
    assert Kiln.Updates.warm() == :in_flight
  end

  test "checks turned off are not applicable", %{original: original} do
    Application.put_env(:kiln_cms, Kiln.Updates, Keyword.put(original, :enabled, false))
    assert %{status: :n_a} = run()
  end
end
