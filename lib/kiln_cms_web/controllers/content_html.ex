defmodule KilnCMSWeb.ContentHTML do
  @moduledoc """
  Templates for the public content delivery frontend (`ContentController`).
  """
  use KilnCMSWeb, :html

  alias KilnCMSWeb.BlockComponents

  embed_templates "content_html/*"

  @doc """
  The `sizes` a top-level image block renders with on this site.

  The `:monograph` theme bleeds a top-level image to the viewport edges, so
  its images declare `100vw`; left at the reading-column default, the browser
  would fetch a candidate for a 768px slot and upscale it across the screen.
  Every other preset keeps images inside the column. `Branding.for_org/1` is
  cached, and the layout has already resolved it for this request.
  """
  def image_sizes(org) do
    case KilnCMS.Branding.for_org(org).theme do
      :monograph -> "100vw"
      _column -> BlockComponents.column_image_sizes()
    end
  end

  @doc """
  The public byline of a document (#2044): the people its flagged
  `:reference` fields name (`KilnCMS.Firing.Bylines`), each linked to their
  profile — "By Ada Lovelace and Grace Hopper · With Alan Turing".

  `fallback` names the author when the byline names none: the console user,
  on the templates that always showed one. The same rule as the page's
  JSON-LD (`KilnCMSWeb.StructuredData.build/4`). Renders nothing when there
  is no one to name.
  """
  attr :bylines, :map, default: %{}
  attr :fallback, :string, default: nil

  def byline(assigns) do
    assigns =
      assign(
        assigns,
        :fallback,
        if(blank?(assigns.bylines[:author]), do: present(assigns.fallback))
      )

    ~H"""
    <span :if={@bylines[:author]} class="public-byline">
      {gettext("By")} <.people people={@bylines[:author]} />
    </span>
    <span :if={@fallback} class="public-byline">
      {gettext("By %{author}", author: @fallback)}
    </span>
    <span :if={(@bylines[:author] || @fallback) && @bylines[:contributor]}>·</span>
    <span :if={@bylines[:contributor]} class="public-byline">
      {gettext("With")} <.people people={@bylines[:contributor]} />
    </span>
    """
  end

  @doc "Whether `byline/1` would render anything for these assigns."
  @spec byline?(map() | nil, String.t() | nil) :: boolean()
  def byline?(bylines, fallback),
    do:
      not blank?((bylines || %{})[:author]) or not blank?((bylines || %{})[:contributor]) or
        not is_nil(present(fallback))

  attr :people, :list, required: true

  defp people(assigns) do
    assigns = assign(assigns, :last, length(assigns.people) - 1)

    ~H"""
    <%= for {person, index} <- Enum.with_index(@people) do %>
      <.link :if={person.url} href={person.url} class="public-byline-name">{person.name}</.link><span
        :if={!person.url}
        class="public-byline-name"
      >{person.name}</span>{separator(index, @last)}
    <% end %>
    """
  end

  # "A", "A and B", "A, B and C".
  defp separator(index, last) when index == last, do: ""
  defp separator(index, last) when index == last - 1, do: " " <> gettext("and") <> " "
  defp separator(_index, _last), do: ", "

  defp blank?(value), do: value in [nil, []]

  defp present(name) when is_binary(name) and name != "", do: name
  defp present(_name), do: nil

  @doc """
  The line under a page hit on `/search` (#1766): the search highlight — why
  it matched, escaped except for its `<mark>` tags — or, when the match gave
  none, the page's meta description. `nil` when there is neither.
  """
  def search_snippet(%{highlight: highlight}) when is_binary(highlight) and highlight != "",
    do: KilnCMS.Search.Highlight.to_safe_html(highlight)

  def search_snippet(%{seo_description: description})
      when is_binary(description) and description != "",
      do: description

  def search_snippet(_record), do: nil

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
