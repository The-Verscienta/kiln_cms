defmodule KilnCMSWeb.RouterTest do
  use ExUnit.Case, async: true

  alias KilnCMSWeb.Router

  test "the API landing route matches only the bare GET path" do
    assert %{plug: KilnCMSWeb.PageController, plug_opts: :api, route: "/api"} =
             Phoenix.Router.route_info(Router, "GET", "/api", "localhost")

    assert %{plug: KilnCMSWeb.ContentController, plug_opts: :fallback} =
             Phoenix.Router.route_info(Router, "GET", "/api/unknown/nested", "localhost")

    assert :error = Phoenix.Router.route_info(Router, "POST", "/api", "localhost")
  end

  test "JSON:API paths still reach the forward" do
    for method <- ["GET", "POST", "PATCH", "DELETE"],
        path <- ["/api/json", "/api/json/posts", "/api/json/posts/example"] do
      assert %{plug: KilnCMSWeb.AshJsonApiRouter} =
               Phoenix.Router.route_info(Router, method, path, "localhost")
    end
  end

  test "nested API routes keep their handlers" do
    for {method, path, controller, action} <- [
          {"GET", "/api/search", KilnCMSWeb.SearchApiController, :index},
          {"GET", "/api/graphql/schema.graphql", KilnCMSWeb.ApiSpecController, :graphql_sdl},
          {"POST", "/api/auth/sign_in", KilnCMSWeb.ApiAuthController, :sign_in},
          {"POST", "/api/media", KilnCMSWeb.MediaUploadController, :create}
        ] do
      assert %{plug: ^controller, plug_opts: ^action} =
               Phoenix.Router.route_info(Router, method, path, "localhost")
    end
  end
end
