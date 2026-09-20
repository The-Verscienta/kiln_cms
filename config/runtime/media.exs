import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## A/V metadata stripping — fail closed (#820)
#
# An MP4 off a phone carries GPS, device model and a local wall-clock date, and
# Kiln remuxes those away with ffmpeg. ffmpeg is an OPTIONAL dependency, so the
# default is best-effort: no ffmpeg means the file is stored as it arrived and
# a warning is logged.
#
# Set REQUIRE_AV_METADATA_STRIP=true to refuse such an upload instead, which is
# the same contract PDFs already have. Do that only WITH ffmpeg installed —
# on a host without it, every video and audio upload starts failing. Default
# off precisely because flipping it for existing deployments would be that
# outage, silently, on upgrade.
with {:ok, required?} <- Env.fetch("REQUIRE_AV_METADATA_STRIP") do
  config :kiln_cms, :require_av_metadata_strip, required?
end

# KILN_AV_STRIP_MODE=deferred moves the remux off the upload request (#1122):
# the upload is staged to PRIVATE storage as a quarantined item — invisible to
# every non-editor read, a 404 on the download/stream routes — and
# KilnCMS.Media.AVStripWorker strips, promotes and releases it in the
# background. Needs private storage (the Local adapter always has it; S3 needs
# a private bucket), else it falls back to `sync` with a warning. `sync` (the
# default) is the bounded synchronous path #1112 shipped.
# A literal case, not `String.to_existing_atom/1`: this file runs before the
# application's modules are loaded in a release, so the atom may not exist yet.
case Env.one_of("KILN_AV_STRIP_MODE", ~w(sync deferred)) do
  {:ok, "deferred"} -> config :kiln_cms, :av_metadata_strip, :deferred
  {:ok, "sync"} -> config :kiln_cms, :av_metadata_strip, :sync
  _unset_or_unrecognized -> :ok
end

# When the quarantine reaper runs (#1122): quarantined uploads whose strip
# never completed are removed after KILN_MEDIA_QUARANTINE_MAX_AGE_HOURS (24).
# `false` disables the schedule.
if cron = System.get_env("KILN_MEDIA_QUARANTINE_REAPER_CRON") do
  config :kiln_cms, :media_quarantine_reaper_cron, cron
end

with {:ok, hours} <- Env.positive_integer("KILN_MEDIA_QUARANTINE_MAX_AGE_HOURS") do
  config :kiln_cms, :media_quarantine_max_age_hours, hours
end

# ## On-the-fly image transforms (`/media/:id/t/…`)
#
# KILN_IMAGE_TRANSFORM_KEY is the HMAC key for signed transform URLs. Unset,
# Kiln derives one from SECRET_KEY_BASE — enough for its own templates, which
# sign server-side. Set it to let a server-side frontend sign URLs with the
# SDKs (any size, not just the allowlist). It is a secret: it must never reach
# a browser. Refused below 32 characters, because a short key is a guessable
# one and the only thing between a stranger and every render the endpoint can
# be made to do. `mix phx.gen.secret 32` makes one.
case System.get_env("KILN_IMAGE_TRANSFORM_KEY") do
  blank when blank in [nil, ""] ->
    :ok

  key when byte_size(key) >= 32 ->
    config :kiln_cms, :image_transforms, signing_key: key

  _short ->
    raise """
    KILN_IMAGE_TRANSFORM_KEY must be at least 32 characters.

    It signs on-the-fly image transform URLs, so a short key can be guessed and
    then used to request renders of any size. Generate one with
    `mix phx.gen.secret 32`, or unset it to derive a key from SECRET_KEY_BASE.
    """
end

# KILN_IMAGE_TRANSFORM_UNSIGNED=false serves only signed transform URLs. On by
# default: unsigned URLs are held to an allowlist of sizes, ratios and
# qualities, which is what lets a browser build them.
with {:ok, allow?} <- Env.fetch("KILN_IMAGE_TRANSFORM_UNSIGNED") do
  config :kiln_cms, :image_transforms, allow_unsigned: allow?
end

# KILN_IMAGE_TRANSFORM_AUTO_AVIF=true lets `fm_auto` answer AVIF to a browser
# that accepts it. Off by default for the same reason AVIF variants are opt-in:
# an AVIF encode costs roughly ten times a WebP one.
with {:ok, avif?} <- Env.fetch("KILN_IMAGE_TRANSFORM_AUTO_AVIF") do
  config :kiln_cms, :image_transforms, auto_avif: avif?
end
