defmodule KilnCMS.Security.Posture.Checks.ExposedEndpointsTest do
  @moduledoc """
  `core.exposed_endpoints` (#2252): a closed baseline passes, and each
  endpoint opened turns it.

  `async: false`: every input is application env, which is node-wide.
  """
  use ExUnit.Case, async: false

  import KilnCMS.PostureFixtures, only: [context: 1]

  alias KilnCMS.Security.Posture.Checks.ExposedEndpoints

  setup do
    saved =
      for key <- [:api_docs, :graphql_introspection, KilnCMSWeb.Metrics],
          do: {key, Application.fetch_env(:kiln_cms, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:kiln_cms, key, v)
          :error -> Application.delete_env(:kiln_cms, key)
        end
      end
    end)

    Application.put_env(:kiln_cms, :api_docs, false)
    Application.put_env(:kiln_cms, :graphql_introspection, false)
    Application.put_env(:kiln_cms, KilnCMSWeb.Metrics, enabled: false)
    :ok
  end

  defp run, do: ExposedEndpoints.run(context(nil))

  test "passes with every endpoint closed" do
    assert %{status: :pass, details: []} = run()
  end

  test "the API explorer warns" do
    Application.put_env(:kiln_cms, :api_docs, true)
    assert %{status: :warn, facts: %{api_docs: true}} = run()
  end

  test "GraphQL introspection warns" do
    Application.put_env(:kiln_cms, :graphql_introspection, true)
    assert %{status: :warn, facts: %{graphql_introspection: true}} = run()
  end

  test "metrics on every interface with no token fails; an empty token is none" do
    Application.put_env(:kiln_cms, KilnCMSWeb.Metrics, enabled: true, bind: :all)
    assert %{status: :fail, facts: %{metrics_public: true}} = run()

    Application.put_env(:kiln_cms, KilnCMSWeb.Metrics, enabled: true, bind: :all, token: "")
    assert %{status: :fail} = run()
  end

  test "metrics with a token, or on loopback, pass" do
    Application.put_env(:kiln_cms, KilnCMSWeb.Metrics, enabled: true, bind: :all, token: "t0k")
    assert %{status: :pass} = run()

    Application.put_env(:kiln_cms, KilnCMSWeb.Metrics, enabled: true, bind: :loopback)
    assert %{status: :pass} = run()
  end
end
