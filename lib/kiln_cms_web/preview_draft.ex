defmodule KilnCMSWeb.PreviewDraft do
  @moduledoc """
  Loads the record a verified preview grant names, as the routes that render a
  draft by URL need it: `KilnCMSWeb.VisualEditingController` (annotated) and
  `KilnCMSWeb.ArtifactController` under a grant (#1887, plain).

  The grant names the record by id; the URL still has to agree with it on
  everything else it says. The type must be the grant's own (a token for a
  post is no key to a page), and the slug — plus the locale, when the caller
  names one — must be that record's, so a token cannot be replayed under
  another document's URL. The site was pinned when the grant was verified
  (`KilnCMS.CMS.PreviewGrant.verify/2`).

  For a live document with unpublished edits it answers the **working copy**
  (`KilnCMS.CMS.WorkingCopy.load_view/2`), as `GET /preview/:token` does: the
  pending text is what a token is minted to show, and why only an editor with
  draft visibility may mint one.
  """

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewGrant
  alias KilnCMS.CMS.WorkingCopy

  @doc """
  The working-copy view of the record `grant` names, if `ct`, `slug` and
  `locale` (`nil`: any) all describe it. `{:error, :invalid_preview}` otherwise.
  """
  @spec fetch(PreviewGrant.t(), map(), String.t(), String.t() | nil) ::
          {:ok, struct()} | {:error, :invalid_preview}
  def fetch(%PreviewGrant{type: type, id: id, org_id: org_id}, ct, slug, locale) do
    with true <- type == to_string(ct.type),
         # authorize?: false — the caller holds no actor; the grant is the
         # signature `PreviewGrant.verify/2` checked, which binds this read to
         # the ONE record id an editor with draft visibility
         # (`PreviewToken.mint/3`) minted it for. The tenant is the serving
         # org, which the token's `org_id` was pinned to, so the bypassed read
         # cannot reach another site's row.
         {:ok, record} <-
           ContentTypes.get_record(ct, id,
             authorize?: false,
             tenant: org_id,
             load: [:featured_image] ++ KilnCMS.Seo.Patterns.loads()
           ),
         true <- record.slug == slug,
         true <- is_nil(locale) or record.locale == locale do
      # authorize?: false — the verified grant, as on the read above; this
      # re-reads the held featured image of that same record.
      {:ok, WorkingCopy.load_view(record, authorize?: false, tenant: org_id)}
    else
      _ -> {:error, :invalid_preview}
    end
  end
end
