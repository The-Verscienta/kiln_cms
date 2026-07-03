defmodule KilnCMS.Mail.DnsCheck do
  @moduledoc """
  Live verification of the DNS records direct delivery depends on
  (`docs/direct-email-delivery-plan.md` Phase 4), plus the outbound port-25
  preflight. Pure `:inet_res`/`:gen_tcp`; the admin mail page renders the
  results and persists them via the `record_verification` settings action.

  Every check returns `%{status: :ok | :warn | :fail | :skip, detail: ...}`
  (plus `found`/`expected` where that helps the operator): `:warn` is
  deliberate honesty — e.g. the SPF check is presence-level, not a full RFC
  7208 evaluator, so an `include:` it can't confirm warns instead of
  pretending to pass.

  DNS and TCP go through injectable seams (`opts[:dns]`, `opts[:tcp]`) so
  tests supply fixtures; defaults are the `InetDNS`/`InetTCP` modules below.
  """

  alias KilnCMS.Mail

  defmodule DNS do
    @moduledoc "DNS lookup seam for `KilnCMS.Mail.DnsCheck` (default: `InetDNS`)."

    @doc "TXT records at a name, each returned as one chunk-joined string."
    @callback txt(String.t()) :: [String.t()]

    @doc "MX hosts for a domain, sorted by preference."
    @callback mx(String.t()) :: [String.t()]

    @doc "The PTR (reverse) name for an address."
    @callback ptr(:inet.ip_address()) :: {:ok, String.t()} | {:error, term()}

    @doc "A/AAAA addresses for a name."
    @callback addresses(String.t()) :: [:inet.ip_address()]
  end

  defmodule InetDNS do
    @moduledoc false
    @behaviour DNS

    # Bound every lookup: without an explicit timeout/retry, a hung or
    # firewalled resolver blocks for the OS resolver default, tying up the
    # settings LiveView's verify task. 2s × 1 retry caps a single lookup at
    # ~4s (mirrors the hardening on KilnCMS.Webhooks.SafeUrl).
    @resolver_opts [timeout: 2_000, retry: 1]

    @impl true
    def txt(name) do
      name
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :txt, @resolver_opts)
      |> Enum.map(fn chunks -> Enum.map_join(chunks, "", &List.to_string/1) end)
    end

    @impl true
    def mx(name) do
      name
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :mx, @resolver_opts)
      |> Enum.sort()
      |> Enum.map(fn {_preference, host} -> List.to_string(host) end)
    end

    @impl true
    def ptr(address) do
      # gethostbyaddr takes a bare timeout (ms), not the resolver-opts list.
      case :inet_res.gethostbyaddr(address, 2_000) do
        {:ok, hostent} -> {:ok, hostent |> elem(1) |> List.to_string()}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def addresses(name) do
      charlist = String.to_charlist(name)

      :inet_res.lookup(charlist, :in, :a, @resolver_opts) ++
        :inet_res.lookup(charlist, :in, :aaaa, @resolver_opts)
    end
  end

  defmodule TCP do
    @moduledoc "TCP banner seam for the port-25 preflight (default: `InetTCP`)."

    @doc "Connect, read the server banner, QUIT, close."
    @callback banner(host :: String.t(), port :: :inet.port_number(), timeout()) ::
                {:ok, String.t()} | {:error, term()}
  end

  defmodule InetTCP do
    @moduledoc false
    @behaviour TCP

    @impl true
    def banner(host, port, timeout) do
      # :inet (IPv4) to match the DirectMX sending path — reachability over
      # IPv6 would not prove the v4 route mail actually uses.
      case :gen_tcp.connect(
             String.to_charlist(host),
             port,
             [:binary, :inet, {:active, false}],
             timeout
           ) do
        {:ok, socket} ->
          result = :gen_tcp.recv(socket, 0, timeout)
          :gen_tcp.send(socket, "QUIT\r\n")
          :gen_tcp.close(socket)
          result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @type result :: %{
          required(:status) => :ok | :warn | :fail | :skip,
          required(:detail) => String.t(),
          optional(:found) => String.t() | nil,
          optional(:expected) => String.t() | nil
        }

  # Large, always-up mail receivers; the preflight only proves "outbound
  # port 25 isn't blocked", so targets are fixed — never operator input.
  @probe_domains ["gmail.com", "outlook.com"]
  @probe_timeout :timer.seconds(5)

  @doc """
  Run all DNS checks for the settings row. Returns
  `%{spf: result, dkim: result, dmarc: result, ptr: result}`, ready for
  `KilnCMS.Mail.record_mail_verification/3`.
  """
  @spec run(struct() | map(), keyword()) :: %{atom() => result()}
  def run(settings, opts \\ []) do
    case Keyword.get_lazy(opts, :domain, &Mail.sending_domain/0) do
      nil ->
        no_domain = %{
          status: :skip,
          detail: "no From address configured (MAIL_FROM_EMAIL) — sending domain unknown"
        }

        %{spf: no_domain, dkim: no_domain, dmarc: no_domain, ptr: no_domain}

      domain ->
        %{
          spf: check_spf(domain, settings.server_ip, opts),
          dkim: check_dkim(domain, settings, opts),
          dmarc: check_dmarc(domain, opts),
          ptr: check_ptr(settings.server_ip, opts)
        }
    end
  end

  @doc """
  The DNS records the operator should publish, as shown on the settings page
  (host / type / value per check). PTR appears with provider-panel wording —
  it's the one record that isn't set in the domain's DNS zone.
  """
  @spec expected_records(struct() | map(), keyword()) :: [map()]
  def expected_records(settings, opts \\ []) do
    domain = Keyword.get_lazy(opts, :domain, &Mail.sending_domain/0) || "<sending-domain>"
    helo = Keyword.get_lazy(opts, :helo_host, &helo_host/0) || "<helo-host>"
    ip = settings.server_ip || "<server-ip>"

    from =
      case Application.get_env(:kiln_cms, :email_from) do
        {_name, address} -> address
        _unset -> "postmaster@#{domain}"
      end

    dkim_value =
      case settings.dkim_public_key do
        nil -> "<generate or configure a DKIM key first>"
        public_key -> "v=DKIM1; k=rsa; p=#{public_key}"
      end

    [
      %{check: :spf, type: "TXT", host: domain, value: "v=spf1 #{spf_mechanism(ip)} -all"},
      %{
        check: :dkim,
        type: "TXT",
        host: "#{settings.dkim_selector || "<selector>"}._domainkey.#{domain}",
        value: dkim_value
      },
      %{
        check: :dmarc,
        type: "TXT",
        host: "_dmarc.#{domain}",
        value: "v=DMARC1; p=quarantine; rua=mailto:#{from}"
      },
      %{check: :ptr, type: "PTR", host: ip, value: helo}
    ]
  end

  @doc """
  Can this host speak SMTP to the outside world on port 25? Tries the fixed
  probe domains' MX hosts until one answers with a 220 banner. A failure here
  is the single most important signal on the settings page: direct delivery
  cannot work, use relay mode.
  """
  @spec check_port25(keyword()) :: result()
  def check_port25(opts \\ []) do
    dns = dns(opts)
    tcp = tcp(opts)

    probes = Enum.map(@probe_domains, &probe_port25(&1, dns, tcp))

    cond do
      # A 220 from any probe: the port is open and mail can leave.
      Enum.any?(probes, &match?({:ok, _domain}, &1)) ->
        %{status: :ok, detail: "outbound port 25 is reachable"}

      # We connected and got a banner, just not a 220 (e.g. a 554 greeting for
      # a blocklisted IP). The port is demonstrably open — this is a reputation
      # or policy problem, not a blocked port, so don't send the operator
      # chasing their host's firewall.
      banner = Enum.find_value(probes, &non_220_banner/1) ->
        %{
          status: :warn,
          detail:
            "outbound port 25 is reachable, but the probe MX rejected the greeting " <>
              "(#{banner}) — this is usually IP reputation (a blocklisted sending IP), " <>
              "not a blocked port. Check the IP against Spamhaus and warm it up."
        }

      # No probe connected at all: the port is (almost certainly) blocked.
      true ->
        %{
          status: :fail,
          detail:
            "cannot reach any probe MX on port 25 (#{format_failures(probes)}) — " <>
              "your host likely blocks outbound SMTP; direct delivery cannot work here, " <>
              "use MAIL_MODE=smtp with a relay instead"
        }
    end
  end

  defp probe_port25(domain, dns, tcp) do
    case dns.mx(domain) do
      [mx_host | _rest] ->
        case tcp.banner(mx_host, 25, @probe_timeout) do
          {:ok, "220" <> _rest} -> {:ok, domain}
          {:ok, banner} -> {:banner, domain, String.slice(banner, 0, 40)}
          {:error, reason} -> {:error, domain, reason}
        end

      [] ->
        {:error, domain, :no_mx}
    end
  end

  defp non_220_banner({:banner, _domain, banner}), do: banner
  defp non_220_banner(_other), do: nil

  @doc """
  The HELO/EHLO hostname direct delivery uses: the DirectMX `:hostname`
  config (`MAIL_HELO_HOST`/`PHX_HOST`), falling back to the endpoint host in
  dev/test where the mailer isn't configured for direct mode.
  """
  @spec helo_host() :: String.t() | nil
  def helo_host do
    mailer_hostname() || endpoint_host()
  end

  ## SPF

  defp check_spf(domain, server_ip, opts) do
    records = dns(opts).txt(domain)

    case Enum.find(records, &String.starts_with?(&1, "v=spf1")) do
      nil ->
        %{
          status: :fail,
          detail: "no SPF record found",
          found: nil,
          expected: "v=spf1 #{spf_mechanism(server_ip || "<server-ip>")} -all"
        }

      record when is_nil(server_ip) ->
        %{
          status: :warn,
          detail: "SPF record exists; set the server IP to check it covers this host",
          found: record
        }

      record ->
        if spf_names_ip?(record, server_ip) do
          %{status: :ok, detail: "SPF record covers #{server_ip}", found: record}
        else
          %{
            status: :warn,
            detail:
              "SPF record exists but doesn't name #{server_ip} directly — " <>
                "includes/redirects/CIDR ranges aren't evaluated, verify coverage yourself",
            found: record
          }
        end
    end
  end

  # Match the mechanism as a whole token, not a substring: a bare
  # `String.contains?` would accept "ip4:203.0.113.90" as covering
  # "203.0.113.9" (prefix), a false green. SPF mechanisms are space-separated,
  # so split and compare each token exactly.
  defp spf_names_ip?(record, ip) do
    mechanism = spf_mechanism(ip)

    record
    |> String.split(~r/\s+/, trim: true)
    |> Enum.member?(mechanism)
  end

  defp spf_mechanism(ip) do
    if String.contains?(ip, ":"), do: "ip6:#{ip}", else: "ip4:#{ip}"
  end

  ## DKIM

  defp check_dkim(_domain, %{dkim_public_key: nil}, _opts) do
    %{status: :skip, detail: "generate or configure a DKIM key first"}
  end

  defp check_dkim(domain, settings, opts) do
    name = "#{settings.dkim_selector}._domainkey.#{domain}"
    records = dns(opts).txt(name)
    expected = strip_whitespace(settings.dkim_public_key)

    published =
      records
      |> Enum.map(&dkim_p_value/1)
      |> Enum.reject(&is_nil/1)
      |> List.first()

    cond do
      published == nil ->
        %{
          status: :fail,
          detail: "no DKIM record found at #{name}",
          found: nil,
          expected: "v=DKIM1; k=rsa; p=#{settings.dkim_public_key}"
        }

      published == expected ->
        %{status: :ok, detail: "DKIM record at #{name} matches the configured key"}

      true ->
        %{
          status: :fail,
          detail:
            "DKIM record at #{name} holds a different public key — " <>
              "a stale record from a previous key? Republish the value below",
          expected: "v=DKIM1; k=rsa; p=#{settings.dkim_public_key}"
        }
    end
  end

  defp dkim_p_value(record) do
    record
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn
      "p=" <> value -> strip_whitespace(value)
      _tag -> nil
    end)
  end

  ## DMARC

  defp check_dmarc(domain, opts) do
    case find_dmarc("_dmarc.#{domain}", opts) do
      {:ok, record} -> %{status: :ok, detail: "DMARC record present", found: record}
      :none -> check_dmarc_parent(domain, opts)
    end
  end

  # DMARC is applied at the From domain and, failing that, its organizational
  # (parent) domain (RFC 7489 §3.2). A subdomain sender like
  # cms@mail.example.com is covered by a policy at _dmarc.example.com, so check
  # the parent before reporting "missing". One-label fallback, not a full
  # Public Suffix List walk.
  defp check_dmarc_parent(domain, opts) do
    with parent when is_binary(parent) <- parent_domain(domain),
         {:ok, record} <- find_dmarc("_dmarc.#{parent}", opts) do
      %{
        status: :ok,
        detail: "DMARC policy inherited from the organizational domain #{parent}",
        found: record
      }
    else
      _no_parent_policy -> dmarc_missing()
    end
  end

  defp find_dmarc(name, opts) do
    case Enum.find(dns(opts).txt(name), &String.starts_with?(&1, "v=DMARC1")) do
      nil -> :none
      record -> {:ok, record}
    end
  end

  defp dmarc_missing do
    %{
      status: :warn,
      detail:
        "no DMARC record — mail can flow without one, but Gmail/Yahoo " <>
          "bulk-sender rules increasingly expect it",
      found: nil,
      expected: "v=DMARC1; p=quarantine"
    }
  end

  # The immediate parent (drop the leftmost label); nil for a bare
  # two-label-or-shorter domain, where there is no distinct parent to check.
  defp parent_domain(domain) do
    case String.split(domain, ".") do
      [_leaf, _tld] -> nil
      [_leftmost | rest] when rest != [] -> Enum.join(rest, ".")
      _ -> nil
    end
  end

  ## PTR

  defp check_ptr(nil, _opts) do
    %{status: :skip, detail: "set the server IP to check reverse DNS"}
  end

  defp check_ptr(ip_string, opts) do
    helo = Keyword.get_lazy(opts, :helo_host, &helo_host/0)

    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:error, _reason} ->
        %{status: :fail, detail: "#{ip_string} is not a valid IP address"}

      {:ok, address} ->
        check_ptr_roundtrip(address, ip_string, helo, opts)
    end
  end

  defp check_ptr_roundtrip(address, ip_string, helo, opts) do
    dns = dns(opts)

    case dns.ptr(address) do
      {:error, _reason} ->
        %{
          status: :fail,
          detail:
            "no PTR (reverse DNS) record for #{ip_string} — set it in your hosting " <>
              "provider's panel (not your DNS zone); most receivers reject mail without one",
          expected: helo
        }

      {:ok, name} ->
        cond do
          address not in dns.addresses(name) ->
            %{
              status: :fail,
              detail:
                "PTR resolves to #{name}, but #{name} does not resolve back to #{ip_string}",
              found: name
            }

          # DNS names are case-insensitive (RFC 4343) and reverse zones often
          # store mixed case, so compare case-folded to avoid a spurious warn.
          helo != nil and String.downcase(name) != String.downcase(helo) ->
            %{
              status: :warn,
              detail:
                "PTR round-trips but names #{name}, while HELO is #{helo} — " <>
                  "align them (MAIL_HELO_HOST) for best deliverability",
              found: name,
              expected: helo
            }

          true ->
            %{status: :ok, detail: "PTR record round-trips to #{name}", found: name}
        end
    end
  end

  ## Seams / helpers

  # Seam resolution: explicit opts > app env > real implementation. The app
  # env layer lets the test suite point every caller (e.g. the mail settings
  # LiveView) at stub resolvers without threading opts through the UI.
  defp dns(opts), do: Keyword.get(opts, :dns) || configured(:dns) || InetDNS
  defp tcp(opts), do: Keyword.get(opts, :tcp) || configured(:tcp) || InetTCP

  defp configured(key) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key)
  end

  defp strip_whitespace(value), do: String.replace(value, ~r/\s/, "")

  defp format_failures(probes) do
    Enum.map_join(probes, ", ", fn {:error, domain, reason} -> "#{domain}: #{inspect(reason)}" end)
  end

  defp mailer_hostname do
    :kiln_cms
    |> Application.get_env(KilnCMS.Mailer, [])
    |> Keyword.get(:hostname)
  end

  defp endpoint_host do
    :kiln_cms
    |> Application.get_env(KilnCMSWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> Keyword.get(:host)
  end
end
