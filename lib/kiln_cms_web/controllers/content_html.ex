defmodule KilnCMSWeb.ContentHTML do
  @moduledoc """
  Templates for the public content delivery frontend (`ContentController`).
  """
  use KilnCMSWeb, :html

  alias KilnCMSWeb.BlockComponents

  embed_templates "content_html/*"

  @doc """
  Long-form published date, localized: the format string and month names both
  flow through gettext (`Calendar.strftime`'s `%B` is English-only), so
  `/fr/blog/…` can render "2 juillet 2026" instead of "July 2, 2026".
  """
  def published_on(datetime) do
    Calendar.strftime(datetime, gettext("%B %-d, %Y"), month_names: &month_name/1)
  end

  defp month_name(1), do: gettext("January")
  defp month_name(2), do: gettext("February")
  defp month_name(3), do: gettext("March")
  defp month_name(4), do: gettext("April")
  defp month_name(5), do: gettext("May")
  defp month_name(6), do: gettext("June")
  defp month_name(7), do: gettext("July")
  defp month_name(8), do: gettext("August")
  defp month_name(9), do: gettext("September")
  defp month_name(10), do: gettext("October")
  defp month_name(11), do: gettext("November")
  defp month_name(12), do: gettext("December")

  @doc """
  An occurrence's date, in the event's **own** timezone (#766).

  Not the reader's and not the server's: "doors at 19:00" is a fact about the
  clock at the venue, so a listing that rendered it in UTC would advertise a
  20:00 gig as being at 18:00 for half the year. `KilnCMS.Events.Index` and
  `KilnCMS.CMS.FieldTypes.DatetimeRange` both have the long version.

  An all-day occurrence drops the time entirely — that is what all-day means,
  and printing `00:00` for it is how a banner event becomes a midnight one.
  """
  def occurrence_on(%{starts_at: starts_at, time_zone: zone, all_day?: all_day?}) do
    local =
      case DateTime.shift_zone(starts_at, zone) do
        {:ok, shifted} -> shifted
        # An unknown zone name is not worth a 500 on a public index: fall back
        # to the stored instant, which is at least the right moment.
        _error -> starts_at
      end

    if all_day? do
      published_on(local)
    else
      # `%H:%M` needs no localization; the date half already flows through
      # `published_on/1`, month names and all.
      published_on(local) <> " · " <> Calendar.strftime(local, "%H:%M")
    end
  end

  @doc """
  A pagination href that carries the active window (#766).

  `?from=`/`?until=` are dropped from page two otherwise, so "Later" would page
  through a *different, unfiltered* listing while looking like the same one.
  `page` is 1-based, and page one carries no `page` parameter at all.
  """
  def page_href(base_path, window, page) do
    query = window ++ if(page > 1, do: [{"page", to_string(page)}], else: [])

    case query do
      [] -> base_path
      pairs -> base_path <> "?" <> URI.encode_query(pairs)
    end
  end
end
