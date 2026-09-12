import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Signed provenance — the claim fields (#644, residual from #608/#641)
#
# The remaining `KilnCMS.Provenance` keys #608 couldn't reach at runtime: the
# `signer` identity and `origin` URL embedded in every manifest a consumer
# verifies, and the default `ai_disclosure`. They live here, at the end, rather
# than in the main provenance block above (search `KILN_PROVENANCE_ENABLED`)
# because that block is dense with the line anchors `docs/environment-variables.md`
# cites, and inserting there would shift every one below it —
# `test/kiln_cms/docs/env_var_anchors_test.exs` guards exactly that.
#
# Skipped in `:test` like the rest of the provenance config: these values ride
# into a signed claim, and the suite must not depend on a developer's shell.
if config_env() != :test do
  # `signer` and `origin` default to something a released image can already set
  # (`:site_name` / `:public_base_url`), so they are lower stakes than #608's
  # three — but there is no reason a prebuilt image should have to rebuild to
  # override the claim. Written only when set, so the `nil`-means-fall-back
  # semantics survive an unset or blank var; scalar values merge cleanly.
  provenance_signer = "KILN_PROVENANCE_SIGNER" |> System.get_env("") |> String.trim()

  if provenance_signer != "" do
    config :kiln_cms, KilnCMS.Provenance, signer: provenance_signer
  end

  provenance_origin = "KILN_PROVENANCE_ORIGIN" |> System.get_env("") |> String.trim()

  if provenance_origin != "" do
    config :kiln_cms, KilnCMS.Provenance, origin: provenance_origin
  end

  # The default AI-disclosure embedded when a document declares none. Unlike
  # `signer`/`origin`, a garbage value here is written into a SIGNED claim, so an
  # unrecognized spelling warns and keeps the configured default rather than
  # being written — `KilnCMS.Provenance.normalize_disclosure/1` coerces unknown
  # to "human" for per-document reads, the wrong direction for a value an
  # operator set on purpose.
  #
  # `Env.one_of/2` rather than a hand-rolled `cond` (#912): the block used to
  # trim, downcase and match itself and then warn with a bare `IO.warn`, which
  # in a release reaches container stdout and nothing else — no Logger, no
  # Sentry. That is the gap #634 closed for flags, and it lands harder here
  # than on a flag, because the operator's only notice that their spelling was
  # rejected scrolls past once during a deploy while every manifest a consumer
  # verifies carries the compiled default instead.
  with {:ok, disclosure} <-
         Env.one_of("KILN_PROVENANCE_AI_DISCLOSURE", KilnCMS.Provenance.disclosures()) do
    config :kiln_cms, KilnCMS.Provenance, ai_disclosure: disclosure
  end
end
