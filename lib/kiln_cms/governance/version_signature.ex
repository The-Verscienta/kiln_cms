defmodule KilnCMS.Governance.VersionSignature do
  @moduledoc """
  Signs a PaperTrail version row at write time (#598 / #670), so a row that
  arrived late can be told apart from one spliced in afterwards.

  ## Why this exists

  Recording the chain's fold order on the anchor removes the permanent false
  `{:tampered, …}` that clock skew and out-of-order commits used to cause. On its
  own it also removes a real detection: a version row spliced into an
  already-anchored range no longer breaks the recomputed prefix, because it is in
  no anchor's list and simply sorts to the tail.

  A signature over the row's own immutable identity closes that. A late row
  carries a valid one; a row somebody inserted into the table does not.

  This adds no new trust assumption. Anchors are already signed with the same
  key, and their whole meaning already rests on an attacker with database write
  access not holding it. This is a second application of an assumption the
  feature was built on.

  ## The payload is only the immutable parts

  `(org_id, resource_type, source_id, version_id, version_inserted_at)` — what
  identifies *which* version this is, and cannot legitimately change afterwards.

  Deliberately **not** the `changes` map. A signature over editorial content
  would start failing for reasons that are not tampering — a re-serialisation, a
  migration touching an embedded type — and a tamper alarm that cries wolf is one
  operators learn to ignore. Content integrity is the chain hash's job. This
  answers one narrower question: *did this row come from Kiln, or did it appear
  in the table?*

  ## Unsigned deployments

  Signing is optional — with no `KILN_PROVENANCE_PRIVATE_KEY` anchors are already
  stored unsigned, and version rows are too. There, a splice cannot be
  distinguished from an ordinary row, and `KilnCMS.Governance.Chain.verify/4`
  reports that as an anomaly rather than a pass or a failure: "this chain cannot
  prove it either way" is the true answer and more useful than a confident wrong
  one. `docs/chain-fold-order.md` states the conditional guarantee as a table.
  """

  require Logger

  alias KilnCMS.Provenance.Signer

  @typedoc """
  Three outcomes, never two.

    * `:valid` — signed by a key we hold, over this identity. The row came from
      Kiln.
    * `:invalid` — checked against a key we hold and **failed**. Evidence.
    * `:unknown` — no signature at all, or a `key_id` naming a key this
      deployment does not hold. Says nothing either way.

  The split matters enough that `KilnCMS.Provenance.Signer` warns about it in its
  own docs: `{:ok, false}` and `{:error, {:unknown_key_id, _}}` mean completely
  different things, and a boolean would flatten them into one answer.
  """
  @type verdict :: :valid | :invalid | :unknown

  @doc """
  Sign a version's identity. `{signature, key_id}`, or `{nil, nil}` when no
  signing key is configured.

  Unsigned is a normal state, not an error: a default install has no provenance
  key. Logged rather than raised, for the same reason the anchor path logs — a
  misconfigured key should be loud, but must not fail the editorial write that
  triggered it.
  """
  @spec sign(map()) :: {String.t() | nil, String.t() | nil}
  def sign(identity) do
    payload = payload(identity)

    with {:ok, signature} <- Signer.sign(payload),
         {:ok, key_id} <- Signer.key_id() do
      {signature, key_id}
    else
      {:error, reason} ->
        Logger.warning(
          "Version row stored UNSIGNED - provenance signing key unavailable: " <>
            KilnCMS.Keys.describe_error(reason)
        )

        {nil, nil}
    end
  end

  @doc """
  Whether `signature` covers this version's identity — see `t:verdict/0`.
  """
  @spec verify(map(), String.t() | nil, String.t() | nil) :: verdict()
  def verify(_identity, nil, _key_id), do: :unknown

  def verify(identity, signature, key_id) do
    case identity |> payload() |> Signer.verify(signature, key_id) do
      {:ok, true} -> :valid
      {:ok, false} -> :invalid
      # A key we do not hold proves nothing — most often a rotated-out key on a
      # deployment restored without its retired registry.
      {:error, _reason} -> :unknown
    end
  end

  @doc """
  The identity of a version row, as both `sign/1` and `verify/3` need it.

  One function so the signing and checking sides cannot drift: a payload built
  two ways is a signature that stops verifying for no reason anyone can find.
  """
  @spec identity(struct(), String.t()) :: map()
  def identity(version, resource_type) do
    %{
      org_id: Map.get(version, :org_id),
      resource_type: resource_type,
      source_id: version.version_source_id,
      version_id: version.id,
      version_inserted_at: version.version_inserted_at
    }
  end

  # Canonical, field-ordered, newline-delimited. A uuid, a type name and an
  # ISO-8601 timestamp contain no newline, so no two identities can serialise to
  # the same bytes and share one signature.
  defp payload(identity) do
    Enum.map_join(
      [
        identity.org_id,
        identity.resource_type,
        identity.source_id,
        identity.version_id,
        stamp(identity.version_inserted_at)
      ],
      "\n",
      &to_string/1
    )
  end

  # ISO-8601 explicitly, never `to_string/1` on the struct: the two agree today
  # and a `DateTime` inspect format that shifted would silently invalidate every
  # signature ever minted.
  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stamp(other), do: to_string(other)
end
