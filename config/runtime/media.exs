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
