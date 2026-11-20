defmodule KilnCMSWeb.PluginHealthJSON do
  @moduledoc """
  The body of `GET /api/security/plugin-health` (#2571): the installed
  plugins' health for monitoring, built from the report
  `Kiln.Plugins.Health.cached/0` holds on the node that answered.

      {
        "version": 1,
        "state": "fresh",
        "checked_at": "2026-11-19T09:00:00Z",
        "notices": "ok",
        "counts": {"fail": 0, "warn": 1, "unknown": 0, "unverifiable": 1,
                   "not_applicable": 1, "ok": 0},
        "plugins": [
          {"id": "MyPlugin", "name": "my_plugin", "source": "hex",
           "package": "my_plugin", "version": "1.2.0", "latest_version": "1.3.0",
           "overall": "warn",
           "integrity": {"status": "ok", "reason": null},
           "notices": {"complete": true, "items": [
             {"id": "GHSA-…", "aliases": ["CVE-…"], "severity": "medium",
              "source": "kiln", "url": "https://…"}]},
           "abandonment": {"known": true, "reasons": [
             {"kind": "stale", "retirement": null,
              "last_release_at": "2024-01-01T00:00:00Z",
              "requirement": null, "bundled": null}]}}
        ]
      }

  Every field is chosen here, one by one, from the report's structs; none is
  derived from them, so a field added to `Kiln.Plugins.Health.PluginStatus`
  or `Kiln.Plugins.Health.Notice` stays private until it is added here on
  purpose. Never emitted: a Hex retirement's message, a notice's title,
  affected and patched ranges, the locked and registry checksums, the git
  ref, the plugin's `kiln_plugin` requirement as declared, any sentence
  written for a person, a site id or the node's name.

  ## The contract

    * **Additive only**, like the `kiln_reporting_v1` views: a field may be
      added, never removed, renamed or retyped. `version` changes only for a
      change that breaks that, and then only alongside a major release.
    * **Open value sets.** Every string value listed below may gain a value
      in a later release, and `counts` may gain a key. A consumer must
      tolerate a value or key it does not know, and read an unknown status as
      unknown, never as OK.
    * **Keyed by `id`.** `id` is the plugin's module (`MyApp.MyPlugin`, no
      `Elixir.` prefix) and is unique; `name` is the plugin's own and may
      repeat. `plugins` is sorted by `name`, then `id`, but the order is not
      part of the contract.
    * **`state` decides how to read the rest.** An empty `plugins` is never
      "all clean": `not_checked` means this node holds no fresh check (this
      endpoint never starts one; nothing is fetched until a platform
      administrator opens System or Security posture, or reads
      `GET /api/security/posture`, on that node), and `disabled` means the
      check is turned off.
    * **Per node.** The cache is each node's own, so `state` and `checked_at`
      describe the node that answered.

  Values today: `state` `fresh` | `partial` | `disabled` | `nothing_to_check` |
  `not_checked`; top-level `notices` `ok` | `unknown` | `disabled` | `null`
  (`null` when `not_checked`); `source` `hex` | `git` | `path` | `overlay` |
  `unknown`; `overall` and the `counts` keys `fail` | `warn` | `unknown` |
  `unverifiable` | `not_applicable` | `ok`; `integrity.status` `ok` |
  `mismatch` | `not_found` | `unverifiable` | `not_applicable` | `unknown` |
  `disabled`, with `integrity.reason` `git` | `path` | `private_repo` |
  `no_checksum` | `unknown_source` for `unverifiable`, otherwise `null`;
  notice `severity` `low` | `medium` | `high` | `critical` | `unknown` and
  `source` `kiln` | `hex`; abandonment `kind` `retired` | `stale` |
  `sdk_unsupported` | `sdk_requirement_invalid`, with `retirement`
  `security` | `deprecated` | `invalid` | `renamed` | `other` for `retired`.
  Every reason object carries all five keys, `null` where they do not apply.

  `notices.complete` is `false` when a source the plugin's notices need did
  not answer: the `items` are what *was* found, never a clean bill.
  `checked_at` is when the oldest of the remote data was fetched, `null` when
  nothing was. Every string passes through `String.replace_invalid/1`, and a
  notice `url` that is not a valid `http(s)://` link is `null`.
  """

  alias Kiln.Plugins.Health.Notice
  alias Kiln.Plugins.Health.PluginStatus
  alias Kiln.Plugins.Health.Report

  @version 1

  @overall ~w(fail warn unknown unverifiable not_applicable ok)a

  @retirements ~w(security deprecated invalid renamed other)a

  @doc "The body's `version`: bumped only for a change that breaks the contract."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The response body for `report`, or for a node with no fresh check (`nil`)."
  @spec show(%{report: Report.t() | nil}) :: map()
  def show(%{report: nil}) do
    %{
      "version" => @version,
      "state" => "not_checked",
      "checked_at" => nil,
      "notices" => nil,
      "counts" => counts([]),
      "plugins" => []
    }
  end

  def show(%{report: %Report{} = report}) do
    %{
      "version" => @version,
      "state" => Atom.to_string(report.state),
      "checked_at" => timestamp(report.checked_at),
      "notices" => Atom.to_string(report.notices),
      "counts" => counts(report.plugins),
      "plugins" =>
        report.plugins
        |> Enum.map(&plugin/1)
        |> Enum.sort_by(&{&1["name"], &1["id"]})
    }
  end

  defp counts(plugins) do
    Enum.reduce(
      plugins,
      Map.new(@overall, &{Atom.to_string(&1), 0}),
      &Map.update(&2, Atom.to_string(&1.overall), 1, fn count -> count + 1 end)
    )
  end

  defp plugin(%PluginStatus{} = status) do
    %{
      "id" => id(status.plugin),
      "name" => text(status.name),
      "source" => Atom.to_string(status.source),
      "package" => text(status.package),
      "version" => text(status.version),
      "latest_version" => text(status.latest_version),
      "overall" => Atom.to_string(status.overall),
      "integrity" => integrity(status.integrity),
      "notices" => notices(status.advisories),
      "abandonment" => %{
        "known" => status.abandonment_known? == true,
        "reasons" => Enum.map(status.abandonment, &reason/1)
      }
    }
  end

  # The module, as Elixir writes it. Every installed plugin has one, whatever
  # its source (`Kiln.Plugins.Health.Installed.build/4`): an overlay plugin is
  # a module compiled into the app, an unknown-source one a module no loaded
  # application owns.
  defp id(module) when is_atom(module),
    do: module |> Atom.to_string() |> String.replace_prefix("Elixir.", "") |> text()

  # Mismatch carries both checksums; neither is emitted.
  defp integrity({:unverifiable, reason}) when is_atom(reason),
    do: %{"status" => "unverifiable", "reason" => Atom.to_string(reason)}

  defp integrity({status, _data}) when is_atom(status),
    do: %{"status" => Atom.to_string(status), "reason" => nil}

  defp integrity(status) when is_atom(status),
    do: %{"status" => Atom.to_string(status), "reason" => nil}

  defp notices({state, notices}) when is_list(notices) do
    %{"complete" => state == :ok, "items" => Enum.map(notices, &notice/1)}
  end

  # Title, affected and patched are display text, and never emitted.
  defp notice(%Notice{} = notice) do
    %{
      "id" => text(notice.id),
      "aliases" => Enum.map(notice.aliases, &text/1),
      "severity" => Atom.to_string(notice.severity),
      "source" => Atom.to_string(notice.source),
      "url" => url(notice.url)
    }
  end

  # The retirement message is free text from Hex, and never emitted.
  defp reason({:retired, retirement, _message}),
    do: reason("retired", retirement: retirement(retirement))

  defp reason({:stale, %DateTime{} = last_release_at}),
    do: reason("stale", last_release_at: timestamp(last_release_at))

  defp reason({:sdk_unsupported, requirement, bundled}),
    do: reason("sdk_unsupported", requirement: text(requirement), bundled: text(bundled))

  defp reason({:sdk_requirement_invalid, requirement}),
    do: reason("sdk_requirement_invalid", requirement: text(requirement))

  defp reason(kind, fields) when is_binary(kind) do
    %{
      "kind" => kind,
      "retirement" => fields[:retirement],
      "last_release_at" => fields[:last_release_at],
      "requirement" => fields[:requirement],
      "bundled" => fields[:bundled]
    }
  end

  defp retirement(reason) when reason in @retirements, do: Atom.to_string(reason)
  defp retirement(_reason), do: "other"

  # A link with bad bytes is dropped, not repaired, as on the posture.
  defp url(value) when is_binary(value) do
    with true <- String.valid?(value),
         %URI{scheme: scheme, host: host}
         when scheme in ["http", "https"] and host not in [nil, ""] <- URI.parse(value) do
      value
    else
      _other -> nil
    end
  end

  defp url(_value), do: nil

  defp timestamp(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp timestamp(nil), do: nil

  defp text(value) when is_binary(value), do: String.replace_invalid(value)
  defp text(nil), do: nil
end
