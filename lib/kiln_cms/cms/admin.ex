defmodule KilnCMS.CMS.Admin do
  @moduledoc """
  Small helpers for the AshAdmin content views (issue #25).

  Referenced from the `admin do ... end` blocks on the content resources via
  `format_fields` MFAs — kept here so the formatting is shared and nil-safe
  (AshAdmin calls the formatter even for `nil` timestamps).
  """

  @doc """
  Render a datetime as a compact `YYYY-MM-DD HH:MM (UTC)` string for the admin
  datatable / show views. Returns an empty string for `nil` (e.g. an unpublished
  record's `published_at`) so the column reads blank rather than crashing.
  """
  def format_datetime(nil), do: ""

  def format_datetime(%struct{} = datetime)
      when struct in [DateTime, NaiveDateTime] do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  def format_datetime(other), do: to_string(other)
end
