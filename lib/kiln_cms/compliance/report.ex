defmodule KilnCMS.Compliance.Report do
  @moduledoc """
  What claims are live on this site right now (#858).

  #377 shipped claim checking into two places that are both about the document
  in front of you — the editor's panel, and the publish gate's refusal — and
  neither is a *record*. The question a compliance officer has is the other one:
  not "does this draft say something risky" but "what is currently published in
  our name". Nothing could answer it, which is what #352's dashboard was
  supposed to be for.

  ## Recomputed, not stored

  The scan runs when the page is read. There is no findings table and nothing is
  written on publish, which is a deliberate trade and worth stating because the
  alternative is the more obvious one:

    * It answers "what is live now" exactly, which is the question asked, and it
      cannot answer "what did this page claim in March". Point-in-time history
      already exists next door (`KilnCMS.Governance`), and a claim scan of a
      restored version is the honest way to get that answer if it is ever
      wanted — rather than a second store that can disagree with the document.
    * A stored finding would need writing on publish, and
      `KilnCMS.CMS.Changes.AutoCompleteTasks` force-completes every open task on
      `:publish`/`:publish_scheduled`. A compliance record that arrived through
      a task would be closed by the very publish it was meant to gate. #858
      flags that hazard; not writing on publish is how this avoids it entirely.
    * The rules are per site and editable (#857). A stored finding is a claim
      about a vocabulary that may since have changed; a recomputed one is always
      judged by the rules in force now, which is what an officer reading the
      page assumes they are seeing.

  The cost is a scan per page load. It is bounded by `@document_cap` and the
  scan itself is a regex fold over text the site already stores — the same work
  the editor does per keystroke, for one document at a time.

  ## Published only

  Drafts are excluded, and that is the point rather than an optimisation: a
  draft claim is the editor panel's business and the publish gate's, both of
  which already run. What is published is what the site is saying.

  ## Every field on its own

  Segments are scanned separately and never concatenated, for
  `KilnCMS.CMS.Validations.ComplianceClaims`' reason: joining a body ending
  "at your own risk" to a title beginning "Free consultation" invents the phrase
  "risk free" across the seam, and reports a claim the document does not make.
  """

  require Ash.Query

  alias Kiln.Advisory.Body
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Compliance
  alias KilnCMS.Compliance.Settings

  # The same fields the publish gate scans. Kept in step with
  # `ComplianceClaims`' list deliberately: a report that judged more fields than
  # the gate would flag claims no publish could refuse, and one that judged
  # fewer would call a document clean that the gate would stop.
  @scanned_fields [:title, :seo_title, :seo_description]

  # Bounded like `KilnCMS.Links.Report`'s row cap, and for the same reason: this
  # is a page, not a job, and a site with fifty thousand published documents
  # must not turn one page load into a full-table scan. `truncated?` says so
  # rather than the page quietly describing a subset as the whole.
  @document_cap 500

  @typedoc "One published document that matched at least one rule."
  @type finding :: %{
          type: String.t(),
          id: Ash.UUID.t(),
          title: String.t() | nil,
          slug: String.t() | nil,
          matches: %{atom() => [String.t()]},
          errors?: boolean()
        }

  @typedoc """
  `enabled?` is the site's switch, and `false` is a state the page renders
  rather than an empty list — "no claims found" and "nobody looked" are the same
  picture and opposite facts, which is the lesson `KilnCMS.Links.Report` carries
  in its own moduledoc.
  """
  @type t :: %{
          enabled?: boolean(),
          scanned: non_neg_integer(),
          truncated?: boolean(),
          findings: [finding()]
        }

  @doc """
  Scan this site's published documents for claim matches.

  System-level (`authorize?: false`, tenant-scoped): the caller is
  `KilnCMSWeb.GovernanceLive`, which is already admin-gated, and the alternative
  is a per-document policy check on a page whose whole purpose is the site-wide
  view.
  """
  @spec for_org(Ash.UUID.t()) :: t()
  def for_org(org_id) do
    settings = Settings.for_org(org_id)

    if settings.enabled? do
      documents = published_documents(org_id)

      %{
        enabled?: true,
        scanned: length(documents),
        truncated?: length(documents) >= @document_cap,
        findings: documents |> Enum.flat_map(&finding(&1, settings.rules)) |> sort()
      }
    else
      %{enabled?: false, scanned: 0, truncated?: false, findings: []}
    end
  end

  @doc "How many documents one read will look at before it stops."
  @spec document_cap() :: pos_integer()
  def document_cap, do: @document_cap

  # Errors first, then by title, so the page opens on the rows that would refuse
  # a publish rather than on whatever the database returned first.
  defp sort(findings) do
    Enum.sort_by(findings, fn f -> {not f.errors?, String.downcase(f.title || "")} end)
  end

  defp finding(%{record: record, type: type}, rules) do
    matches =
      record
      |> segments()
      |> Enum.map(&(&1 |> Body.fold() |> Compliance.scan(rules)))
      |> Enum.reduce(%{}, &Compliance.merge/2)

    if matches == %{} do
      []
    else
      [
        %{
          type: type,
          id: record.id,
          title: record.title,
          slug: record.slug,
          matches: matches,
          errors?: Compliance.errors_only(matches, rules) != %{}
        }
      ]
    end
  end

  defp segments(record) do
    fields =
      Enum.map(@scanned_fields, fn field ->
        case Map.get(record, field) do
          text when is_binary(text) -> text
          _other -> ""
        end
      end)

    [Body.compute(Map.get(record, :blocks)).text | fields]
  end

  # Compiled types and dynamic entries both, mirroring
  # `KilnCMS.Governance.content_index/2` — a site whose content is a dynamic
  # type is not a site with nothing to report.
  defp published_documents(org_id) do
    compiled =
      Enum.flat_map(ContentTypes.all(), fn ct ->
        ct.resource
        |> published_query()
        |> Ash.read!(authorize?: false, tenant: org_id)
        |> Enum.map(&%{record: &1, type: to_string(ct.type)})
      end)

    compiled ++ dynamic_documents(org_id)
  end

  defp dynamic_documents(org_id) do
    case ContentTypes.dynamic_all(org_id) do
      [] ->
        []

      descriptors ->
        names = Map.new(descriptors, &{&1.definition.id, &1.type})

        KilnCMS.CMS.Entry
        |> published_query()
        |> Ash.read!(authorize?: false, tenant: org_id)
        |> Enum.flat_map(&entry_document(&1, names))
    end
  end

  # An entry whose definition no longer resolves is dropped, as it is in the
  # governance index: there is no type name to file it under, and inventing one
  # would put a row on the page that links nowhere.
  defp entry_document(record, names) do
    case names[record.type_definition_id] do
      nil -> []
      type -> [%{record: record, type: type}]
    end
  end

  defp published_query(resource) do
    resource
    |> Ash.Query.filter(state == :published)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(@document_cap)
  end
end
