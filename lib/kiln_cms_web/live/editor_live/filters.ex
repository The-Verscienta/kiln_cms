defmodule KilnCMSWeb.EditorLive.Filters do
  @moduledoc """
  The content list's filter state (#1593): read from the URL, written back to
  it, and turned into the query each content type's list runs.

  One map of string values, keyed like the query string, so the URL, a saved
  view's `params` and the form all speak the same shape:

  | Key         | Values                                                    |
  |-------------|-----------------------------------------------------------|
  | `status`    | `all` (default), `draft`, `in_review`, `published`, `archived` |
  | `type`      | `all` (default) or a content type the actor may author   |
  | `q`         | title/slug substring                                      |
  | `author`    | `me` or a user id                                         |
  | `category`  | a category id                                             |
  | `tag`       | a tag id                                                  |
  | `locale`    | one of the configured locales                             |
  | `from`/`to` | ISO dates, an inclusive range on the last update          |
  | `health`    | `due` (due or overdue for review), `due_soon`, `expired`  |
  | `scheduled` | `1`: a publish date is set and it is not live yet         |
  | `sort`      | `updated` (default), `published`, `title`                 |

  Every value is checked against what it can be. Anything else reads as
  absent, so a hand-edited link or a saved view whose category was deleted
  narrows less instead of failing.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS.SavedView
  alias KilnCMSWeb.Params

  @statuses ~w(all draft in_review published archived)
  @healths ~w(due due_soon expired)
  @sorts ~w(updated published title)

  @defaults %{
    "status" => "all",
    "type" => "all",
    "q" => "",
    "author" => nil,
    "category" => nil,
    "tag" => nil,
    "locale" => nil,
    "from" => nil,
    "to" => nil,
    "health" => nil,
    "scheduled" => nil,
    "sort" => "updated"
  }

  @typedoc "Filter state: every key in `SavedView.param_keys/0`, a string or `nil`."
  @type t :: %{required(String.t()) => String.t() | nil}

  @doc "The workflow states the status filter offers, `all` first."
  def statuses, do: @statuses

  @doc "The health values the health filter offers."
  def healths, do: @healths

  @doc "The sort orders the list offers."
  def sorts, do: @sorts

  @doc "No filter at all."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc """
  The filter `params` describe. `ctx` carries what a value is checked against:
  `:types` (the type values the actor may author) and `:locales`.
  """
  @spec parse(map(), map()) :: t()
  def parse(params, ctx) when is_map(params) do
    raw = Map.new(SavedView.param_keys(), &{&1, Params.string(params, &1)})

    %{
      "status" => one_of(raw["status"], @statuses, "all"),
      "type" => one_of(raw["type"], ctx.types, "all"),
      "q" => String.trim(raw["q"] || ""),
      "author" => author(raw["author"]),
      "category" => uuid(raw["category"]),
      "tag" => uuid(raw["tag"]),
      "locale" => one_of(raw["locale"], ctx.locales, nil),
      "from" => date(raw["from"]),
      "to" => date(raw["to"]),
      "health" => one_of(raw["health"], @healths, nil),
      "scheduled" => if(raw["scheduled"] == "1", do: "1"),
      "sort" => one_of(raw["sort"], @sorts, "updated")
    }
  end

  def parse(_params, ctx), do: parse(%{}, ctx)

  @doc """
  The query parameters for `filters`: only the keys that differ from the
  default, so the plain list is `/editor` and two equal filters give equal
  maps (which is how a saved view is recognised as the one on screen).
  """
  @spec to_params(t()) :: %{String.t() => String.t()}
  def to_params(filters) do
    for {key, value} <- filters,
        value not in [nil, ""],
        value != Map.get(@defaults, key),
        into: %{},
        do: {key, value}
  end

  @doc "Whether anything narrows or reorders the list."
  @spec active?(t()) :: boolean()
  def active?(filters), do: to_params(filters) != %{}

  @doc "Whether anything narrows the list, ignoring the sort order."
  @spec narrowing?(t()) :: boolean()
  def narrowing?(filters), do: filters |> to_params() |> Map.delete("sort") != %{}

  @doc """
  The Ash `:filter` entries for `filters`, the type aside (the list picks which
  types to read). `actor_id` is what `author=me` means.
  """
  @spec query_filters(t(), Ecto.UUID.t() | nil) :: keyword()
  def query_filters(filters, actor_id) do
    [
      status_filter(filters["status"]),
      search_filter(filters["q"]),
      author_filter(filters["author"], actor_id),
      filters["category"] && expr(category_id == ^filters["category"]),
      filters["tag"] && expr(exists(tags, id == ^filters["tag"])),
      filters["locale"] && expr(locale == ^filters["locale"]),
      from_filter(filters["from"]),
      to_filter(filters["to"]),
      health_filter(filters["health"]),
      filters["scheduled"] &&
        expr(not is_nil(scheduled_at) and state in [:draft, :in_review])
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.map(&{:filter, &1})
  end

  @doc """
  The Ash sort for `filters`. The primary key breaks ties, so keyset paging
  never skips or repeats a row.
  """
  @spec sort(t()) :: keyword()
  def sort(%{"sort" => "published"}), do: [published_at: :desc_nils_last, id: :desc]
  def sort(%{"sort" => "title"}), do: [title: :asc, id: :asc]
  def sort(_filters), do: [updated_at: :desc, id: :desc]

  @doc """
  Whether record `a` comes before record `b` in `filters`' order — the same
  order `sort/1` asks the database for, used to merge the per-type pages.
  """
  @spec before?(t(), map(), map()) :: boolean()
  def before?(%{"sort" => "published"}, a, b) do
    case {a.published_at, b.published_at} do
      {nil, nil} -> a.id >= b.id
      {nil, _} -> false
      {_, nil} -> true
      {x, y} -> desc(DateTime.compare(x, y), a, b)
    end
  end

  def before?(%{"sort" => "title"}, a, b) do
    x = String.downcase(a.title || "")
    y = String.downcase(b.title || "")
    if x == y, do: a.id <= b.id, else: x < y
  end

  def before?(_filters, a, b), do: desc(DateTime.compare(a.updated_at, b.updated_at), a, b)

  defp desc(:gt, _a, _b), do: true
  defp desc(:lt, _a, _b), do: false
  defp desc(:eq, a, b), do: a.id >= b.id

  @doc """
  The built-in views every editor starts with. Not stored: they are filters
  with a name, so there is nothing to rename or delete.
  """
  @spec default_views() :: [%{id: String.t(), name: String.t(), params: map()}]
  def default_views do
    [
      %{id: "all", name: gettext("All content"), params: %{}},
      %{
        id: "my-drafts",
        name: gettext("My drafts"),
        params: %{"status" => "draft", "author" => "me"}
      },
      %{id: "needs-review", name: gettext("Needs review"), params: %{"status" => "in_review"}},
      %{id: "scheduled", name: gettext("Scheduled"), params: %{"scheduled" => "1"}},
      %{id: "review-due", name: gettext("Review due"), params: %{"health" => "due"}}
    ]
  end

  @doc "Human label for a status filter value."
  def status_label("all"), do: gettext("All statuses")
  def status_label("draft"), do: gettext("Draft")
  def status_label("in_review"), do: gettext("In review")
  def status_label("published"), do: gettext("Published")
  def status_label("archived"), do: gettext("Archived")

  @doc "Human label for a health filter value."
  def health_label("due"), do: gettext("Review due")
  def health_label("due_soon"), do: gettext("Review due soon")
  def health_label("expired"), do: gettext("Expired")

  @doc "Human label for a sort order."
  def sort_label("updated"), do: gettext("Last updated")
  def sort_label("published"), do: gettext("Last published")
  def sort_label("title"), do: gettext("Title (A–Z)")

  defp one_of(value, allowed, default), do: if(value in allowed, do: value, else: default)

  defp author("me"), do: "me"
  defp author(value), do: uuid(value)

  defp uuid(nil), do: nil

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp date(nil), do: nil

  defp date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.to_iso8601(date)
      {:error, _} -> nil
    end
  end

  defp status_filter("all"), do: nil
  defp status_filter(status), do: expr(state == ^String.to_existing_atom(status))

  defp search_filter(""), do: nil

  # Case-insensitive title/slug match; %, _ and \ in the input match literally.
  defp search_filter(q) do
    pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"
    expr(ilike(title, ^pattern) or ilike(slug, ^pattern))
  end

  defp author_filter(nil, _actor_id), do: nil
  defp author_filter("me", nil), do: expr(is_nil(author_id) and not is_nil(author_id))
  defp author_filter("me", actor_id), do: expr(author_id == ^actor_id)
  defp author_filter(id, _actor_id), do: expr(author_id == ^id)

  defp from_filter(nil), do: nil

  defp from_filter(iso) do
    from = iso |> Date.from_iso8601!() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    expr(updated_at >= ^from)
  end

  defp to_filter(nil), do: nil

  # Inclusive of the whole `to` day: everything before the next midnight.
  defp to_filter(iso) do
    until = iso |> Date.from_iso8601!() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    expr(updated_at < ^until)
  end

  defp health_filter(nil), do: nil
  defp health_filter("due"), do: expr(health in [:due, :overdue])
  defp health_filter("due_soon"), do: expr(health == :due_soon)
  defp health_filter("expired"), do: expr(health == :expired)
end
