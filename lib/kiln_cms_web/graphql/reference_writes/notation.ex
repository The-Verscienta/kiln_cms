defmodule KilnCMSWeb.Graphql.ReferenceWrites.Notation do
  @moduledoc """
  Schema macros for `KilnCMSWeb.Graphql.ReferenceWrites`.

  Both read the content types from the schema's `:content_domains` when the
  schema compiles, as `KilnCMSWeb.Graphql.ContentRecord.Notation` does, so a
  project overlay's types gain the mutations with no core edit.

    * `reference_result_objects/1` — one `<Type>ReferencesResult` object per
      type, at the top of the schema.
    * `reference_mutations/1` — `add<Type>References`,
      `remove<Type>References` and `move<Type>Reference`, inside the schema's
      `mutation` block.
  """

  @doc "One `<Type>ReferencesResult` object per content type in `domains`."
  defmacro reference_result_objects(domains) do
    {domains, _binding} = Code.eval_quoted(domains, [], __CALLER__)

    for {resource, type} <- content_resources(domains) do
      quote do
        @desc unquote(
                "The result of a reference write on #{Macro.camelize(Atom.to_string(type))}: " <>
                  "the updated record, or the errors that refused the write."
              )
        object unquote(result_type(type)) do
          @desc "The record after the write; null when it was refused."
          field :result, unquote(type) do
            resolve fn parent, args, resolution ->
              KilnCMSWeb.Graphql.ReferenceWrites.load_result(
                unquote(resource),
                parent,
                args,
                resolution
              )
            end
          end

          @desc "Why the write was refused; empty on success."
          field :errors, non_null(list_of(non_null(:mutation_error)))
        end
      end
    end
  end

  @doc "The three reference mutations for every content type in `domains`."
  defmacro reference_mutations(domains) do
    {domains, _binding} = Code.eval_quoted(domains, [], __CALLER__)

    for {resource, type} <- content_resources(domains) do
      result = result_type(type)

      quote do
        @desc """
        Connect records through the `:reference` custom field `field`: an
        update of the record, so its policies, `expectedLockVersion`, history
        and webhooks apply as for `update<Type>`. A record already connected moves to
        `position` and keeps its link values unless new ones are given.
        """
        field unquote(:"add_#{type}_references"), non_null(unquote(result)) do
          arg :id, non_null(:id)
          arg :field, non_null(:string)
          arg :targets, non_null(list_of(non_null(:reference_target_input)))
          arg :position, :reference_position_input
          arg :expected_lock_version, :integer

          resolve fn args, resolution ->
            KilnCMSWeb.Graphql.ReferenceWrites.add(unquote(resource), args, resolution)
          end
        end

        @desc """
        Disconnect records from the `:reference` custom field `field`. An id
        the field does not hold is ignored.
        """
        field unquote(:"remove_#{type}_references"), non_null(unquote(result)) do
          arg :id, non_null(:id)
          arg :field, non_null(:string)
          arg :targets, non_null(list_of(non_null(:id)))
          arg :expected_lock_version, :integer

          resolve fn args, resolution ->
            KilnCMSWeb.Graphql.ReferenceWrites.remove(unquote(resource), args, resolution)
          end
        end

        @desc """
        Move one connected record to `position` in the `:reference` custom
        field `field`.
        """
        field unquote(:"move_#{type}_reference"), non_null(unquote(result)) do
          arg :id, non_null(:id)
          arg :field, non_null(:string)
          arg :target, non_null(:id)
          arg :position, non_null(:reference_position_input)
          arg :expected_lock_version, :integer

          resolve fn args, resolution ->
            KilnCMSWeb.Graphql.ReferenceWrites.move(unquote(resource), args, resolution)
          end
        end
      end
    end
  end

  # `{resource, graphql_type}` for every content resource on the surface.
  defp content_resources(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&KilnCMSWeb.Graphql.ContentRecord.Notation.content_resource?/1)
    |> Enum.map(&{&1, AshGraphql.Resource.Info.type(&1)})
    |> Enum.reject(fn {_resource, type} -> is_nil(type) end)
    |> Enum.uniq_by(&elem(&1, 1))
  end

  # Schema compile time, from the resources' own GraphQL type names.
  # sobelow_skip ["DOS.BinToAtom"]
  defp result_type(type), do: :"#{type}_references_result"
end
