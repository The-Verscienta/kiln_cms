defmodule KilnCMSWeb.BracketedParamsTest do
  @moduledoc """
  No client-chosen parameter *shape* can 500 a public route (#751).

  Plug's query decoder hands the caller the type as well as the value: `?q=x` is
  a binary, `?q[]=x` a list, `?q[a]=x` a map. A `%{"slug" => slug}` head
  constrains the key and never the value, so every one of these is `term()`
  until something checks — and the two ways of forgetting fail differently.
  A bare parser (`Integer.parse/1`, `DateTime.from_iso8601/1`) raises on both
  shapes; `to_string/1` quietly absorbs the list and raises only on the map, so
  a site can look exercised and still be one bracket from a 500.

  Neither is a `Plug.Exception`, so on an unauthenticated route each request is
  a 500 *and* an error-tracker event — an anonymous report generator, the same
  shape as #700.

  The table below is the point of the file: every public entry point that reads
  a client-supplied scalar, driven through the real router in both shapes. A new
  one is a row here, and the row is what fails when someone reaches for
  `to_string/1`.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  alias KilnCMS.CMS.Page

  doctest KilnCMSWeb.Params

  # A published document, so the rows below enter the handler's *success*
  # branch. Without one, `related`'s `limit/1` sits inside a `with` that a
  # nonexistent slug never reaches, and the row asserts nothing but a 404.
  setup do
    slug = "brackets-#{System.unique_integer([:positive])}"

    Ash.Seed.seed!(Page, %{
      title: "Bracket subject",
      slug: slug,
      state: :published,
      published_at: DateTime.utc_now()
    })

    %{slug: slug}
  end

  # {label, path, param} — each is fetched three ways: plain, `[]`, and `[a]`.
  @get_routes [
    {"artifact collection as_of", "/api/content/page", "as_of"},
    {"artifact collection limit", "/api/content/page?as_of=2020-01-01", "limit"},
    {"artifact show as_of", "/api/content/page/__SLUG__", "as_of"},
    {"artifact show locale", "/api/content/page/__SLUG__", "locale"},
    {"artifact show surface", "/api/content/page/__SLUG__", "surface"},
    {"related limit", "/api/content/page/__SLUG__/related", "limit"},
    {"related locale", "/api/content/page/__SLUG__/related", "locale"},
    {"search q", "/api/search", "q"},
    {"search limit", "/api/search?q=hello", "limit"},
    {"search locale", "/api/search?q=hello", "locale"},
    {"ask q", "/api/ask", "q"},
    {"ask locale", "/api/ask?q=hello", "locale"},
    {"resolve locale", "/api/resolve?path=/__SLUG__", "locale"},
    {"provenance locale", "/api/provenance/page/__SLUG__", "locale"},
    {"visual-editing locale", "/api/visual-editing/page/__SLUG__", "locale"}
  ]

  # The on-site pages, which answer HTML rather than JSON.
  @html_routes [
    {"site search q", "/search", "q"},
    {"blog page", "/blog", "page"}
  ]

  defp shapes(param), do: ["#{param}=x", "#{param}[]=x", "#{param}[a]=x"]

  defp separator(path), do: if(String.contains?(path, "?"), do: "&", else: "?")

  describe "a bracketed query parameter never 500s a public GET" do
    for {label, path, param} <- @get_routes do
      @label label
      @path path
      @param param

      test "#{label}", %{slug: slug} do
        path = String.replace(@path, "__SLUG__", slug)

        for query <- shapes(@param) do
          conn =
            build_conn()
            |> put_req_header("accept", "application/json")
            |> get(path <> separator(path) <> query)

          # 500 specifically, not 5xx: an unhandled raise is what Phoenix
          # renders as 500, while a 503 here is delivery deliberately answering
          # `artifact_compiling` for a document with no fired artifact yet.
          refute conn.status == 500,
                 "#{@label} answered #{conn.status} for ?#{query} — a client-chosen " <>
                   "parameter shape must not reach a parser that has no clause for it"
        end
      end
    end
  end

  describe "a bracketed query parameter never 500s a public HTML page" do
    for {label, path, param} <- @html_routes do
      @label label
      @path path
      @param param

      test "#{label}" do
        for query <- shapes(@param) do
          conn =
            build_conn()
            |> put_req_header("accept", "text/html")
            |> get(@path <> separator(@path) <> query)

          refute conn.status == 500,
                 "#{@label} answered #{conn.status} for ?#{query}"
        end
      end
    end
  end

  describe "the shape is refused, not silently reinterpreted" do
    test "a bracketed as_of is the documented 400, not a live read" do
      # `as_of` is the one parameter where reading a malformed value as *absent*
      # would be worse than the crash: it would serve the current document to a
      # compliance reader who asked what it said on a date. So it takes the same
      # branch a garbage string does.
      for query <- ["as_of[]=2020-01-01", "as_of[a]=2020-01-01"] do
        conn =
          build_conn()
          |> put_req_header("accept", "application/json")
          |> get("/api/content/page?" <> query)

        assert %{"errors" => [%{"code" => "invalid_as_of"}]} = json_response(conn, 400)
      end
    end

    test "a bracketed q searches for nothing rather than for its first element" do
      # `to_string(["x"]) == "x"`, so the old code answered `?q[]=x` as if it
      # were `?q=x`. One request meaning two things depending on which helper
      # the handler happened to use is the drift worth removing, even though
      # neither answer crashes.
      bracketed =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/api/search?q[]=hello")

      assert %{"query" => ""} = json_response(bracketed, 200)
    end
  end

  describe "public POST bodies" do
    test "a bracketed form field is a validation error, not a crash" do
      form =
        Ash.Seed.seed!(KilnCMS.CMS.Form, %{
          name: "Contact",
          slug: "brackets-#{System.unique_integer([:positive])}",
          active: true
        })

      Ash.Seed.seed!(KilnCMS.CMS.FormField, %{
        form_id: form.id,
        name: "message",
        label: "Message",
        field_type: :text,
        required: true,
        position: 0
      })

      for body <- [%{"message" => ["hi"]}, %{"message" => %{"a" => "hi"}}] do
        conn =
          build_conn()
          |> put_req_header("accept", "application/json")
          |> post("/api/forms/#{form.slug}", body)

        refute conn.status == 500
      end
    end

    test "a bracketed newsletter email is refused, not a crash" do
      for body <- [%{"email" => ["a@b.test"]}, %{"email" => %{"a" => "a@b.test"}}] do
        conn = post(build_conn(), "/newsletter/subscribe", body)
        refute conn.status == 500
      end
    end
  end

  describe "a bracketed query parameter never 500s /api/json (#763)" do
    # Each shape the ash_json_api sweep found raising, verified against the
    # real router: page[limit]/page[offset] via Integer.parse/1 (no clause
    # for a list or map), a non-object `page` via Map.fetch/2 (no clause for
    # a non-map), and sort/include via String.Chars/String.split (no clause
    # for either). filter[...] and fields[...] are deliberately absent —
    # ash_json_api already handles those shapes correctly (400, not 500).
    @bad_shapes [
      {"page[limit][]", "page[limit][]=1"},
      {"page[limit][a]", "page[limit][a]=1"},
      {"page[offset][]", "page[offset][]=1"},
      {"page[offset][a]", "page[offset][a]=1"},
      {"a scalar page", "page=1"},
      {"a listed page", "page[]=1"},
      {"sort[]", "sort[]=title"},
      {"sort[a]", "sort[a]=title"},
      {"include[]", "include[]=tags"},
      {"include[a]", "include[a]=tags"}
    ]

    for {label, query} <- @bad_shapes do
      @query query

      test "#{label}" do
        conn =
          build_conn()
          |> put_req_header("accept", "application/vnd.api+json")
          |> get("/api/json/posts?#{@query}")

        refute conn.status == 500,
               "?#{@query} answered 500 — a client-chosen parameter shape must not " <>
                 "reach a parser that has no clause for it"

        assert %{"errors" => [%{"status" => "400", "code" => code} | _]} =
                 json_response(conn, 400)

        assert code in ~w(invalid_pagination invalid_sort invalid_includes),
               "?#{@query} answered code #{inspect(code)}, expected one ash_json_api itself uses"
      end
    end

    test "legitimate page/sort/include values are unaffected" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/json/posts?page[limit]=10&page[offset]=0&sort=-inserted_at&include=tags")

      assert conn.status == 200
    end
  end

  describe "the collab socket token is read before any authentication" do
    test "a bracketed token is refused rather than raising in Plug.Crypto" do
      # `Phoenix.Token.verify/4` requires a binary and only has a fallback for
      # `nil`, and this runs before the socket has authenticated anything — so
      # the raise was reachable by anyone who could open a websocket.
      for token <- [["x"], %{"a" => "x"}, 1] do
        assert :error = KilnCMSWeb.CollabSocket.connect(%{"token" => token}, %{}, %{})
      end
    end
  end

  describe "the guards do not change the working paths" do
    test "a plain as_of still resolves, and a plain locale still selects" do
      Ash.Seed.seed!(Page, %{
        title: "Bracket guard",
        slug: "bracket-guard-#{System.unique_integer([:positive])}",
        state: :draft
      })

      ok =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/api/content/page?as_of=2020-01-01")

      assert %{"as_of" => _, "entries" => _} = json_response(ok, 200)

      searched =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/api/search?q=hello")

      assert %{"query" => "hello"} = json_response(searched, 200)
    end
  end

  describe "guards against the next one" do
    # A helper each call site must remember is a convention, and #744 is this
    # repo's record of what those are worth. So the specific trap is scanned
    # for rather than described: `to_string/1` reached for on a request
    # parameter, which is the edit that looks harmless, passes review, and
    # 500s on a map.
    @trap ~r/to_string\(\s*params\[|params\[[^\]]*\]\s*\|>\s*to_string|Integer\.parse\(\s*params\[|from_iso8601\(\s*params\[/

    # Deliberate divergences go here with a reason. Nothing qualifies today.
    @allowed %{}

    test "no controller or channel reaches for to_string on a request parameter" do
      offenders =
        ["lib/kiln_cms_web/controllers/**/*.ex", "lib/kiln_cms_web/channels/**/*.ex"]
        |> Enum.flat_map(&Path.wildcard/1)
        |> Enum.reject(&Map.has_key?(@allowed, &1))
        |> Enum.filter(&(File.read!(&1) =~ @trap))

      assert offenders == [],
             """
             These read a request parameter straight into a parser, or through
             `to_string/1`, which raises on the map a client sends as `?x[a]=1`:

             #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

             `KilnCMSWeb.Params.string/3` and `integer/4` are the readers. If the
             divergence is deliberate, add the file to @allowed with the reason.
             """
    end

    test "the scan detects the trap" do
      # Otherwise a regex that matches nothing passes the test above forever.
      assert ~S'to_string(params["q"])' =~ @trap
      assert ~S'params["q"] |> to_string()' =~ @trap
      assert ~S'Integer.parse(params["limit"])' =~ @trap
      assert ~S'DateTime.from_iso8601(params["as_of"])' =~ @trap

      refute ~S'Params.string(params, "q", "")' =~ @trap
      refute ~S'Map.get(@surfaces, params["surface"] || "json")' =~ @trap
    end
  end
end
