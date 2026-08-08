defmodule KilnCMS.Governance.Witness.HTTP do
  @moduledoc """
  A transparency log reached over HTTP: `POST` the checkpoint, keep the receipt
  (#733).

      config :kiln_cms, KilnCMS.Governance.Witness, adapter: KilnCMS.Governance.Witness.HTTP
      config :kiln_cms, KilnCMS.Governance.Witness.HTTP,
        url: "https://log.example/kiln",
        token: {:env, %{"var" => "KILN_GOVERNANCE_WITNESS_TOKEN"}}

  (`KILN_GOVERNANCE_WITNESS=http`, `KILN_GOVERNANCE_WITNESS_URL`,
  `KILN_GOVERNANCE_WITNESS_TOKEN`.)

  ## The wire contract

  Three requests against `url`, with the checkpoint key as a path segment:

  | | request | expected |
  |---|---|---|
  | `publish/2` | `POST <url>/<key>`, JSON body | `201`; `409` if the key exists |
  | `fetch/1` | `GET <url>/<key>` | `200` with the exact bytes; `404` if absent |
  | `list/1` | `GET <url>/<org_id>/`, `Accept: application/json` | `200`, a JSON array of keys |

  `list/1` **follows pagination**: an `RFC 8288` `Link: <…>; rel="next"` header,
  or a `{"keys": […], "next": "…"}` body. A log that answers a bounded page and
  says nothing about the rest would otherwise report the sink as smaller than it
  is — and for this audit "smaller" reads as *no missing rows*, which is the
  answer a truncation attack wants. `KilnCMS.Governance.Witness.S3` pages for
  exactly this reason; an HTTP log is likelier to page, not less.

  Deliberately small. A log that speaks RFC 6962, or a homegrown append-only
  service, or an object store behind a signed-URL proxy can all satisfy it with
  a thin shim; requiring any one protocol would have made this adapter useful to
  one deployment.

  ## Refusing to overwrite is the service's job, and is checked here

  `publish/2` sends `If-None-Match: *` — the same conditional-create the S3
  adapter uses — and treats `409` (or `412`) as `{:error, :already_published}`.

  But an HTTP endpoint is not a store with defined semantics: a service that
  ignores the header and replaces the object answers `201` and looks identical
  to one that appended. **A sink that accepts an overwrite is worse than no
  sink**, because the attacker rewrites the published checkpoint to match the
  doctored database and `--audit` passes over it. So a `2xx` that is not `201`
  is refused rather than trusted: `200 OK` from a `POST` that was supposed to
  create is exactly what a replace looks like.

  That is a heuristic and it is documented as one. The real guarantee has to
  come from the log — an append-only service, or a proxy that denies overwrites
  — and `docs/governance.md` says so.

  ## Why not `SafeFetch`

  `KilnCMS.SafeFetch` exists for URLs *content* chose, and refuses private
  addresses to stop SSRF. This URL is operator configuration, like the S3
  bucket, and a transparency log on an internal network or a sidecar on
  `127.0.0.1` is a legitimate deployment — one this adapter would otherwise
  make unreachable. Same posture the S3 adapter takes with `ex_aws`.

  ## The receipt

  Whatever the service returns — a signed tree head, an inclusion proof, a
  bare id — goes into the checkpoint's `witness_receipt` map, which is outside
  the signature. A JSON object body is stored as-is under `"response"`; anything
  else is stored as text. The `sha256` this adapter computes over the body it
  sent is stored alongside, so an audit can tell "the log returned something
  unparseable" from "the log returned a receipt for different bytes".
  """
  @behaviour KilnCMS.Governance.Witness

  alias KilnCMS.Governance.Witness

  @impl true
  def publish(key, body) do
    with {:ok, url} <- url() do
      [
        method: :post,
        url: join(url, key),
        body: body,
        headers: headers([{"content-type", "application/json"}, {"if-none-match", "*"}])
      ]
      |> request()
      |> case do
        {:ok, %{status: 201} = response} -> {:ok, receipt(key, body, response)}
        # A conditional create that was refused. Named rather than passed
        # through as a generic HTTP error so the caller does not retry forever.
        {:ok, %{status: status}} when status in [409, 412] -> {:error, :already_published}
        {:ok, %{status: status}} when status in 200..299 -> {:error, {:not_created, status}}
        {:ok, %{status: status}} -> {:error, {:http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def fetch(key) do
    with {:ok, url} <- url() do
      # `decode_body: false` so this returns what the log stored, byte for byte.
      # Both callers compare bytes — `Checkpoint.confirm/5` pattern-matches the
      # published body against the one it sent — and letting Req decode meant
      # re-encoding with `Jason`, which only round-trips identically because
      # every map in a checkpoint has under 32 keys and Erlang flatmaps iterate
      # in sorted order below that. One field more and every publish would
      # record a mismatch that reads as "the sink accepted an overwrite".
      [method: :get, url: join(url, key), headers: headers([]), decode_body: false]
      |> request()
      |> case do
        {:ok, %{status: 200, body: body}} -> {:ok, to_binary(body)}
        {:ok, %{status: 404}} -> {:error, :not_published}
        {:ok, %{status: status}} -> {:error, {:http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A page count that cannot be reached by a well-behaved log, but bounds a
  # broken or hostile one: a `next` that points at itself would otherwise spin
  # forever inside a Mix task.
  @max_pages 1_000

  @impl true
  def list(org_id) do
    with {:ok, url} <- url(), do: list_pages(join(url, "#{org_id}/"), org_id, [], @max_pages)
  end

  defp list_pages(_url, _org_id, _acc, 0), do: {:error, :witness_listing_too_long}

  defp list_pages(url, org_id, acc, remaining) do
    [method: :get, url: url, headers: headers([{"accept", "application/json"}])]
    |> request()
    |> case do
      {:ok, %{status: 200} = response} ->
        with {:ok, keys} <- keys(response.body, org_id),
             do: continue(next_page(response), org_id, acc ++ keys, remaining)

      # A log that has never been written for this org 404s the collection
      # rather than answering `[]`, and that is not a tampering signal. Only on
      # the FIRST page: a `next` that 404s is a broken listing, not an empty one.
      {:ok, %{status: 404}} when acc == [] ->
        {:ok, []}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue(nil, _org_id, keys, _remaining), do: {:ok, keys}
  defp continue(next, org_id, keys, remaining), do: list_pages(next, org_id, keys, remaining - 1)

  # Two spellings, because a shim author will reach for whichever their store
  # already speaks: the `Link` header, or a `next` alongside the keys.
  defp next_page(response) do
    case link_next(header(response, "link")) do
      nil -> body_next(response.body)
      next -> next
    end
  end

  defp link_next(nil), do: nil

  defp link_next(link) do
    Regex.run(~r/<([^>]+)>\s*;\s*rel\s*=\s*"?next"?/i, link)
    |> case do
      [_full, url] -> url
      _no_next -> nil
    end
  end

  defp body_next(body) do
    case decode(body) do
      %{"next" => next} when is_binary(next) and next != "" -> next
      _no_next -> nil
    end
  end

  @impl true
  def describe do
    case url() do
      {:ok, url} -> "http (#{url})"
      {:error, _reason} -> "http (unconfigured — set KILN_GOVERNANCE_WITNESS_URL)"
    end
  end

  # A list of keys, however the service spells them. Both the bare
  # `["<org>/000000000001.json"]` and the org-relative `["000000000001.json"]`
  # are accepted and normalised to what `Witness.key/2` produces, because the
  # audit lines these up against `sequence_from_key/1` and a shim author should
  # not have to guess which one Kiln wanted.
  #
  # A body that is not a list of strings is an error rather than an empty list.
  # "The log holds nothing for this org" is the exact answer a truncation attack
  # wants the audit to reach, so it must never be something a malformed response
  # can produce by accident.
  defp keys(body, org_id) do
    case decode(body) do
      %{"keys" => list} when is_list(list) ->
        keys(list, org_id)

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok,
           list
           |> Enum.map(&normalize_key(&1, org_id))
           |> Enum.filter(&own_org?(&1, org_id))}
        else
          {:error, {:invalid_listing, :not_strings}}
        end

      _other ->
        {:error, {:invalid_listing, :not_a_list}}
    end
  end

  defp normalize_key(key, org_id) do
    trimmed = String.trim_leading(key, "/")

    if String.contains?(trimmed, "/"), do: trimmed, else: "#{org_id}/#{trimmed}"
  end

  # A listing is asked for one org and must answer for that org. A key naming a
  # different one — a log that ignores the path, a shim that lists the whole
  # bucket — would otherwise have its sequence attributed here, and the audit
  # would report "the witness holds a checkpoint the database does not" about a
  # checkpoint that belongs to somebody else. False alarms on a tamper-detection
  # surface are not free: they are how a real one stops being believed.
  defp own_org?(key, org_id), do: String.starts_with?(key, org_id <> "/")

  # Req decodes a JSON response by content-type; a service that answers
  # `text/plain` hands back the raw string, so both shapes are handled.
  defp decode(body) when is_list(body) or is_map(body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp decode(_body), do: nil

  defp receipt(key, body, response) do
    %{
      "key" => key,
      "bytes" => byte_size(body),
      "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
      "status" => response.status,
      "location" => header(response, "location"),
      "response" => receipt_body(response.body)
    }
  end

  # A JSON object or array is kept as structure so an auditor can read a signed
  # tree head out of it; anything else is stored as text rather than dropped,
  # since an opaque id is still a receipt.
  defp receipt_body(body) when is_map(body) or is_list(body), do: body
  defp receipt_body(body) when is_binary(body), do: decode(body) || body
  defp receipt_body(_body), do: nil

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: Jason.encode!(body)

  # `Req.Response`'s `headers` is always a `%{binary() => [binary()]}`, so there
  # is no second clause to write — dialyzer rejects one as uncoverable. The
  # single-binary branch stays because that is what a `Req.Test` plug's response
  # can carry, and it costs nothing.
  defp header(%Req.Response{headers: headers}, name) do
    case Map.get(headers, name) do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp headers(base) do
    case token() do
      {:ok, token} -> [{"authorization", "Bearer " <> token} | base]
      :none -> base
    end
  end

  # Through `KilnCMS.Keys`' provider tuples rather than a bare env read, so the
  # token can come from a file or a secret manager like every other credential
  # here. A plain string is accepted too — an operator who has already put it in
  # an env var should not have to learn the tuple form to try this out.
  defp token do
    case Keyword.get(Witness.config(__MODULE__), :token) do
      nil ->
        :none

      token when is_binary(token) ->
        {:ok, token}

      {provider, config} when provider in [:env, :file, :database] ->
        case KilnCMS.Keys.provider!(provider).fetch(config) do
          {:ok, token} -> {:ok, token}
          _error -> :none
        end

      _other ->
        :none
    end
  end

  defp request(options) do
    options
    # No client-side retry. `KilnCMS.Governance.CheckpointWorker` owns retrying a
    # failed publication, and Req retrying underneath it would turn one 502 into
    # several seconds of a worker's time and hide the failure count from the
    # thing that reports it.
    |> Keyword.put_new(:retry, false)
    |> Req.new()
    |> Req.merge(Keyword.get(Witness.config(__MODULE__), :req_options, []))
    |> Req.request()
  end

  defp join(url, key), do: String.trim_trailing(url, "/") <> "/" <> key

  # An unconfigured URL is an error value, not a raise: publication runs in a
  # background worker and the audit task walks every org, and neither should die
  # on a misconfiguration it can report.
  defp url do
    case Keyword.get(Witness.config(__MODULE__), :url) do
      url when url in [nil, ""] ->
        {:error, :witness_url_not_configured}

      url when is_binary(url) ->
        # A scheme is checked, not assumed. `Req` RAISES on a schemeless URL —
        # `log.example/kiln` is an ordinary typo — and a raise here defeats the
        # whole point of returning an error value: the publish worker's blanket
        # rescue swallows it, the row never gets its `witness_error`, and the
        # operator's only signal is a checkpoint that silently stays
        # unpublished.
        case URI.parse(url) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            {:ok, url}

          _otherwise ->
            {:error, :witness_url_invalid}
        end

      _otherwise ->
        {:error, :witness_url_invalid}
    end
  end
end
