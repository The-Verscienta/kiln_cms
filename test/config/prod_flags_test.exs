defmodule KilnCMS.Config.ProdFlagsTest do
  @moduledoc """
  Pins the surfaces `config/prod.exs` switches off explicitly rather than
  leaving unset (#1660).

  Each of these reads as off when unset too, so a missing line changes nothing
  today — which is exactly why it could be dropped unnoticed. Setting them in
  `prod.exs` means enabling one takes a deliberate config change. This reads
  the real prod config, so the test is of the file, not of a copy of it.
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok,
     config: "config/prod.exs" |> Config.Reader.read!(env: :prod) |> Keyword.fetch!(:kiln_cms)}
  end

  test "the CRDT co-editing prototype is pinned off (#1660)", %{config: config} do
    assert Keyword.fetch!(config, :collab_prototype) == false
  end

  test "API docs and GraphQL introspection stay pinned off", %{config: config} do
    assert Keyword.fetch!(config, :api_docs) == false
    assert Keyword.fetch!(config, :graphql_introspection) == false
  end

  test "dev tooling routes and the mailbox preview stay pinned off", %{config: config} do
    assert Keyword.fetch!(config, :dev_routes) == false
    assert Keyword.fetch!(config, :mailbox_preview) == false
  end
end
