defmodule Kiln.Security.Check.Context do
  @moduledoc """
  What a `Kiln.Security.Check` is run with (kiln_cms#2252).

    * `org_id` — the site the report is for, for a `:site` check. `nil` for a
      `:deployment` check, which is about the whole installation.
    * `build_env` — the environment the release was compiled for (`:prod`,
      `:dev`, `:test`, …). A check about a production-only setting answers
      `:n_a` on anything else.
    * `now` — the moment the report was started. Use it instead of reading the
      clock, so a test can move it.
    * `locale` — the locale of the person reading the page (`"en"`, `"fr"`,
      …). A check's summary and details are shown as written, so a plugin that
      translates them uses this (with its own Gettext backend, say).

  There is deliberately no actor. A check reports on settings and records the
  site's administrators are allowed to see; it is not run *as* anyone, and it
  must not reveal more than its own summary, details and facts say.
  """

  @type t :: %__MODULE__{
          org_id: String.t() | nil,
          build_env: atom(),
          now: DateTime.t(),
          locale: String.t()
        }

  @enforce_keys [:build_env, :now]
  defstruct org_id: nil, build_env: :prod, now: nil, locale: "en"
end
