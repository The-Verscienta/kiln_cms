defmodule KilnCMS.CMS.Changes.StampFirstFailure do
  @moduledoc """
  Keeps `first_failed_at` on an `ExternalLink` in step with its outcome (#474).

  Set when a run of failures *starts*, left alone while it continues, cleared
  when the URL answers again. "Failing since Tuesday" is the difference between
  a report an author acts on and a list of URLs with no sense of whether
  anything is getting worse.

  Only `:broken` and `:transient` count. `:undetermined` is the checker
  declining to judge — recording it as the start of a failure would date a
  failure that was never observed, and a later real one would then inherit a
  timestamp from a bot wall.
  """
  use Ash.Resource.Change

  @failing [:broken, :transient]

  @impl true
  def change(changeset, _opts, _context) do
    outcome = Ash.Changeset.get_attribute(changeset, :outcome)

    cond do
      outcome in @failing and is_nil(changeset.data.first_failed_at) ->
        Ash.Changeset.force_change_attribute(changeset, :first_failed_at, DateTime.utc_now())

      outcome in @failing ->
        changeset

      true ->
        Ash.Changeset.force_change_attribute(changeset, :first_failed_at, nil)
    end
  end
end
