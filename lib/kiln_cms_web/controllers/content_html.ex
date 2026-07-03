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
end
