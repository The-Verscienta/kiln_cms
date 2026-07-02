# Callback names (handle_HELO, ...) are dictated by the Erlang behaviour.
# credo:disable-for-this-file Credo.Check.Readability.FunctionNames
defmodule KilnCMS.SMTPSink do
  @moduledoc """
  Minimal receive-and-record SMTP server session (gen_smtp's server side),
  standing in for a recipient domain's MX in direct-delivery tests.

  Start one per test with `start/1` and receive `{:smtp_sink, from, to, data}`
  for every accepted message:

      {name, port} = KilnCMS.SMTPSink.start(self())
      # deliver to 127.0.0.1:port ...
      assert_receive {:smtp_sink, from, to, data}
  """
  @behaviour :gen_smtp_server_session

  @doc """
  Start a sink on an ephemeral port, reporting messages to `pid`. Returns
  `{listener_name, port}`; stop it with `:gen_smtp_server.stop(listener_name)`.
  """
  def start(pid) do
    name = :"smtp_sink_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      :gen_smtp_server.start(name, __MODULE__,
        port: 0,
        sessionoptions: [callbackoptions: [pid: pid]]
      )

    {name, :ranch.get_port(name)}
  end

  @impl true
  def init(hostname, _session_count, _address, opts),
    do: {:ok, ["220 ", hostname, " SMTP sink"], opts}

  @impl true
  def handle_HELO(_hostname, state), do: {:ok, state}

  @impl true
  def handle_EHLO(_hostname, extensions, state), do: {:ok, extensions, state}

  @impl true
  def handle_MAIL(_from, state), do: {:ok, state}

  @impl true
  def handle_MAIL_extension(_extension, _state), do: :error

  @impl true
  def handle_RCPT(_to, state), do: {:ok, state}

  @impl true
  def handle_RCPT_extension(_extension, _state), do: :error

  @impl true
  def handle_DATA(from, to, data, state) do
    send(state[:pid], {:smtp_sink, from, to, data})
    {:ok, "queued", state}
  end

  @impl true
  def handle_RSET(state), do: state

  @impl true
  def handle_VRFY(_address, state), do: {:error, "252 VRFY disabled", state}

  @impl true
  def handle_STARTTLS(state), do: state

  @impl true
  def handle_other(verb, _args, state),
    do: {["500 error: command not recognized: '", verb, "'"], state}

  @impl true
  def terminate(reason, state), do: {:ok, reason, state}

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}
end
