defmodule KilnCMS.CMS.Changes.PairAppIcon do
  @moduledoc """
  Keeps `app_icon_size` describing the `app_icon_url` it was measured from
  (#629).

  `app_icon_size` is not accepted as an attribute. It arrives as the
  `:app_icon_size` **argument**, and this change is the only thing that writes
  the column — so the two can only ever be set by one write, together.

  ## Why a change and not `upsert_fields`

  The `:save` action lists both columns in `upsert_fields`, and that reads like
  it pairs them. It does not: AshPostgres filters `upsert_fields` down to the
  attributes actually present in the changeset
  (`upsert_set/4` — `Enum.filter(&(&1 in attributes_changing_anywhere))`), so a
  write that supplies only the URL simply omits the size from the `ON CONFLICT
  … SET` clause and the previous measurement survives underneath the new icon.

  ## Why a change and not a validation

  The rule is not "reject the write" — an operator changing their icon should
  not have their save fail. It is "a size only survives alongside the URL it
  measured", so the fallback direction is **clear the size**. A missing size
  means the manifest serves the stock icons, which is the safe state:
  `icons[].sizes` is a declaration Chromium's installability check believes, and
  a wrong one removes the install prompt outright instead of degrading.

  ## Why not verify here

  Measuring means an HTTP fetch, and a change runs inside the write
  transaction. Holding a Postgres transaction open across a network round trip
  to an operator-supplied host is the wrong trade at any timeout. The caller
  measures first (`KilnCMS.Branding.AppIcon.verify/1`) and passes the result as
  the argument; this change makes it impossible for that result to outlive the
  URL it describes.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    url = Ash.Changeset.get_attribute(changeset, :app_icon_url)
    size = Ash.Changeset.get_argument(changeset, :app_icon_size)

    changeset
    |> Ash.Changeset.force_change_attribute(:app_icon_size, size_for(url, size))
    # A settings save is a fresh measurement attempt — do not let a prior
    # nightly streak survive underneath a successful (or freshly failed) save.
    |> Ash.Changeset.force_change_attribute(:app_icon_verify_failures, 0)
  end

  # No icon, no measurement to keep. Covers both "cleared it" and "never set
  # one": a size with no URL is a claim about nothing, and the next icon would
  # inherit it.
  defp size_for(url, _size) when url in [nil, ""], do: nil

  # A measurement is only trusted when the caller measured *this* write's URL.
  # Absent argument -> the writer did not measure -> stock icons.
  defp size_for(_url, size) when is_integer(size) and size > 0, do: size
  defp size_for(_url, _size), do: nil
end
