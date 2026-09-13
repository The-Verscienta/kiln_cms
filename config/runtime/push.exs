import Config

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# Web Push's VAPID keys, lifted out of the provenance-claims block they shared a
# `config_env() != :test` guard with in the single-file runtime.exs. Same guard,
# same position in the evaluation order — see config/runtime.exs.
if config_env() != :test do
  # ── Web Push (#628) ──────────────────────────────────────────────────────────
  #
  # VAPID identifies this deployment to a push service. Runtime rather than
  # compile time so a prebuilt image can be switched on by an operator, and
  # absent keys mean push is simply off: `KilnCMS.Push.enabled?/0` is false, the
  # settings page never offers the toggle, and the sender no-ops.
  #
  # `mix kiln.vapid.gen` generates a pair (the same format
  # `web-push generate-vapid-keys` emits, so an existing pair carries over).
  # Rotating invalidates every live subscription — the push service answers 403
  # and the row is pruned — so reviewers have to re-enable notifications.
  #
  # Written key by key rather than as one keyword list: `Config` deep-merges, and
  # an operator who sets only the subject must not blank the keys.
  # Inside the non-test region: `runtime.exs` loads after `test.exs` and wins,
  # so a developer or CI runner with `KILN_VAPID_*` exported would otherwise
  # turn push on for the suite and break the premise `config/test.exs` states —
  # failing job-count assertions on one machine and nowhere else.
  for {var, key} <- [
        {"KILN_VAPID_PUBLIC_KEY", :vapid_public_key},
        {"KILN_VAPID_PRIVATE_KEY", :vapid_private_key},
        {"KILN_VAPID_SUBJECT", :vapid_subject}
      ] do
    case var |> System.get_env("") |> String.trim() do
      "" -> :ok
      value -> config :kiln_cms, KilnCMS.Push, [{key, value}]
    end
  end
end
