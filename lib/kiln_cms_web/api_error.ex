defmodule KilnCMSWeb.ApiError do
  @moduledoc """
  The one error envelope the headless surfaces answer with (#190, #744).

      {"errors": [{"status": "404", "code": "not_found", "detail": "Content not found."}]}

  It is the JSON:API error shape, so `/api/json` and the hand-written surfaces
  agree, and `docs/api.md` documents it once for both.

  ## Why this is a module rather than a comment

  It used to be a convention — the phrase *"standard error envelope shared
  across the headless surfaces"* sat in a comment that four controllers copied
  along with the `defp error/4` beneath it. Two more surfaces wrote the map out
  inline, one of them with no comment at all, and the per-IP 429 wrote a
  third shape with neither `status` nor `code`.

  A convention named in a comment and enforced nowhere drifts, and it had:
  `FormController`'s copy interpolated the status it was handed rather than
  `Plug.Conn.Status.code/1`, so an atom status would have emitted
  `"unprocessable_entity"` where the others emitted `"422"`. Nothing passed it
  an atom yet, which is the only reason no client saw it — a latent difference
  in a public response body, waiting for the next call site.

  The inline copies are the harder half. A duplicated named function is at
  least greppable; a literal `%{errors: [%{status: "404", …}]}` in the middle
  of an `else` branch looks like ordinary response-building. That is what
  `test/kiln_cms_web/api_error_test.exs` guards: it reads the source of every
  module under `lib/kiln_cms_web/` and fails on a hand-written envelope
  wherever it appears, in whatever shape.

  `status` is deliberately a **string** and deliberately **numeric**: string
  because that is what JSON:API specifies, numeric because a client parsing it
  with `parseInt` is the obvious reading and it is the only form that works
  across every surface.

  ## What is deliberately *not* this envelope

  Named here because the enforcing test allows each one explicitly, and an
  allowlist is only honest if it says why:

    * `KilnCMSWeb.ResolveController` — `/api/resolve` answers a verdict
      (`{"status": "ok" | "moved" | "not_found"}`), and its 404 is that verdict
      rather than an error (#750). Its 400 (a missing/malformed `?path=`) IS an
      error, and answers this envelope via `send/4` like everything else.
    * `POST /api/forms/:slug`'s 422 — field-level validation errors are
      `{"ok": false, "errors": {"<field>": "…"}}`, a per-field map that this
      envelope has no room for.
    * GraphQL — follows the GraphQL spec's own top-level `errors` array.

  ## What callers keep

  Their own named wrappers — `unauthorized/1`, `not_found/1`,
  `provenance_disabled/1`. Those legitimately differ per surface; the envelope
  does not. Response headers stay the caller's business: pipe
  `put_resp_header/3` in *before* `send/4`, as the `retry-after` on a 429 or
  503 does. Afterwards is too late — the response has been sent.

  `send/4` sets the status, the body, and (via `Phoenix.Controller.json/2`)
  `content-type: application/json` — the last only if the conn does not already
  carry one, so do not hand it a conn whose content type was set for a
  different surface.

  ## `body/3` and `body_from_template/1`

  `send/4` is for a controller, which has a `conn` to put a status on.
  `KilnCMSWeb.ErrorJSON` (#750) is a Phoenix error VIEW — invoked for a
  *raised* error on a JSON-negotiated request (an unrouted path, or an
  unhandled exception), with no controller action and no envelope-specific
  values to pass, only the template name Phoenix derives the status from
  (`"404.json"`). `body/3` is `send/4`'s body alone, and `body_from_template/1`
  derives `status`/`code`/`detail` the same way Phoenix's own
  `status_message_from_template/1` derives its message — so the two agree
  on what an unrecognized template renders as (`500`/`internal_server_error`),
  rather than growing a second answer to the same question.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  @doc """
  Answer with the standard envelope: `status` sets the HTTP status and is
  echoed into the body as its numeric string, `code` is the stable
  machine-readable token clients branch on, `detail` the human sentence.

  `status` is a named `Plug.Conn.Status` atom (`:not_found`) or an integer in
  `100..999`; both normalize to the same body. Anything else raises, in a
  module whose whole job is rendering error responses — so pass a literal, and
  never a value derived from request data.
  """
  @spec send(Plug.Conn.t(), atom() | 100..999, String.t(), String.t()) :: Plug.Conn.t()
  def send(conn, status, code, detail) do
    conn
    |> put_status(status)
    |> json(body(status, code, detail))
  end

  @doc "The envelope body alone — see \"`body/3` and `body_from_template/1`\" above."
  @spec body(atom() | 100..999, String.t(), String.t()) :: map()
  def body(status, code, detail) do
    %{errors: [%{status: to_string(Plug.Conn.Status.code(status)), code: code, detail: detail}]}
  end

  @doc """
  The envelope for a Phoenix error-view template name (`"404.json"`) —
  `status`/`code`/`detail` all derived from the status code the template
  names. An unrecognized template (custom status Plug.Conn.Status has no
  entry for) falls back to `500`/`internal_server_error`, matching
  `Phoenix.Controller.status_message_from_template/1`'s own fallback.
  """
  @spec body_from_template(String.t()) :: map()
  def body_from_template(template) do
    code = template |> String.split(".") |> hd() |> String.to_integer()
    body(code, code_token(code), Plug.Conn.Status.reason_phrase(code))
  rescue
    _ -> body(500, "internal_server_error", "Internal Server Error")
  end

  # `Plug.Conn.Status.reason_atom/1` is not the inverse of `code/1` for 422:
  # Plug's table spells it "Unprocessable Content" per RFC 9110, so
  # `reason_atom(422)` answers `:unprocessable_content` — but every 422 this
  # codebase writes by hand uses `unprocessable_entity` (`:unprocessable_entity`
  # is still a valid INPUT to `code/1`, just not what `reason_atom/1` outputs).
  # Left to derive automatically, the first raised 422 that reaches this
  # function would silently answer a different `code` than every other 422 —
  # the exact "nothing passed it an atom yet, which is the only reason no
  # client saw it" drift this module's own moduledoc warns about.
  defp code_token(422), do: "unprocessable_entity"
  defp code_token(code), do: to_string(Plug.Conn.Status.reason_atom(code))
end
