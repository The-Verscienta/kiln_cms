defmodule KilnCMS.SystemActorGrants do
  @moduledoc """
  What each `KilnCMS.Checks.SystemActor` clause admits, asked of Ash itself
  (#1747) — the machinery behind `KilnCMS.SystemActorScopeTest`.

  `decide/3` answers "may a system actor of `subsystem` run `action` on
  `resource`?" through `Ash.can/3`, without touching the database, so it can be
  asked for every action of every granting resource times every subsystem:

    * a **write or generic action** is decided outright: `true` or `false`
      (evaluated against an in-memory record for an update or destroy, so a
      data condition like `MediaItem`'s `quarantined == true` is applied);
    * a **read** is never refused outright when another branch of its policy
      could still filter rows in — a stranger's view of published `:public`
      media, say — so it is decided by Ash's answer *and* the filter Ash would
      add. A subsystem the grant admits is authorized with no filter of the
      policy's own; one it refuses gets `false`, a stranger's filter, or (for a
      `:runtime` policy) a `:maybe`.

  Either way "admitted" is relative: `admitted/4` compares each subsystem's
  answer with the answer for a label no grant names, which every clause for
  people resolves to nothing (`KilnCMS.SystemActor` has no `:id` and no
  `:role`). Only a `KilnCMS.Checks.SystemActor` clause can tell two labels
  apart, so an answer that differs from the unnamed label's is that clause
  admitting it.
  """

  alias KilnCMS.SystemActor

  # Data an update or destroy is decided against, where a policy reads the
  # record: the media pipeline may purge only a quarantined item.
  @records %{KilnCMS.CMS.MediaItem => %{quarantined: true}}

  @matrix_path "docs/policy-matrix.md"

  @doc """
  The rows of `docs/policy-matrix.md`'s "The system actor" table, as
  `{resources, %{action => [subsystem]}}` — parsed from each row's first cell
  (the resources, in backticks) and its **Subsystems** cell: groups of
  `` `action`, `action`: `:subsystem`, `:subsystem` `` separated by ` · `.
  """
  @spec matrix_rows() :: [{[module()], %{atom() => [atom()]}}]
  def matrix_rows do
    [_before, section] =
      @matrix_path |> File.read!() |> String.split("### The system actor", parts: 2)

    [table | _] = String.split(section, "\nLegend:", parts: 2)

    for line <- String.split(table, "\n"),
        String.starts_with?(line, "| `") do
      [resources, _actions, subsystems | _why] =
        line |> String.trim_leading("| ") |> String.split(" | ")

      {row_resources(resources), parse_grants(subsystems)}
    end
  end

  # The "(content)" row names the core's content types, but its grants come
  # from `KilnCMS.CMS.Content`, which every content type an overlay builds on
  # it carries too, so the row covers those types as well. Without this, a
  # correct overlay's own content types admit subsystems "no row names". The
  # types are taken from the granting resources rather than `:content_domains`,
  # so one compiled into any configured domain is covered.
  defp row_resources(cell) do
    named = Enum.map(ticked(cell), &Module.concat(KilnCMS, &1))

    if String.contains?(cell, "(content)"),
      do: Enum.uniq(named ++ Enum.filter(granting_resources(), &content_type?/1)),
      else: named
  end

  @doc """
  Whether `resource` is built on `KilnCMS.CMS.Content`: a compiled content
  type (`__kiln_content_type__/0`) or the dynamic `Entry` resource
  (`__kiln_dynamic_entry__/0`). Such a resource carries the base's
  system-actor grants, which the matrix's "(content)" row documents.
  """
  @spec content_type?(module()) :: boolean()
  def content_type?(resource) do
    Code.ensure_loaded?(resource) and
      (function_exported?(resource, :__kiln_content_type__, 0) or
         function_exported?(resource, :__kiln_dynamic_entry__, 0))
  end

  defp parse_grants(cell) do
    for group <- String.split(cell, " · "), reduce: %{} do
      acc ->
        {subsystems, actions} =
          group |> ticked() |> Enum.split_with(&String.starts_with?(&1, ":"))

        subsystems = Enum.map(subsystems, &(&1 |> String.trim_leading(":") |> String.to_atom()))

        Enum.reduce(actions, acc, fn action, acc ->
          Map.update(acc, String.to_atom(action), subsystems, &Enum.uniq(&1 ++ subsystems))
        end)
    end
  end

  defp ticked(text), do: for([_, token] <- Regex.scan(~r/`([^`]+)`/, text), do: token)

  @doc """
  The matrix's grants folded per resource and action (a resource may have more
  than one row): `%{{resource, action} => MapSet.t(subsystem)}`.
  """
  @spec matrix_grants() :: %{{module(), atom()} => MapSet.t(atom())}
  def matrix_grants do
    for {resources, grants} <- matrix_rows(),
        resource <- resources,
        {action, subsystems} <- grants,
        reduce: %{} do
      acc ->
        Map.update(
          acc,
          {resource, action},
          MapSet.new(subsystems),
          &MapSet.union(&1, MapSet.new(subsystems))
        )
    end
  end

  @doc "Every non-embedded resource with a `KilnCMS.Checks.SystemActor` clause."
  @spec granting_resources() :: [module()]
  def granting_resources do
    for domain <- Application.fetch_env!(:kiln_cms, :ash_domains),
        resource <- Ash.Domain.Info.resources(domain),
        not Ash.Resource.Info.embedded?(resource),
        clauses(resource) != [],
        uniq: true,
        do: resource
  end

  @doc "Every `KilnCMS.Checks.SystemActor` clause on `resource`, as its options."
  @spec clauses(module()) :: [keyword()]
  def clauses(resource) do
    for policy <- Ash.Policy.Info.policies(resource),
        check <- policy.policies,
        check.check_module == KilnCMS.Checks.SystemActor,
        do: check.check_opts
  end

  @doc "The subsystems any clause on `resource` names."
  @spec named_subsystems(module()) :: MapSet.t(atom())
  def named_subsystems(resource) do
    resource
    |> clauses()
    |> Enum.flat_map(&KilnCMS.Checks.SystemActor.subsystems/1)
    |> MapSet.new()
  end

  @doc """
  Every subsystem label the application builds an actor with, read from the
  source (`SystemActor.new(:x)`, `SystemActor.resolve(:x)`, `system(:x)`, and
  a defaulted `system(subsystem \\\\ :x)`), plus every label a grant names.
  """
  @spec all_subsystems() :: [atom()]
  def all_subsystems do
    pattern =
      ~r/SystemActor\.(?:new|resolve)\(:(\w+)\)|\bsystem\(:(\w+)\)|system\(subsystem \\\\ :(\w+)\)/

    from_source =
      for path <- Path.wildcard("lib/**/*.ex"),
          captures <- Regex.scan(pattern, File.read!(path), capture: :all_but_first),
          label <- captures,
          label != "",
          do: String.to_atom(label)

    from_grants = Enum.flat_map(granting_resources(), &MapSet.to_list(named_subsystems(&1)))

    Enum.sort(Enum.uniq(from_source ++ from_grants))
  end

  @doc "Every action on `resource`, as `{name, type}`."
  @spec actions(module()) :: [{atom(), atom()}]
  def actions(resource) do
    for action <- Ash.Resource.Info.actions(resource), do: {action.name, action.type}
  end

  @doc """
  Ash's answer for a system actor of `subsystem` running `action` on
  `resource`: `true` / `false` for a write or generic action, `{:filter, _}`
  for a read.
  """
  @spec decide(module(), atom(), atom()) :: term()
  def decide(resource, action, subsystem) do
    actor = SystemActor.new(subsystem)
    tenant = KilnCMS.Accounts.default_org_id()
    opts = [tenant: tenant, run_queries?: false, maybe_is: :maybe]

    case Ash.Resource.Info.action(resource, action).type do
      :read ->
        query = Ash.Query.for_read(resource, action, arguments(resource, action), tenant: tenant)
        {:ok, answer, query} = Ash.can(query, actor, Keyword.put(opts, :alter_source?, true))
        {answer, inspect(query.filter)}

      type when type in [:update, :destroy] ->
        record = struct(resource, Map.merge(%{org_id: tenant}, Map.get(@records, resource, %{})))
        answer!(Ash.can({record, action}, actor, opts))

      _create_or_generic ->
        answer!(Ash.can({resource, action}, actor, opts))
    end
  end

  defp answer!({:ok, answer}), do: answer

  # A value for each required argument of a read. Left `nil`, an argument the
  # action filters on (`user_id == ^arg(:user_id)`) can template to the same
  # expression a refused actor's filter does (`user_id == ^actor(:id)`, `nil`
  # for a system actor), and the two answers would be indistinguishable.
  defp arguments(resource, action) do
    for argument <- Ash.Resource.Info.action(resource, action).arguments,
        not argument.allow_nil?,
        is_nil(argument.default),
        value = sample(argument.type, argument.constraints),
        not is_nil(value),
        into: %{},
        do: {argument.name, value}
  end

  defp sample({:array, type}, constraints), do: List.wrap(sample(type, constraints[:items] || []))
  # Fixed values: the answers for two labels are compared, so the arguments
  # must not differ between the calls.
  defp sample(Ash.Type.UUID, _), do: "7b1e7a4c-0d5c-4a53-9d0e-5c6a1f0e1747"
  defp sample(Ash.Type.String, _), do: "probe"
  defp sample(Ash.Type.CiString, _), do: "probe"
  defp sample(Ash.Type.Integer, _), do: 1
  defp sample(Ash.Type.Boolean, _), do: true
  defp sample(Ash.Type.UtcDatetimeUsec, _), do: ~U[2026-01-01 00:00:00.000000Z]
  defp sample(Ash.Type.UtcDatetime, _), do: ~U[2026-01-01 00:00:00Z]
  defp sample(Ash.Type.Date, _), do: ~D[2026-01-01]

  defp sample(Ash.Type.Atom, constraints) do
    case constraints[:one_of] do
      [first | _] -> first
      _ -> :probe
    end
  end

  defp sample(_type, _constraints), do: nil

  @doc """
  The subsystems out of `subsystems` that a `KilnCMS.Checks.SystemActor`
  clause admits to `action` on `resource`: those whose `decide/3` answer
  differs from `probe`'s, a label no grant names.

  `:undecidable` when `probe` itself is authorized outright with no filter —
  the action is open to everyone (a world-readable `Redirect`), or its policy
  is `access_type :runtime` and only rows can answer
  (`Firing.PublishedArtifact`'s reads). A grant there has to be tested against
  data.
  """
  @spec admitted(module(), atom(), [atom()], atom()) :: [atom()] | :undecidable
  def admitted(resource, action, subsystems, probe \\ :__no_grant_names_this__) do
    case decide(resource, action, probe) do
      open when open in [true, {true, "nil"}] ->
        :undecidable

      refused ->
        Enum.filter(subsystems, &(decide(resource, action, &1) != refused))
    end
  end
end
