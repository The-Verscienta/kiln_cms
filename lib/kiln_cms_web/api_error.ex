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

    * `KilnCMSWeb.ErrorJSON` — Phoenix's fallback view for *raised* errors
      (`/api/nope`, an unhandled 500). Renders `errors` as an object rather
      than an array, so it does not match this contract at all (#750).
    * `KilnCMSWeb.ResolveController` — `/api/resolve` answers a verdict
      (`{"status": "ok" | "moved" | "not_found"}`), and its 404 is that verdict
      rather than an error (#750).
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
    |> json(%{
      errors: [%{status: to_string(Plug.Conn.Status.code(status)), code: code, detail: detail}]
    })
  end
end
