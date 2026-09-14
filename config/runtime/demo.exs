import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ── Demo mode (docs/demo-mode.md) ────────────────────────────────────────────
#
# A public "try the editor" instance that resets to a golden snapshot on a
# schedule — which means dropping every table in the database on a timer. So
# KILN_DEMO_RESET is a SENTINEL WORD, not a boolean: only `confirm` enables it,
# and `true` is refused (warned and collected) exactly like a misspelling, the
# KILN_STAGING_SCRUB convention. `KilnCMS.Demo.Guard` re-checks the database,
# the host and the snapshot at every reset regardless.
#
# Here rather than beside the other cron schedules, and last before the warning
# flush, so it can override the mailer and federation blocks above — and so it
# shifts no line anchor that docs/environment-variables.md cites for them.
#
# Skipped in `:test`: the suite drives `KilnCMS.Demo` through Application env,
# and an exported shell must not put the suite into demo mode.
if config_env() != :test do
  with {:ok, "confirm"} <- Env.one_of("KILN_DEMO_RESET", ["confirm"]) do
    config :kiln_cms, KilnCMS.Demo, enabled: true

    demo_golden = "KILN_DEMO_GOLDEN_PATH" |> System.get_env("") |> String.trim()

    if demo_golden != "" do
      config :kiln_cms, KilnCMS.Demo, golden_path: demo_golden
    end

    # Hourly unless set; `false` keeps demo mode but drops the schedule (manual
    # resets only). A blank value is "unset", not "off" — `.env` files write
    # `VAR=` to mean "leave it alone".
    demo_cron = "KILN_DEMO_RESET_CRON" |> System.get_env("") |> String.trim()
    config :kiln_cms, :demo_reset_cron, if(demo_cron == "", do: "0 * * * *", else: demo_cron)

    # Anyone can reach a public demo, so anything a visitor can make it send
    # goes inert: mail is logged (recipient only) instead of delivered, and
    # federation is off whatever KILN_FEDERATION_ENABLED says. Webhooks, social
    # posting, push and LLM keys are admin-configured — leave them out of the
    # golden snapshot and the environment (docs/demo-mode.md).
    config :kiln_cms, KilnCMS.Mailer, adapter: Swoosh.Adapters.Logger
    config :kiln_cms, KilnCMS.Federation, enabled: false
  end
end
