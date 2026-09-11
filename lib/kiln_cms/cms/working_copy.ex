defmodule KilnCMS.CMS.WorkingCopy do
  @moduledoc """
  The working copy of a live document (docs/working-copy.md).

  A published record keeps two texts: the one readers get — `title` and
  `blocks`, the columns every delivery read serves — and the one the editor is
  typing into, held on the same row in `working_title` / `working_blocks` and
  stamped by `working_copy_at`. Only those two fields split; tags, slug,
  scheduling and every other setting stay single-state and go live on Save.

  The invariant the three columns keep: **they are set only while the record is
  published.** `:save_working_copy` refuses any other state at the row,
  `:publish_changes` and `:discard_changes` clear them, and the retiring
  transitions (`:unpublish`, `:archive` and their scheduled twins) fold the
  working text into the row before leaving `:published` — so a draft never
  carries a stale shadow of itself.

  This module is the one place that reads the pair back: `view/1` is what the
  editor and the signed-in preview render, and `pending?/1` is what the
  "Live · draft" pill, the content list's *edited since publishing* marker and
  a release's readiness verdict all ask.
  """

  @typedoc "Any content record — `KilnCMS.CMS.Page`, `Post`, `Entry` or a project type."
  @type content :: struct()

  @doc """
  Whether `record` is live with edits that have not been published yet.

  `false` for anything not published, whatever the columns hold — see the
  invariant in the moduledoc.
  """
  @spec pending?(content() | nil) :: boolean()
  def pending?(%{state: :published, working_copy_at: %DateTime{}}), do: true
  def pending?(_record), do: false

  @doc """
  The record as the editor should see it: the working copy's title and blocks
  laid over the live row when one is pending, the row itself otherwise.

  Everything else on the struct — state, lock version, slug, settings — is the
  live row's, which is what the caller is about to save against.
  """
  @spec view(content()) :: content()
  def view(record) do
    if pending?(record) do
      %{record | title: record.working_title, blocks: record.working_blocks || []}
    else
      record
    end
  end

  @doc """
  The text the working copy is measured against: the previous working copy when
  one is pending, else the published text. What "runs ahead" means, and what a
  field grant or block policy judges a working-copy write against.
  """
  @spec basis(content()) :: %{title: String.t() | nil, blocks: list()}
  def basis(record) do
    if pending?(record) do
      %{title: record.working_title, blocks: record.working_blocks || []}
    else
      %{title: record.title, blocks: record.blocks || []}
    end
  end

  @doc """
  Whether two block trees carry the same content.

  Compared as the data layer would store them (`Ash.Type.dump_to_native/3`),
  not as structs: a tree loaded from the row and one cast from the editor's
  params differ in Ecto metadata (`:loaded` against `:built`) and nothing else,
  and the whole point of asking is to ignore exactly that.
  """
  @spec same_blocks?(module(), list() | nil, list() | nil) :: boolean()
  def same_blocks?(resource, left, right) do
    dump(resource, left) == dump(resource, right)
  end

  defp dump(resource, blocks) do
    attribute = Ash.Resource.Info.attribute(resource, :blocks)

    case Ash.Type.dump_to_native(attribute.type, List.wrap(blocks), attribute.constraints) do
      {:ok, dumped} -> dumped
      _error -> List.wrap(blocks)
    end
  end
end
