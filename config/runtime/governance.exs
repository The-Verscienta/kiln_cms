import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Tamper-evident history — master kill switch (#356, #611)
#
# `:audit_anchors_enabled` gates BOTH publish-time anchor minting AND the
# `:audit_anchor_every_write` extension below — `Chain.extend/2` requires
# both, so `KILN_AUDIT_ANCHOR_EVERY_WRITE=true` was a complete no-op whenever
# this stayed off with no runtime override to recover it, contradicting its
# documented status (docs/deploy-p3.md) as an operator-facing kill switch
# reversible without a rebuild.
#
# Compiled default is `true` (anchoring on unless an operator turns it off),
# so an unrecognized value keeps history signed — the safe side, opposite of
# `KILN_AUDIT_ANCHOR_EVERY_WRITE`'s.
#
# Skipped under :test for the same reason as KILN_AUDIT_ANCHOR_EVERY_WRITE.
if config_env() != :test do
  with {:ok, enabled?} <- Env.fetch("KILN_AUDIT_ANCHORS_ENABLED") do
    config :kiln_cms, :audit_anchors_enabled, enabled?
  end
end

# ## Tamper-evident history — anchor every write (#356)
#
# Anchors are always minted at publish. This additionally extends the signed
# chain after *every* versioned write, closing the window between two publishes
# — #356's "sign every version, not just published artifacts". It costs a
# signature and a `history_anchors` row per save, AND it disables autosave
# coalescing (#671), so a draft keeps one version row per debounce. Hence false.
#
# Runtime rather than compile-time on purpose — an operator must be able to turn
# this off without rebuilding the image. See KilnCMS.Governance.Chain and
# docs/editorial-consent.md.
#
# Only RECOGNIZED spellings write config: an unrecognized value (`enabled`, a
# typo, a quote-wrapped `"true"` from `docker run --env-file`) leaves the
# compiled default alone and warns, rather than disabling an audit trail the
# deployment deliberately turned on. Note the compiled default here is `false`,
# so the warning is also the only signal that a typo failed to turn signing ON.
#
# Skipped under :test so the suite is deterministic regardless of the developer's
# environment — the flag causes a DB write per save, and the governance tests
# drive it explicitly with Application.put_env instead.
if config_env() != :test do
  with {:ok, every_write?} <- Env.fetch("KILN_AUDIT_ANCHOR_EVERY_WRITE") do
    config :kiln_cms, :audit_anchor_every_write, every_write?
  end
end

# ## Governance checkpoint witness (#666)
#
# Where the org-wide anchor-chain commitment gets published. Runtime rather than
# compile time because it is the one knob that decides whether the truncation
# guarantee holds against an attacker with full database access, and an operator
# must be able to point it at a bucket without rebuilding the image.
#
# An unrecognized value leaves the compiled default (`none`) rather than
# guessing. That is the *weaker* side, so it is warned about explicitly here
# rather than left to `Env`'s generic stderr line — see KilnCMS.Config.Env on
# why "fail to default" is not "fail safe".
#
# Skipped under :test so the suite does not depend on the developer's shell; the
# checkpoint tests set the adapter explicitly.
if config_env() != :test do
  witness =
    case System.get_env("KILN_GOVERNANCE_WITNESS") do
      nil ->
        nil

      value ->
        case value |> String.trim() |> String.downcase() do
          "" ->
            nil

          "none" ->
            KilnCMS.Governance.Witness.None

          "file" ->
            KilnCMS.Governance.Witness.File

          "s3" ->
            KilnCMS.Governance.Witness.S3

          "http" ->
            KilnCMS.Governance.Witness.HTTP

          other ->
            # ASCII only: config providers write to stderr before Logger exists,
            # and non-ASCII comes back escaped in exactly the line an operator
            # needs to read.
            IO.puts(
              :standard_error,
              "KILN_GOVERNANCE_WITNESS=#{inspect(other)} is not one of none|file|s3|http - " <>
                "governance checkpoints will NOT be published outside the database, " <>
                "which is the weaker side of the default. See #666."
            )

            nil
        end
    end

  if witness do
    config :kiln_cms, KilnCMS.Governance.Witness, adapter: witness
  end

  if dir = System.get_env("KILN_GOVERNANCE_WITNESS_DIR") do
    config :kiln_cms, KilnCMS.Governance.Witness.File, dir: dir
  end

  if bucket = System.get_env("KILN_GOVERNANCE_WITNESS_BUCKET") do
    config :kiln_cms, KilnCMS.Governance.Witness.S3,
      bucket: bucket,
      prefix: System.get_env("KILN_GOVERNANCE_WITNESS_PREFIX", "")
  end

  if witness_url = System.get_env("KILN_GOVERNANCE_WITNESS_URL") do
    # The token stays a `{:env, …}` provider tuple rather than being read here,
    # so it resolves through `KilnCMS.Keys` at call time like every other
    # credential — an operator can point it at a file or a secret manager
    # instead by configuring the tuple directly.
    config :kiln_cms, KilnCMS.Governance.Witness.HTTP,
      url: witness_url,
      token:
        if(System.get_env("KILN_GOVERNANCE_WITNESS_TOKEN"),
          do: {:env, %{"var" => "KILN_GOVERNANCE_WITNESS_TOKEN"}}
        )
  end

  # How often the commitment is refreshed. The exposure window for a truncated
  # chain is one interval wide, so a regulated deployment shortens this
  # ("0 * * * *" for hourly) rather than leaving the nightly default.
  #
  # A plain `:kiln_cms` key rather than a reach into `Oban`'s nested plugin
  # keyword list: `Config` deep-merges those, and overriding one entry of one
  # plugin tuple from here is the #608 shape. `KilnCMS.Application.oban_config/0`
  # assembles the crontab from this.
  if cron = System.get_env("KILN_GOVERNANCE_CHECKPOINT_CRON") do
    config :kiln_cms, :governance_checkpoint_cron, cron
  end
end
