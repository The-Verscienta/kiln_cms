defmodule KilnCMSWeb.ApiErrorTest do
  @moduledoc """
  The headless error envelope (#744).

  Three layers, because the drift this replaces could not have been caught by
  any one of them:

    * `send/4`'s own behaviour — that an atom status renders numerically, which
      is the property `FormController`'s copy got wrong;
    * that each headless surface still answers the envelope end to end;
    * `guards against a seventh copy` — a source scan over `lib/kiln_cms_web/`
      that fails when any module writes the envelope by hand.

  The scan is the load-bearing one. The surface tests below would all have
  passed against the pre-refactor tree: `FormController`'s drifted
  `to_string(status)` was only ever *called* with the integer literal `404`,
  and `to_string(404)` is `"404"` too. The bug was latent, so no black-box
  assertion could have reached it — only removing the copy fixes it, and only
  the scan keeps it removed.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMSWeb.ApiError

  defp json_conn(conn), do: put_req_header(conn, "accept", "application/json")

  # Every envelope, from every surface, must satisfy this.
  defp assert_envelope(body, expected_status) do
    assert %{"errors" => [entry]} = body
    assert %{"status" => status, "code" => code, "detail" => detail} = entry

    # The point of the exercise: a numeric string, never the atom's name.
    assert status == to_string(expected_status)
    assert is_binary(code) and code != ""
    assert is_binary(detail) and detail != ""
  end

  describe "send/4" do
    test "normalizes an atom status to its numeric string", %{conn: conn} do
      conn = ApiError.send(conn, :unprocessable_entity, "missing_parameters", "email is required")

      assert conn.status == 422
      assert %{"errors" => [%{"status" => "422"}]} = json_response(conn, 422)
    end

    test "an integer status produces the identical body", %{conn: conn} do
      atom = ApiError.send(conn, :not_found, "not_found", "Content not found.")
      int = ApiError.send(conn, 404, "not_found", "Content not found.")

      assert json_response(atom, 404) == json_response(int, 404)
    end

    test "leaves response headers to the caller", %{conn: conn} do
      conn =
        conn
        |> put_resp_header("retry-after", "2")
        |> ApiError.send(:service_unavailable, "temporarily_unavailable", "Retry shortly.")

      assert get_resp_header(conn, "retry-after") == ["2"]
      assert_envelope(json_response(conn, 503), 503)
    end
  end

  describe "every headless surface" do
    test "GET /api/content/:type/:slug (artifact)", %{conn: conn} do
      conn = conn |> json_conn() |> get(~p"/api/content/page/no-such-page-#{unique()}")
      assert_envelope(json_response(conn, 404), 404)
    end

    test "GET /api/content/:type/:slug/related", %{conn: conn} do
      conn = conn |> json_conn() |> get(~p"/api/content/page/no-such-page-#{unique()}/related")
      assert_envelope(json_response(conn, 404), 404)
    end

    test "GET /api/provenance/:type/:slug", %{conn: conn} do
      # Provenance is disabled by default, which is its own envelope
      # (`provenance_disabled`) rather than a plain 404 body.
      conn = conn |> json_conn() |> get(~p"/api/provenance/page/no-such-page-#{unique()}")
      assert_envelope(json_response(conn, 404), 404)
    end

    test "GET /api/forms/:slug", %{conn: conn} do
      conn = conn |> json_conn() |> get(~p"/api/forms/no-such-form-#{unique()}")
      assert_envelope(json_response(conn, 404), 404)
    end

    test "POST /api/forms/:slug", %{conn: conn} do
      conn = conn |> json_conn() |> post(~p"/api/forms/no-such-form-#{unique()}", %{})
      assert_envelope(json_response(conn, 404), 404)
    end

    test "GET /api/visual-editing/:type/:slug", %{conn: conn} do
      conn = conn |> json_conn() |> get(~p"/api/visual-editing/page/no-such-page-#{unique()}")
      assert_envelope(json_response(conn, 404), 404)
    end

    test "GET /preview/:token", %{conn: conn} do
      conn = conn |> json_conn() |> get(~p"/preview/not-a-real-token")
      assert_envelope(json_response(conn, 404), 404)
    end

    test "POST /api/auth/sign_in — 401 and 422 both", %{conn: conn} do
      unauthorized =
        conn
        |> json_conn()
        |> post(~p"/api/auth/sign_in", %{"email" => "nobody@example.com", "password" => "wrong"})

      assert_envelope(json_response(unauthorized, 401), 401)

      # The atom-status path, which is where the drift would have shown.
      missing = conn |> json_conn() |> post(~p"/api/auth/sign_in", %{"email" => "a@b.test"})
      assert_envelope(json_response(missing, 422), 422)
    end
  end

  describe "guards against a seventh copy" do
    # `errors:` / `"errors" =>` opening a list or a map, with `detail` close
    # behind. `detail` is what distinguishes *this* envelope from the other
    # `errors` shapes in the tree — GraphQL's `message`, and the `%{errors: […]}`
    # patterns that LiveViews match Ash errors against.
    @envelope ~r/"?errors"?\s*(:|=>)\s*(\[|%\{)/

    # Each entry is a deliberate divergence, and has to stay explained. Adding
    # to this list is the decision; hand-writing the envelope is not.
    @allowed %{
      # The implementation, plus the moduledoc that shows the shape.
      "lib/kiln_cms_web/api_error.ex" => "the one implementation",
      # Phoenix's fallback view for *raised* errors. Renders `errors` as an
      # object rather than an array, so it does not match this contract at all
      # — tracked separately rather than changed in passing (#750).
      "lib/kiln_cms_web/controllers/error_json.ex" => "raised-error fallback, see #750"
    }

    test "no module under lib/kiln_cms_web/ writes the envelope by hand" do
      offenders =
        "lib/kiln_cms_web/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&Map.has_key?(@allowed, &1))
        |> Enum.filter(&hand_written_envelope?/1)

      assert offenders == [],
             """
             These modules build the headless error envelope themselves instead of
             calling KilnCMSWeb.ApiError.send/4:

             #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

             That is how #744 happened: six copies, one of which had already
             drifted. Route them through ApiError, or — if the divergence is
             deliberate — add the file to @allowed with the reason.
             """
    end

    test "the allowlist has no stale entries" do
      stale = Enum.reject(Map.keys(@allowed), &hand_written_envelope?/1)

      assert stale == [],
             "no longer writes the envelope by hand, drop from @allowed: #{inspect(stale)}"
    end

    # Proves the scan can actually fail — otherwise a regex that matches
    # nothing would pass both tests above forever.
    test "the scan detects a hand-written envelope" do
      assert envelope_in?(~S'json(conn, %{errors: [%{status: "404", detail: "gone"}]})')
      assert envelope_in?(~S'json(%{"errors" => [%{"detail" => message}]})')
      assert envelope_in?(~S'%{errors: %{detail: "Not Found"}}')

      # ...and that it leaves the other `errors` shapes alone.
      refute envelope_in?(~S'%{errors: [%{message: "GraphQL introspection is disabled"}]}')
      refute envelope_in?(~S'defp error_message(%{errors: [%{message: message} | _rest]})')
    end

    defp hand_written_envelope?(path) do
      case File.read(path) do
        {:ok, source} -> envelope_in?(source)
        _ -> false
      end
    end

    defp envelope_in?(source) do
      @envelope
      |> Regex.scan(source, return: :index)
      |> Enum.any?(fn [{start, len} | _] ->
        source |> binary_part(start + len, min(200, byte_size(source) - start - len)) =~ "detail"
      end)
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
