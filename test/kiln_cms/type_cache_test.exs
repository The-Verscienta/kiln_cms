defmodule KilnCMS.TypeCacheTest do
  @moduledoc """
  Every type the migrations created is already in Postgrex's type cache, with
  its codec resolved, when tests run (#1796). See `KilnCMS.Test.TypeCache`.

  On an already-migrated database this passes without the warm-up, because
  the bootstrap saw every type. It is the fresh database CI starts each shard
  with that needs it: there, without `TypeCache.warm!/1` in `test_helper.exs`,
  `citext`, `vector` and friends are missing here.

  It reads Postgrex internals (the `Postgrex.TypeManager` registry and the
  type server's ETS table). If a Postgrex upgrade moves them, this fails on
  the lookup, which is the moment to recheck whether the race still exists.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Repo
  alias KilnCMS.Test.TypeCache

  test "no migration-created type is left to load lazily mid-run" do
    %{rows: rows} = Repo.query!(TypeCache.types_sql())
    assert rows != [], "expected the migrations to have created at least citext and vector"

    table = type_table!()

    unresolved =
      for [oid, name] <- rows,
          resolved?(table, oid) == false,
          do: name

    assert unresolved == [],
           "types not resolved in Postgrex's cache before the first test: " <>
             Enum.join(unresolved, ", ")
  end

  defp resolved?(table, oid) do
    case :ets.lookup(table, oid) do
      [{^oid, _info, {_format, _codec}}] -> true
      _ -> false
    end
  end

  defp type_table! do
    database = Repo.config()[:database]

    servers =
      for {{KilnCMS.PostgrexTypes, {_host, _port, ^database}}, pid} <-
            Registry.select(Postgrex.TypeManager, [
              {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
            ]),
          do: pid

    assert [server] = servers, "no Postgrex type server for #{database}"

    assert [table] = for(t <- :ets.all(), :ets.info(t, :owner) == server, do: t),
           "the type server owns no ETS table"

    table
  end
end
