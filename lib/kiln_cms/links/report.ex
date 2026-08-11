defmodule KilnCMS.Links.Report do
  @moduledoc """
  The site-wide broken-link report (#474).

  Reads `KilnCMS.CMS.ExternalLink` and shapes it for the one question the page
  asks: *what is broken, and where do I go to fix it?*

  ## Grouped by URL, because that is the unit of work

  The stored grain is `{document, url}`, but an author fixing a dead link fixes
  the link once and then visits every page that cites it. So the report inverts
  the storage: one row per URL, each carrying the documents to open. A flat list
  of occurrences would show the same dead URL nine times and make nine problems
  out of one.

  ## Only `:broken` is shown

  `:transient` and `:undetermined` are recorded (see `KilnCMS.Links.External`)
  and deliberately not surfaced. A "might be broken" column is a column authors
  learn to ignore, and it takes the real one with it. They are counted, though,
  because "nothing is broken" and "nothing has been checked" must not look the
  same on this page.

  ## Bounded

  A site that has just switched checking on after years of link rot can have
  thousands of broken occurrences, and this renders in a LiveView. Rows are
  capped and the report says when it truncated, rather than paginating a list
  whose sensible length is zero.
  """

  require Ash.Query

  alias KilnCMS.CMS.ExternalLink
  alias KilnCMS.Links.Settings

  # Occurrences loaded, not URLs — the cap has to bound what is read, and how
  # many distinct URLs that turns out to be is not known until after the read.
  @row_cap 1_000

  @type document :: %{
          type: String.t(),
          id: Ash.UUID.t(),
          title: String.t() | nil,
          block_index: non_neg_integer() | nil
        }

  @type entry :: %{
          url: String.t(),
          host: String.t() | nil,
          status_code: integer() | nil,
          reason: String.t() | nil,
          first_failed_at: DateTime.t() | nil,
          last_checked_at: DateTime.t() | nil,
          documents: [document()]
        }

  @type t :: %{
          enabled?: boolean(),
          last_swept_at: DateTime.t() | nil,
          counts: %{atom() => non_neg_integer()},
          broken: [entry()],
          truncated?: boolean()
        }

  @doc "Everything `/editor/links` renders for one site."
  @spec for_org(Ash.UUID.t()) :: t()
  def for_org(org_id) do
    settings = Settings.for_org(org_id)
    rows = broken_rows(org_id)

    %{
      enabled?: !!(settings && settings.external_enabled),
      last_swept_at: settings && settings.last_swept_at,
      counts: counts(org_id),
      broken: group(rows),
      truncated?: length(rows) >= @row_cap
    }
  end

  defp broken_rows(org_id) do
    ExternalLink
    |> Ash.Query.filter(outcome == :broken)
    |> Ash.Query.sort(first_failed_at: :asc)
    |> Ash.Query.limit(@row_cap)
    |> Ash.read!(authorize?: false, tenant: org_id)
  end

  # Counted rather than tallied from a read: the whole table is the thing being
  # summarized, and loading it to count it is what the count exists to avoid.
  defp counts(org_id) do
    Map.new([:ok, :broken, :pending, :transient, :undetermined], fn value ->
      {value,
       ExternalLink
       |> Ash.Query.filter(outcome == ^value)
       |> Ash.count!(authorize?: false, tenant: org_id)}
    end)
  end

  # Most-cited first: a dead URL on nine pages is nine pages of broken reading,
  # and it is also the fix with the best return.
  defp group(rows) do
    rows
    |> Enum.group_by(& &1.url_digest)
    |> Enum.map(fn {_digest, [first | _rest] = occurrences} -> entry(first, occurrences) end)
    |> Enum.sort_by(&{-length(&1.documents), &1.url})
  end

  defp entry(first, occurrences) do
    %{
      url: first.url,
      host: first.host,
      status_code: first.status_code,
      reason: first.reason,
      first_failed_at: first.first_failed_at,
      last_checked_at: first.last_checked_at,
      documents:
        occurrences
        |> Enum.map(
          &%{
            type: &1.document_type,
            id: &1.document_id,
            title: &1.document_title,
            block_index: &1.block_index
          }
        )
        |> Enum.sort_by(&(&1.title || ""))
    }
  end

  @doc "How many occurrences the report will load before it truncates."
  @spec row_cap() :: pos_integer()
  def row_cap, do: @row_cap
end
