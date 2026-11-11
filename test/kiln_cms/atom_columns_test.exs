defmodule KilnCMS.AtomColumnsTest do
  @moduledoc """
  Every `:atom` attribute without a `one_of`, in the core domains and the
  core's embedded resources, is on a reviewed list (#2605).

  Plain `:atom` loads stored text with `String.to_existing_atom/1`, so a value
  a newer release wrote that this one has no atom for fails the whole read
  that meets it: a rollback, or a rolling deploy, breaks every list holding
  such a row. `FieldDefinition.field_type` did exactly that to v1.8.0. An
  open-set column (one whose values follow a registry, like a plugin's field
  types) should be a `KilnCMS.Types.KnownAtom`, with membership checked by a
  validation and the read side handling `KilnCMS.Types.UnknownAtom`
  (`docs/releasing.md`, "New values in an atom column").

  The columns below predate that rule. Adding one to the list means saying why
  an unknown value cannot reach it, or accepting that it can. A downstream
  project's domains are not checked: they are its own.
  """
  use ExUnit.Case, async: true

  # The core's own domains, as `config/config.exs` lists them. A project adds
  # its domains after these in its own config.
  @core_domains [
    KilnCMS.Accounts,
    KilnCMS.CMS,
    KilnCMS.Analytics,
    KilnCMS.Firing,
    KilnCMS.History,
    KilnCMS.SearchIndex,
    KilnCMS.Mail,
    KilnCMS.Notifications,
    KilnCMS.Newsletter,
    KilnCMS.Automation,
    KilnCMS.Billing,
    KilnCMS.Backups,
    KilnCMS.Federation,
    KilnCMS.Experiments,
    KilnCMS.Social,
    KilnCMS.Security
  ]

  @reviewed %{
    # AshPaperTrail's, not ours: the source resource's action names. A newer
    # release's new action is an atom this one may not have.
    "KilnCMS.CMS.Page.Version.version_action_name" => :paper_trail,
    "KilnCMS.CMS.Post.Version.version_action_name" => :paper_trail,
    "KilnCMS.CMS.Entry.Version.version_action_name" => :paper_trail,
    "KilnCMS.CMS.SiteCodeInjection.Version.version_action_name" => :paper_trail,
    # A content `state`, captured before a release item's transition: the
    # states are a fixed set every release has.
    "KilnCMS.CMS.ReleaseItem.prior_state" => :closed_set_without_one_of,
    # Link kinds, written by code (`:related`, `:reference`, …), open by design
    # so a new kind needs no migration.
    "KilnCMS.CMS.RelatedLink.kind" => :written_by_code,
    "KilnCMS.CMS.ContentLink.kind" => :written_by_code,
    # Content type atoms (`:entry` for every dynamic type): the registry is
    # compiled code, and a type a rollback removes leaves rows behind either way.
    "KilnCMS.Firing.PublishedArtifact.document_type" => :content_type,
    "KilnCMS.Firing.ReferenceEdge.from_type" => :content_type,
    "KilnCMS.Firing.ReferenceEdge.to_type" => :content_type,
    "KilnCMS.Firing.SyncExposure.document_type" => :content_type,
    "KilnCMS.Search.DocumentChunkEmbedding.document_type" => :content_type,
    # Audience names, from the site's billing configuration.
    "KilnCMS.Billing.MembershipEvent.audiences_added" => :audience,
    "KilnCMS.Billing.MembershipEvent.audiences_removed" => :audience
  }

  test "the core domains are all configured" do
    configured = Application.get_env(:kiln_cms, :ash_domains)
    assert @core_domains -- configured == []
  end

  test "every open :atom column is a reviewed one" do
    found =
      (Enum.flat_map(@core_domains, &Ash.Domain.Info.resources/1) ++ core_embedded())
      |> Enum.uniq()
      |> Enum.flat_map(&open_atom_columns/1)
      |> Enum.sort()

    assert found == @reviewed |> Map.keys() |> Enum.sort(), """
    An `:atom` attribute without `one_of` was added or removed.

    Added: #{inspect(found -- Map.keys(@reviewed))}
    Gone:  #{inspect(Map.keys(@reviewed) -- found)}

    A value a newer release writes into a plain `:atom` column fails every read
    of it on an older release (#2605). Use `KilnCMS.Types.KnownAtom` for an open
    set, add `one_of` for a closed one, or list the column here with why it is
    safe (docs/releasing.md, "New values in an atom column").
    """
  end

  defp core_embedded do
    {:ok, modules} = :application.get_key(:kiln_cms, :modules)

    Enum.filter(modules, fn module ->
      String.starts_with?(Atom.to_string(module), "Elixir.KilnCMS.") and
        Code.ensure_loaded?(module) and Ash.Resource.Info.resource?(module) and
        Ash.Resource.Info.embedded?(module)
    end)
  end

  defp open_atom_columns(resource) do
    for attribute <- Ash.Resource.Info.attributes(resource),
        open_atom?(attribute),
        do: "#{inspect(resource)}.#{attribute.name}"
  end

  defp open_atom?(%{type: {:array, Ash.Type.Atom}, constraints: constraints}),
    do: is_nil(get_in(constraints, [:items, :one_of]))

  defp open_atom?(%{type: Ash.Type.Atom, constraints: constraints}),
    do: is_nil(constraints[:one_of])

  defp open_atom?(_attribute), do: false
end
