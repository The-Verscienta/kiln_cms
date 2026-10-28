defmodule KilnCMSWeb.ProvenanceController do
  @moduledoc """
  Public verification surface for signed, provenance-verified content (#340).

  - `GET /api/provenance/:type/:slug?surface=json` — the **detached manifest**:
    a signed hash of the artifact bound to a claim (signer, AI-disclosure,
    origin, version, timestamp). A consumer recomputes the artifact's canonical
    hash, checks it against the manifest, and verifies the signature against the
    published public key — proving the content is unaltered and came from us.
  - `GET /api/provenance/:type/:slug/verify?surface=json` — server-side
    convenience: re-runs that verification against the current artifact and
    returns a verdict plus the attested claim.
  - `GET /api/provenance/public-key` — the signing key's public half (PEM +
    base64 SPKI DER + fingerprint) for offline verification.
  - `GET /api/provenance/verify/:type/:slug?surface=json` (#1929) — the
    served artifact checked against the manifest stored when it was fired:
    `verified`, `tampered`, `unsigned` (nothing was signed) or `unverifiable`
    (signed with a key this instance no longer holds). Anonymous and
    cacheable, and it answers for every published document, signed or not.
    Unlike `…/verify` above, it can fail: that one re-derives the manifest
    from the body it then checks.

  All routes 404 when provenance is disabled (`KilnCMS.Provenance.enabled?/0`).
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Delivery
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Provenance
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params

  @surfaces KilnCMS.Firing.Surfaces.name_map()
  @max_age_seconds 300

  def public_key(conn, _params) do
    if Provenance.enabled?() do
      case Provenance.Signer.public_key_info() do
        {:ok, info} ->
          conn
          |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
          |> json(info)

        {:error, reason} ->
          unavailable(conn, reason)
      end
    else
      disabled(conn)
    end
  end

  # The manifest stored at fire time when there is one (#1929). An artifact
  # fired before 1.7 has none and gets one derived from its body, as before.
  def manifest(conn, params) do
    with_artifact(conn, params, fn record, artifact ->
      case stored_or_derived(artifact, record) do
        {:ok, manifest} ->
          conn
          |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
          |> json(manifest)

        {:error, reason} ->
          unavailable(conn, reason)
      end
    end)
  end

  # Short: a re-fire replaces the artifact and its manifest, and a verdict
  # should not outlive the body it describes by long.
  @status_max_age_seconds 60

  def status(conn, params) do
    with_artifact(conn, params, fn record, artifact ->
      {status, result} = Provenance.verdict(artifact)
      manifest = artifact.manifest || %{}

      conn
      |> put_resp_header("cache-control", "public, max-age=#{@status_max_age_seconds}")
      |> json(%{
        "status" => Atom.to_string(status),
        "type" => Engine.public_type(record),
        "slug" => record.slug,
        "locale" => record.locale,
        "surface" => Atom.to_string(artifact.surface),
        "version" => artifact.source_version_id,
        "fired_at" => artifact.fired_at,
        "key_id" => get_in(manifest, ["signature", "key_id"]),
        "unaltered" => result && result["unaltered"],
        "authentic" => result && result["authentic"],
        "claim" => manifest["claim"]
      })
    end)
  end

  defp stored_or_derived(%{manifest: %{} = manifest}, _record), do: {:ok, manifest}
  defp stored_or_derived(artifact, record), do: Provenance.manifest_for(artifact, record)

  def verify(conn, params) do
    with_artifact(conn, params, fn record, artifact ->
      with {:ok, manifest} <- Provenance.manifest_for(artifact, record),
           {:ok, verdict} <- Provenance.verify(manifest, artifact.body) do
        json(conn, verdict)
      else
        {:error, reason} -> unavailable(conn, reason)
      end
    end)
  end

  # Resolve the published record + its fired artifact row, then hand both to
  # `fun`. Mirrors ArtifactController's lookup, but reads the artifact *row*
  # (not just the body) since the manifest needs `fired_at`/`source_version_id`.
  defp with_artifact(conn, %{"type" => type, "slug" => slug} = params, fun) do
    if Provenance.enabled?() do
      locale = Params.string(params, "locale", KilnCMS.I18n.default_locale())
      surface = Map.get(@surfaces, params["surface"] || "json")
      org_id = KilnCMSWeb.Tenant.current_org_id(conn)

      with false <- is_nil(surface),
           ct when not is_nil(ct) <- ContentTypes.get(type),
           {:ok, record} <- Delivery.published(org_id, ct.type, slug, locale),
           {:ok, artifact} <- artifact_row(record, surface) do
        fun.(record, artifact)
      else
        _ -> ApiError.send(conn, :not_found, "not_found", "No provenance for this content.")
      end
    else
      disabled(conn)
    end
  end

  # The manifest needs the artifact *row* (`fired_at`/`source_version_id`), not
  # just the body Delivery.read_artifact returns, so read the row here.
  defp artifact_row(record, surface) do
    type = Engine.document_type(record)

    # `record.org_id` is the request tenant (resolved through Delivery.published/4).
    #
    # authorize?: false — no actor on this public endpoint, and the artifact's
    # read policy (`DocumentReadable`) re-asks a question already answered —
    # `record` came back from the published, public-audience delivery read, so
    # this is the artifact of a document the anonymous reader may see; `tenant:`
    # and the `record.id` argument pin it to that one row.
    case Firing.get_artifact(type, record.id, surface, authorize?: false, tenant: record.org_id) do
      {:ok, %_{} = artifact} ->
        # The third artifact reader, and it migrates like the other two (#615).
        # Without this, a document read only through provenance never converges:
        # its manifest would keep attesting to an old shape while /api/content
        # serves the new one for the same document. The manifest returned by THIS
        # request still describes the body just read, which is the body currently
        # served — the re-fire lands behind it, as on the delivery path.
        Engine.migrate_if_stale(record.org_id, type, record.id, artifact)
        {:ok, artifact}

      _ ->
        :error
    end
  end

  defp disabled(conn),
    do:
      ApiError.send(conn, :not_found, "provenance_disabled", "Content provenance is not enabled.")

  defp unavailable(conn, reason) do
    ApiError.send(
      conn,
      :service_unavailable,
      "provenance_unavailable",
      "Signing key unavailable: #{KilnCMS.Keys.describe_error(reason)}"
    )
  end
end
