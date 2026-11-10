defmodule KilnCMSWeb.SecurityPostureJSON do
  @moduledoc """
  The body of `GET /api/security/posture` (#2521): a site's security posture
  for monitoring, built from `KilnCMS.Security.Posture.snapshot/2`'s report.

      {
        "version": 1,
        "generated_at": "2026-11-10T09:00:00Z",
        "org_id": "…",
        "scopes": ["site"],
        "status": "warn",
        "counts": {"fail": 0, "warn": 1, "error": 0, "unknown": 0, "pass": 9, "n_a": 1},
        "checks": [
          {"id": "core.second_factor", "scope": "site", "source": "core", "plugin": null,
           "status": "warn", "title": "…", "summary": "…", "fix_path": "/editor/…",
           "docs_url": "https://…", "facts": {"admins_without": 1}, "error": null}
        ]
      }

  Every field is chosen here, one by one, from the report's structs; none is
  derived from them, so a field added to `Entry` or `Result` stays private
  until it is added here on purpose. A result's `details` (which name people),
  a check's `description`, its duration and its module are never emitted.

  ## The contract

    * **Additive only**, like the `kiln_reporting_v1` views: a field may be
      added, never removed, renamed or retyped. `version` changes only for a
      change that breaks that, and then only alongside a major release.
    * **Open value sets.** `status`, `checks[].status`, `checks[].source`,
      `checks[].scope` and `checks[].error` hold the values listed below
      today, and a later release may add one; so may `counts` gain a key.
      A consumer must tolerate a value or key it does not know (read an
      unknown status as a warning).
    * **Keyed by id.** `checks` is sorted by `id`, but the order is not part
      of the contract: read a check by its `id`. Core check ids (`core.…`)
      and the keys of core checks' `facts` are contract; a plugin's are its
      own.
    * **Human text is not stable.** `title` and `summary` are English
      sentences for a person, and may be reworded in any release; never
      match on them. `fix_path` is a console path relative to the site's
      console host.
    * **`generated_at`** is when the checks ran, which for a cached answer is
      up to 30 seconds ago.

  Values today: `status` `pass` | `warn` | `fail`; `checks[].status` `pass` |
  `warn` | `fail` | `unknown` | `n_a` | `error`; `source` `core` | `plugin` |
  `config` (with `plugin` the plugin's name, otherwise `null`); `scope`
  `site` | `deployment`; `error` `crashed` | `timeout` | `invalid_result` |
  `busy` | `null`.

  Every string passes through `String.replace_invalid/1` (the sanitizer does
  this already; this is a second line for a report built some other way), and
  a fact value that is not `null`, a boolean, a number or a string is `null`.
  """

  alias Kiln.Security.Check.Result
  alias KilnCMS.Security.Posture
  alias KilnCMS.Security.Posture.Entry
  alias KilnCMS.Security.Posture.Report

  @version 1

  @doc "The body's `version`: bumped only for a change that breaks the contract."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The response body for `report`."
  @spec show(%{report: Report.t()}) :: map()
  def show(%{report: %Report{} = report}) do
    %{
      "version" => @version,
      "generated_at" => report.ran_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "org_id" => report.org_id,
      "scopes" => Enum.map(report.scopes, &Atom.to_string/1),
      "status" => Atom.to_string(report.overall),
      "counts" =>
        Map.new(Posture.statuses(), &{Atom.to_string(&1), Map.get(report.counts, &1, 0)}),
      "checks" => report.entries |> Enum.sort_by(& &1.id) |> Enum.map(&check/1)
    }
  end

  defp check(%Entry{} = entry) do
    {source, plugin} = source(entry.source)
    result = entry.result

    %{
      "id" => text(entry.id),
      "scope" => Atom.to_string(entry.scope),
      "source" => source,
      "plugin" => plugin,
      "status" => Atom.to_string(entry.status),
      "title" => text(entry.title),
      "summary" => result_field(result, :summary),
      "fix_path" => result_field(result, :fix_path),
      "docs_url" => result_field(result, :docs_url),
      "facts" => facts(result),
      "error" => entry.error && Atom.to_string(entry.error)
    }
  end

  defp source(:core), do: {"core", nil}
  defp source({:plugin, name}), do: {"plugin", text(name)}
  defp source(:config), do: {"config", nil}

  defp result_field(%Result{} = result, field), do: result |> Map.fetch!(field) |> text()
  defp result_field(nil, _field), do: nil

  defp facts(%Result{facts: facts}) when is_map(facts) do
    Map.new(
      Enum.flat_map(facts, fn {key, value} ->
        case fact_key(key) do
          nil -> []
          name -> [{name, json_value(value)}]
        end
      end)
    )
  end

  defp facts(_result), do: %{}

  defp fact_key(key) when is_binary(key), do: text(key)
  defp fact_key(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp fact_key(_key), do: nil

  defp json_value(value) when is_binary(value), do: text(value)

  defp json_value(value) when is_nil(value) or is_boolean(value) or is_number(value),
    do: value

  defp json_value(_value), do: nil

  defp text(value) when is_binary(value), do: String.replace_invalid(value)
  defp text(nil), do: nil
end
