defmodule KilnCMSWeb.CustomFieldAliasesTest do
  @moduledoc """
  The pure half of `KilnCMSWeb.CustomFieldAliases` (#2292): which
  `filter[...]` / `sort` names move to `custom_filter` / `custom_sort`.
  Request-level behaviour is in `KilnCMSWeb.JsonApiTest`.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.CustomFieldAliases, as: Aliases

  defp route(resource, action, type \\ :index) do
    resource
    |> AshJsonApi.Resource.Info.routes([KilnCMS.CMS])
    |> Enum.find(&(&1.action == action and &1.type == type)) ||
      flunk("no #{type} route for #{inspect(action)}")
  end

  defp rewrite(params, action \\ :read) do
    Aliases.rewrite(params, KilnCMS.CMS.Post, route(KilnCMS.CMS.Post, action))
  end

  describe "filter" do
    test "an unknown head moves, bare or with operators" do
      assert %{"custom_filter" => %{"price" => "10"}} =
               out = rewrite(%{"filter" => %{"price" => "10"}})

      refute Map.has_key?(out, "filter")

      assert %{"custom_filter" => %{"price" => %{"gt" => "10"}}} =
               rewrite(%{"filter" => %{"price" => %{"gt" => "10"}}})
    end

    test "operator shapes ride along untouched" do
      params = %{
        "filter" => %{"p" => %{"in" => ["1", "2"], "null" => "false", "is_nil" => "true"}}
      }

      assert %{"custom_filter" => %{"p" => %{"in" => ["1", "2"]}}} = rewrite(params)
    end

    test "x.link.y heads move whole" do
      assert %{"custom_filter" => %{"refs.link.role" => %{"eq" => "a"}}} =
               rewrite(%{"filter" => %{"refs.link.role" => %{"eq" => "a"}}})
    end

    test "a built-in name keeps its meaning" do
      params = %{"filter" => %{"title" => "x", "slug" => "y", "state" => "published"}}
      assert rewrite(params) == params
    end

    test "a built-in relation keeps field filters but its set operators move" do
      assert rewrite(%{"filter" => %{"category" => %{"slug" => "a"}, "tags" => %{"slug" => "t"}}}) ==
               %{"filter" => %{"category" => %{"slug" => "a"}, "tags" => %{"slug" => "t"}}}

      assert %{"custom_filter" => %{"tags" => %{"has" => ["1"]}}} =
               out = rewrite(%{"filter" => %{"tags" => %{"has" => ["1"]}}})

      refute Map.has_key?(out, "filter")

      out = rewrite(%{"filter" => %{"tags" => %{"has" => "1", "slug" => "t"}}})
      assert out["custom_filter"] == %{"tags" => %{"has" => "1"}}
      assert out["filter"] == %{"tags" => %{"slug" => "t"}}
    end

    test "and / or / not are left alone" do
      params = %{"filter" => %{"or" => [%{"title" => "a"}], "not" => %{"title" => "b"}}}
      assert rewrite(params) == params
    end

    test "both forms present: built-in applies both, custom merges, clash stays native" do
      both = %{"filter" => %{"title" => "a"}, "custom_filter" => %{"title" => "b"}}
      assert rewrite(both) == both

      merged =
        rewrite(%{
          "filter" => %{"p" => %{"gt" => "1"}},
          "custom_filter" => %{"p" => %{"lt" => "9"}}
        })

      assert merged["custom_filter"] == %{"p" => %{"gt" => "1", "lt" => "9"}}

      clash = %{"filter" => %{"p" => %{"gt" => "1"}}, "custom_filter" => %{"p" => %{"gt" => "2"}}}
      assert rewrite(clash) == clash

      bare_clash = %{"filter" => %{"p" => "1"}, "custom_filter" => %{"p" => "2"}}
      assert rewrite(bare_clash) == bare_clash
    end

    test "a non-map filter is untouched; a string filter is decoded first" do
      assert rewrite(%{"filter" => ["x"]}) == %{"filter" => ["x"]}

      assert %{"custom_filter" => %{"price" => "10"}} = out = rewrite(%{"filter" => "price=10"})
      refute Map.has_key?(out, "filter")

      assert rewrite(%{"filter" => "title=x"}) == %{"filter" => "title=x"}
    end

    test "a non-map custom_filter is left for the preparation" do
      params = %{"filter" => %{"p" => "1"}, "custom_filter" => "junk"}
      assert rewrite(params) == params
    end

    test "only routes whose action declares custom_filter are rewritten" do
      params = %{"filter" => %{"price" => "10"}}

      assert Aliases.rewrite(params, KilnCMS.CMS.MediaItem, route(KilnCMS.CMS.MediaItem, :read)) ==
               params
    end

    test "relationship routes are not rewritten" do
      params = %{"filter" => %{"price" => "10"}, "sort" => "price"}
      index = route(KilnCMS.CMS.Post, :read)

      for type <- [:get_related, :relationship, :post_to_relationship] do
        assert Aliases.rewrite(params, KilnCMS.CMS.Post, %{index | type: type}) == params
      end
    end

    test "only :index routes are rewritten" do
      params = %{"filter" => %{"price" => "10"}}
      route = route(KilnCMS.CMS.Post, :read, :get)
      assert Aliases.rewrite(params, KilnCMS.CMS.Post, route) == params
    end
  end

  describe "filter groups (#2355)" do
    test "a group of built-ins only stays native" do
      params = %{"filter" => %{"or" => %{"0" => %{"title" => "a"}, "1" => %{"slug" => "b"}}}}
      assert rewrite(params) == params
    end

    test "a group naming a custom field moves, built-ins gather under _native" do
      params = %{
        "filter" => %{
          "or" => %{"0" => %{"price" => %{"gt" => "1"}}, "1" => %{"title" => "a"}},
          "state" => "published"
        }
      }

      assert rewrite(params) == %{
               "filter" => %{"state" => "published"},
               "custom_filter" => %{
                 "_or" => [%{"price" => %{"gt" => "1"}}, %{"_native" => %{"title" => "a"}}]
               }
             }
    end

    test "not, and, nesting, relationship operators" do
      params = %{
        "filter" => %{
          "not" => %{"price" => "1", "title" => "a"},
          "and" => [%{"or" => [%{"rating" => "2"}, %{"title" => "b"}]}, %{"title" => "c"}]
        }
      }

      out = rewrite(params)
      refute Map.has_key?(out, "filter")

      assert out["custom_filter"] == %{
               "_not" => %{"price" => "1", "_native" => %{"title" => "a"}},
               "_and" => [
                 %{"_or" => [%{"rating" => "2"}, %{"_native" => %{"title" => "b"}}]},
                 %{"_native" => %{"title" => "c"}}
               ]
             }

      tags = %{"filter" => %{"or" => [%{"tags" => %{"has" => "1"}}, %{"title" => "a"}]}}

      assert rewrite(tags)["custom_filter"] == %{
               "_or" => [%{"tags" => %{"has" => "1"}}, %{"_native" => %{"title" => "a"}}]
             }
    end

    test "a clash with an explicit group key, or a malformed group, stays as written" do
      clash = %{
        "filter" => %{"or" => [%{"price" => "1"}]},
        "custom_filter" => %{"_or" => [%{"price" => "2"}]}
      }

      assert rewrite(clash) == clash

      junk = %{"filter" => %{"or" => "price"}}
      assert rewrite(junk) == junk
    end
  end

  describe "sort" do
    test "custom tokens move, order and direction kept" do
      out = rewrite(%{"sort" => "-price, rating"})
      assert out["custom_sort"] == "-price,rating"
      refute Map.has_key?(out, "sort")
    end

    test "built-ins first then custom splits at the boundary" do
      out = rewrite(%{"sort" => "-title,price"})
      assert out == %{"sort" => "-title", "custom_sort" => "price"}
    end

    test "a custom token before a built-in one is one combined order (#2356)" do
      assert rewrite(%{"sort" => "price,title"}) == %{"custom_sort" => "price,_native:title"}

      assert rewrite(%{"sort" => "-title,price,-state,rating"}) ==
               %{"sort" => "-title", "custom_sort" => "price,-_native:state,rating"}
    end

    test "moved tokens go before an explicit custom_sort" do
      out = rewrite(%{"sort" => "price", "custom_sort" => "rating"})
      assert out == %{"custom_sort" => "price,rating"}
      params = %{"sort" => "title", "custom_sort" => "rating"}
      assert rewrite(params) == params
    end

    test "built-in names that cannot be sorted stay built-in" do
      params = %{"sort" => "word_count"}
      assert rewrite(params) == params
    end

    test "blank tokens are left for the native error" do
      assert rewrite(%{"sort" => ""}) == %{"sort" => ""}
      assert rewrite(%{"sort" => "price,"}) == %{"sort" => "price,"}
    end

    test "search routes take custom_sort; routes without the argument are untouched" do
      assert %{"custom_sort" => "price"} = rewrite(%{"sort" => "price"}, :search)

      params = %{"sort" => "price"}

      assert Aliases.rewrite(params, KilnCMS.CMS.MediaItem, route(KilnCMS.CMS.MediaItem, :read)) ==
               params
    end

    test "search_any style filter names are not touched on routes lacking the argument" do
      assert rewrite(%{"sort" => "price"}, :search_published)["custom_sort"] == "price"
    end
  end

  test "call/2 passes the non-route notices through" do
    conn = Plug.Test.conn(:get, "/")

    for notice <- [:open_api, :json_schema, :not_found],
        do: assert(Aliases.call(conn, notice) == conn)
  end
end
