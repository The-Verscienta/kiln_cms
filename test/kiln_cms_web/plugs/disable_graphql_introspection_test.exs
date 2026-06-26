defmodule KilnCMSWeb.Plugs.DisableGraphqlIntrospectionTest do
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMSWeb.Plugs.DisableGraphqlIntrospection

  test "passes through when introspection enabled (default)" do
    conn =
      build_conn(:post, "/", %{"query" => "{ __schema { types { name } } }"})
      |> DisableGraphqlIntrospection.call([])

    refute conn.halted
  end

  test "blocks __schema when disabled via config" do
    Application.put_env(:kiln_cms, :graphql_introspection, false)

    conn =
      build_conn(:post, "/", %{"query" => "{ __schema { types { name } } }"})
      |> DisableGraphqlIntrospection.call([])

    assert conn.halted
    assert conn.status == 403
  after
    Application.put_env(:kiln_cms, :graphql_introspection, true)
  end

  test "allows __typename even when disabled" do
    Application.put_env(:kiln_cms, :graphql_introspection, false)

    conn =
      build_conn(:post, "/", %{"query" => "{ viewer { __typename } }"})
      |> DisableGraphqlIntrospection.call([])

    refute conn.halted
  after
    Application.put_env(:kiln_cms, :graphql_introspection, true)
  end
end
