import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Signed provenance / C2PA-style content manifests (#340)
#
# `KilnCMS.Provenance` was configured in `config/config.exs` alone, which is
# compile time — so on a prebuilt image the only settable knob was the default
# `KILN_PROVENANCE_PRIVATE_KEY` binding, and `enabled`, a file-mounted signing
# key and `retired_keys` all needed a source edit and a rebuild (#608). Each of
# those is something the docs tell operators to do, so each gets a var here.
#
# Skipped under :test for the same reason as KILN_AUDIT_ANCHOR_EVERY_WRITE
# above: whether provenance is on decides between a 404 and a signed manifest on
# every /api/provenance/* route, and the suite must not depend on what happens
# to be exported in the developer's shell. The provenance tests drive the config
# explicitly instead.
if config_env() != :test do
  # Whether manifests are produced at all. The compiled default is `false` and
  # there was no runtime override, so every /api/provenance/* route 404s on a
  # released image no matter what key the operator configures — they set the
  # key, get signed anchors, and then get a 404 from the endpoint the docs point
  # them at, with nothing to change.
  #
  # `Env.fetch/1` rather than a sixth bespoke parser (#607): unset and
  # unrecognized both leave the compiled default alone, which matters in both
  # directions here — a deployment publishing manifests to consumers must not
  # stop because someone wrote `On`, and one that has never enabled provenance
  # must not start signing because of a typo.
  with {:ok, provenance?} <- Env.fetch("KILN_PROVENANCE_ENABLED") do
    config :kiln_cms, KilnCMS.Provenance, enabled: provenance?
  end

  # ActivityPub federation (#491). The deployment-wide half of a two-part gate:
  # off here means every federation route 404s regardless of what any tenant
  # admin has enabled. Federation makes this server sign and POST to hosts
  # chosen by strangers who followed the site, so an operator whose egress
  # policy forbids that must be able to say so once, centrally.
  #
  # `Env.fetch/1` for the same reason as above (#607): unset and unrecognized
  # both leave the compiled default (off) alone.
  with {:ok, federation?} <- Env.fetch("KILN_FEDERATION_ENABLED") do
    config :kiln_cms, KilnCMS.Federation, enabled: federation?
  end

  # Content experiments / A/B testing (#499). OFF by default, and the deployment
  # gets a say because serving an experiment costs its page the SHARED CACHE: a
  # variant render is `private, no-store`, since a CDN would otherwise cache one
  # arm and hand it to every visitor — a 100/0 split reported as 50/50. An
  # operator fronting Kiln with a CDN should decide that once, centrally, rather
  # than discover it from a cache-hit graph.
  with {:ok, experiments?} <- Env.fetch("KILN_EXPERIMENTS_ENABLED") do
    config :kiln_cms, KilnCMS.Experiments, enabled: experiments?
  end

  # Sticky assignment (#984). A SECOND decision, and separate from the one above
  # on purpose: enabling experiments changes caching, enabling this puts a
  # cookie on visitors of experimented pages. `docs/data-flows.md` states that
  # no visitor cookie is recorded, and this is the one switch that makes that
  # untrue — so it is not something the experiments switch should turn on as a
  # side effect. See docs/data-flows.md#sticky-assignment-cookie-984.
  with {:ok, sticky?} <- Env.fetch("KILN_EXPERIMENTS_STICKY") do
    config :kiln_cms, KilnCMS.Experiments, sticky: sticky?
  end

  # Deep-merges with the two `config` calls above (`Config` merges successive
  # calls for the same key rather than overwriting them) — see #608.
  with {:ok, sticky_days} <- Env.positive_integer("KILN_EXPERIMENTS_STICKY_DAYS") do
    config :kiln_cms, KilnCMS.Experiments, sticky_max_age_days: sticky_days
  end

  # Mount the signing key as a file instead of exporting it. The key is a
  # multi-line PKCS#1 PEM and most .env parsers (docker-compose included) do not
  # carry embedded newlines, so a file is the route .env.example already
  # recommends — it just had no way to say so without editing config.
  #
  # Overrides the compiled `{:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}`
  # default when set, so an operator migrating from the env var can mount the
  # file first and unset the var afterwards.
  provenance_key_file = "KILN_PROVENANCE_KEY_FILE" |> System.get_env("") |> String.trim()

  if provenance_key_file != "" do
    config :kiln_cms, KilnCMS.Provenance, signing_key: {:file, %{"path" => provenance_key_file}}
  end

  # Public halves of keys that no longer sign but must still VERIFY — a
  # comma-separated list of PEM paths. Manifests (#340) and history anchors
  # (#356) record the key_id that signed them, so without this a rotation blinds
  # everything signed before it, and the outgoing private half cannot safely be
  # destroyed.
  #
  # Writes :retired_key_files (paths), NOT :retired_keys (provider tuples), and
  # KeyRegistry.retired/0 unions the two. A list of `{:file, %{…}}` tuples is a
  # keyword list, and Config deep-merges keyword lists — so writing :retired_keys
  # here would Keyword.merge into any :retired_keys set in source and silently
  # delete every :file entry already there. Losing a verification key is the one
  # outcome this must never produce. :retired_key_files is the runtime channel
  # and this is its only writer; source config belongs in :retired_keys.
  # See KilnCMS.Provenance.KeyRegistry.
  #
  # A value that parses to NO paths warns and writes nothing rather than writing
  # `[]`. `KILN_PROVENANCE_RETIRED_KEY_FILES=","` — or a shell expanding an unset
  # variable into a bare separator — otherwise clears the list, and silently
  # deregistering every retired key is precisely the failure this feature exists
  # to prevent.
  retired_key_files_raw = System.get_env("KILN_PROVENANCE_RETIRED_KEY_FILES", "")
  retired_key_files = String.trim(retired_key_files_raw)

  case KilnCMS.Provenance.parse_key_files(retired_key_files) do
    [] when retired_key_files != "" ->
      # Collected rather than stderr-only, for the same reason as the
      # disclosure below (#912) — and the RAW value, because with
      # `KILN_PROVENANCE_RETIRED_KEY_FILES=" , "` the trimmed form is `","`, a
      # string that appears nowhere in the operator's compose file.
      #
      # `record_unusable/3`, not a reader: the failure here is "parsed to no
      # paths", which is not a shape `Env` models.
      Env.record_unusable(
        "KILN_PROVENANCE_RETIRED_KEY_FILES",
        retired_key_files_raw,
        "a comma-separated list of PEM file paths"
      )

    [] ->
      :ok

    paths ->
      config :kiln_cms, KilnCMS.Provenance, retired_key_files: paths
  end
end
