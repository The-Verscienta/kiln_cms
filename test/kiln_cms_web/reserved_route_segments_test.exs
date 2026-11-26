defmodule KilnCMSWeb.ReservedRouteSegmentsTest do
  @moduledoc """
  The router and `ContentTypes.reserved_path_segments/0` agree (#2898).

  A GET route declared ahead of `/:slug` answers its URL before delivery does,
  so a page, path alias or dynamic type that takes its first segment is saved
  but never served. `developers`, `ready`, `setup`, `sign-out`, … were missed
  that way. This reads the compiled route table, so a new top-level route
  fails here until its segment is reserved.

  Only slug-shaped segments count: a slug and an alias segment are
  `[a-z0-9-]`, so `sitemap.xml`, `llms.txt` or `.well-known` can never collide.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.ContentTypes

  # First segments whose routes are all three or more segments deep, so they
  # answer neither a page's `/<slug>` nor a dynamic type's `/<segment>/<slug>`.
  # Reserving them would refuse common page slugs for nothing. (A path alias
  # spelled exactly like one of these routes is still shadowed.)
  @deeper_only %{
    # `/forms/:slug/embed`; `POST /forms/:slug` is not a GET. #2341 left it out.
    "forms" => "only /forms/:slug/embed",
    # `/newsletter/unsubscribe/:token`, `/newsletter/confirm/:token`.
    "newsletter" => "only /newsletter/<action>/:token"
  }

  @slug_shaped ~r/\A[a-z0-9-]+\z/

  # Every GET (or any-method) route the router declares before `/:slug`.
  defp routes_ahead_of_slug do
    routes = KilnCMSWeb.Router.__routes__()
    assert Enum.any?(routes, &(&1.path == "/:slug")), "the /:slug catch-all moved or was renamed"

    routes
    |> Enum.take_while(&(&1.path != "/:slug"))
    |> Enum.filter(&(&1.verb in [:get, :*]))
  end

  defp static_slug_shaped(route) do
    case String.split(route.path, "/", trim: true) do
      [first | _] = segments ->
        if Regex.match?(@slug_shaped, first),
          do: [{first, length(segments), route.path}],
          else: []

      [] ->
        []
    end
  end

  test "every route ahead of /:slug that can shadow content has a reserved first segment" do
    reserved = ContentTypes.reserved_path_segments()

    missing =
      for route <- routes_ahead_of_slug(),
          {first, depth, path} <- static_slug_shaped(route),
          first not in reserved,
          depth <= 2 or not Map.has_key?(@deeper_only, first),
          uniq: true,
          do: {first, path}

    assert missing == [],
           "routes declared ahead of /:slug whose first segment is not in " <>
             "ContentTypes.reserved_path_segments/0 (a page or dynamic type using it " <>
             "would never be served; add it, or to @deeper_only with a reason if every " <>
             "route under it is three segments deep): #{inspect(missing)}"
  end

  test "the deeper-only exemptions are still routes, and still deep" do
    by_first =
      routes_ahead_of_slug()
      |> Enum.flat_map(&static_slug_shaped/1)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    for first <- Map.keys(@deeper_only) do
      assert depths = by_first[first], "#{first} has no route any more: drop the exemption"
      assert Enum.all?(depths, &(&1 >= 3)), "#{first} now has a shallow route: reserve it"
    end
  end

  test "the segments the issue named are reserved" do
    reserved = ContentTypes.reserved_path_segments()

    for segment <- ~w(developers actor ap ready sign-out setup mcp) do
      assert segment in reserved
    end
  end
end
