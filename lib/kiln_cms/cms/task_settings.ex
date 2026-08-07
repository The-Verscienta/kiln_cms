defmodule KilnCMS.CMS.TaskSettings do
  @moduledoc """
  The read side of "does publishing complete this task?" (#818).

  Two places can answer, and this module is the only one that knows the order:

    1. The **task**'s own `auto_complete_on_publish`, when it is not `nil`.
    2. The **site**'s `SiteEditorialSettings.auto_complete_tasks_on_publish`.
    3. Failing both, `true` — what #501 shipped unconditionally.

  Nothing outside this module reads either half directly, for the same reason
  `KilnCMS.Links.Settings` exists: **absence is the default**, so a site that
  has never opened the settings page has no row, and resolving that here keeps
  a task list from writing one as a side effect of being rendered.

  ## Why a read failure resolves to "on"

  `KilnCMS.Links.Settings` fails the other way — a database blip there must not
  become outbound HTTP traffic from a site that never asked for any. Here the
  two outcomes are "a done task stays open" and "an open task is closed", and
  neither is dangerous; what matters is which one is *surprising*. Every
  existing install auto-completes, so a transient error that silently stopped
  doing so would look like tasks were being ignored, with nothing to point at.
  Failing to the shipped behaviour is the quieter wrong answer, and it is
  logged.

  ## One read per publish, not one per task

  `auto_complete?/2` takes an already-resolved site default so a publish with
  twelve open tasks reads the settings row once. `site_default/1` is the read;
  `auto_complete?/2` is pure.
  """
  require Logger

  alias KilnCMS.CMS.SiteEditorialSettings
  alias KilnCMS.CMS.Task

  @shipped_default true

  @doc """
  This site's default, or `#{@shipped_default}` when it has never been saved.

  Takes an org id or an `%Organization{}` — the LiveViews hold the struct
  (`socket.assigns.current_org`), and `Ash.ToTenant` accepts either, so a
  version that only handled the id worked on the happy path and raised
  `Protocol.UndefinedError` in the error branch, where the id is interpolated
  into the log line. That is the one branch that exists to keep things running.
  """
  @spec site_default(Ash.UUID.t() | struct()) :: boolean()
  def site_default(org) do
    SiteEditorialSettings
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: org)
    |> case do
      {:ok, %SiteEditorialSettings{auto_complete_tasks_on_publish: value}} ->
        value

      {:ok, nil} ->
        @shipped_default

      {:error, reason} ->
        Logger.warning(
          "editorial settings: could not read auto-complete default for " <>
            "#{inspect(org_id(org))}: #{inspect(reason)}"
        )

        @shipped_default
    end
  end

  defp org_id(%{id: id}), do: id
  defp org_id(org), do: org

  @doc """
  Whether publishing completes `task`, given the site default.

      iex> alias KilnCMS.CMS.TaskSettings
      iex> TaskSettings.auto_complete?(%KilnCMS.CMS.Task{auto_complete_on_publish: false}, true)
      false

      iex> alias KilnCMS.CMS.TaskSettings
      iex> TaskSettings.auto_complete?(%KilnCMS.CMS.Task{auto_complete_on_publish: true}, false)
      true

      iex> alias KilnCMS.CMS.TaskSettings
      iex> TaskSettings.auto_complete?(%KilnCMS.CMS.Task{auto_complete_on_publish: nil}, false)
      false
  """
  @spec auto_complete?(Task.t(), boolean()) :: boolean()
  def auto_complete?(%Task{auto_complete_on_publish: override}, site_default)
      when is_boolean(site_default) do
    case override do
      nil -> site_default
      value when is_boolean(value) -> value
    end
  end

  @doc """
  How a task's setting should read in the UI: the effective answer, and whether
  it came from the task or the site.

  The pair matters because "off" and "off, because the site is set that way" are
  different things to an editor deciding whether to change it.
  """
  @spec describe(Task.t(), boolean()) :: {boolean(), :task | :site}
  def describe(%Task{auto_complete_on_publish: nil}, site_default),
    do: {site_default, :site}

  def describe(%Task{auto_complete_on_publish: override}, _site_default),
    do: {override, :task}
end
