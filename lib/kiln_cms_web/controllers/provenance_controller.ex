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

  All routes 404 when provenance is disabled (`KilnCMS.Provenance.enabled?/0`).
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Delivery
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Provenance

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

  def manifest(conn, params) do
    with_artifact(conn, params, fn record, artifact ->
      case Provenance.manifest_for(artifact, record) do
        {:ok, manifest} ->
          conn
          |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
          |> json(manifest)

        {:error, reason} ->
          unavailable(conn, reason)
      end
    end)
  end

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
      locale = params["locale"] || KilnCMS.I18n.default_locale()
      surface = Map.get(@surfaces, params["surface"] || "json")
      org_id = KilnCMSWeb.Tenant.current_org_id(conn)

      with false <- is_nil(surface),
           ct when not is_nil(ct) <- ContentTypes.get(type),
           {:ok, record} <- Delivery.published(org_id, ct.type, slug, locale),
           {:ok, artifact} <- artifact_row(record, surface) do
        fun.(record, artifact)
      else
        _ -> error(conn, :not_found, "not_found", "No provenance for this content.")
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
    case Firing.get_artifact(type, record.id, surface, authorize?: false, tenant: record.org_id) do
      {:ok, %_{} = artifact} -> {:ok, artifact}
      _ -> :error
    end
  end

  defp disabled(conn),
    do: error(conn, :not_found, "provenance_disabled", "Content provenance is not enabled.")

  defp unavailable(conn, reason) do
    error(
      conn,
      :service_unavailable,
      "provenance_unavailable",
      "Signing key unavailable: #{KilnCMS.Keys.describe_error(reason)}"
    )
  end

  defp error(conn, status, code, detail) do
    conn
    |> put_status(status)
    |> json(%{
      errors: [%{status: to_string(Plug.Conn.Status.code(status)), code: code, detail: detail}]
    })
  end
end
