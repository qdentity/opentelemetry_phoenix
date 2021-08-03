defmodule OpentelemetryPhoenix do
  @moduledoc """
  OpentelemetryPhoenix uses [telemetry](https://hexdocs.pm/telemetry/) handlers to create `OpenTelemetry` spans.

  Current events which are supported include endpoint start/stop, router start/stop,
  and router exceptions.

  ## Usage

  In your application start:

      def start(_type, _args) do
        OpenTelemetry.register_application_tracer(:my_app)
        OpentelemetryPhoenix.setup()

        children = [
          {Phoenix.PubSub, name: MyApp.PubSub},
          MyAppWeb.Endpoint
        ]

        opts = [strategy: :one_for_one, name: MyStore.Supervisor]
        Supervisor.start_link(children, opts)
      end

  """

  require OpenTelemetry.Tracer
  alias OpenTelemetry.Span
  alias OpentelemetryPhoenix.Reason

  @tracer_id :opentelemetry_phoenix

  @typedoc "Setup options"
  @type opts :: [endpoint_prefix() | sampler_for()]

  @typedoc "The endpoint prefix in your endpoint. Defaults to `[:phoenix, :endpoint]`"
  @type endpoint_prefix :: {:endpoint_prefix, [atom()]}

  @typedoc "A sampler function, which can be used to use a sample a particular requests."
  @type sampler_for :: (%{measurements: map(), meta: map()} -> {:sampler, :otel_sampler.t()} | :no_sampler)

  @doc """
  Initializes and configures the telemetry handlers.
  """
  @spec setup(opts()) :: :ok
  def setup(opts \\ []) do
    opts = ensure_opts(opts)

    {:ok, otel_phx_vsn} = :application.get_key(@tracer_id, :vsn)
    OpenTelemetry.register_tracer(@tracer_id, otel_phx_vsn)

    :ok = attach_endpoint_start_handler(opts)
    :ok = attach_endpoint_stop_handler(opts)
    :ok = attach_router_start_handler(opts)
    :ok = attach_router_dispatch_exception_handler(opts)

    :ok
  end

  if Mix.env() == :test do
    def detach_all do
      [
        {__MODULE__, :endpoint_start},
        {__MODULE__, :endpoint_stop},
        {__MODULE__, :router_dispatch_start},
        {__MODULE__, :router_dispatch_exception}
      ]
      |> Enum.each(&:telemetry.detach/1)
    end
  end

  defp ensure_opts(opts), do: Keyword.merge(default_opts(), opts)

  defp default_opts do
    [endpoint_prefix: [:phoenix, :endpoint]]
  end

  @doc false
  def attach_endpoint_start_handler(opts) do
    :telemetry.attach(
      {__MODULE__, :endpoint_start},
      opts[:endpoint_prefix] ++ [:start],
      &__MODULE__.handle_endpoint_start/4,
      opts
    )
  end

  @doc false
  def attach_endpoint_stop_handler(opts) do
    :telemetry.attach(
      {__MODULE__, :endpoint_stop},
      opts[:endpoint_prefix] ++ [:stop],
      &__MODULE__.handle_endpoint_stop/4,
      opts
    )
  end

  @doc false
  def attach_router_start_handler(opts) do
    :telemetry.attach(
      {__MODULE__, :router_dispatch_start},
      [:phoenix, :router_dispatch, :start],
      &__MODULE__.handle_router_dispatch_start/4,
      opts
    )
  end

  @doc false
  def attach_router_dispatch_exception_handler(opts) do
    :telemetry.attach(
      {__MODULE__, :router_dispatch_exception},
      [:phoenix, :router_dispatch, :exception],
      &__MODULE__.handle_router_dispatch_exception/4,
      opts
    )
  end

  @doc false
  def handle_endpoint_start(_event, measurements, %{conn: %{adapter: adapter} = conn} = meta, config) do
    :otel_propagator.text_map_extract(conn.req_headers)

    peer_data = Plug.Conn.get_peer_data(conn)

    user_agent = header_value(conn, "user-agent")
    peer_ip = Map.get(peer_data, :address)

    attributes = [
      "http.client_ip": client_ip(conn),
      "http.flavor": http_flavor(adapter),
      "http.host": conn.host,
      "http.method": conn.method,
      "http.scheme": "#{conn.scheme}",
      "http.target": conn.request_path,
      "http.user_agent": user_agent,
      "net.host.ip": to_string(:inet_parse.ntoa(conn.remote_ip)),
      "net.host.port": conn.port,
      "net.peer.ip": to_string(:inet_parse.ntoa(peer_ip)),
      "net.peer.port": peer_data.port,
      "net.transport": :"IP.TCP"
    ]

    start_opts = maybe_put_sampler(%{kind: :server}, measurements, meta, config)

    # start the span with a default name. Route name isn't known until router dispatch
    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "HTTP #{conn.method}", meta, start_opts)
    |> Span.set_attributes(attributes)
  end

  @doc false
  def handle_endpoint_stop(_event, _measurements, %{conn: conn} = meta, _config) do
    # ensure the correct span is current and update the status
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    Span.set_attribute(ctx, :"http.status", conn.status)

    if conn.status >= 400 do
      Span.set_status(ctx, OpenTelemetry.status(:error, ""))
    end

    # end the Phoenix span
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  @doc false
  def handle_router_dispatch_start(_event, _measurements, meta, _config) do
    attributes = [
      "phoenix.plug": meta.plug,
      "phoenix.action": meta.plug_opts,
      "http.route": meta.route
    ]

    # Add more info that we now know about but don't close the span
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)
    Span.update_name(ctx, "#{meta.route}")
    Span.set_attributes(ctx, attributes)
  end

  @doc false
  def handle_router_dispatch_exception(
        _event,
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    {[reason: reason], attrs} =
      Reason.normalize(reason)
      |> Keyword.split([:reason])

    # try to normalize all errors to Elixir exceptions
    exception = Exception.normalize(kind, reason, stacktrace)

    # record exception and mark the span as errored
    Span.record_exception(ctx, exception, stacktrace, attrs)
    Span.set_status(ctx, OpenTelemetry.status(:error, ""))

    # do not close the span as endpoint stop will still be called with
    # more info, including the status code, which is nil at this stage
  end

  defp http_flavor({_adapter_name, meta}) do
    case Map.get(meta, :version) do
      :"HTTP/1.0" -> :"1.0"
      :"HTTP/1.1" -> :"1.1"
      :"HTTP/2.0" -> :"2.0"
      :SPDY -> :SPDY
      :QUIC -> :QUIC
      nil -> ""
    end
  end

  defp client_ip(%{remote_ip: remote_ip} = conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] ->
        to_string(:inet_parse.ntoa(remote_ip))

      [client | _] ->
        client
    end
  end

  defp header_value(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [] ->
        ""

      [value | _] ->
        value
    end
  end

  defp maybe_put_sampler(opts, measurements, meta, config) do
    if sampler_for = Keyword.get(config, :sampler_for) do
      sampler = sampler_for.(%{measurements: measurements, meta: meta})

      case sampler do
        {:sampler, sampler} ->
          Map.put(opts, :sampler, sampler)

        :no_sampler ->
          opts

        _ ->
          raise ArgumentError, "expected to get {:sampler, otel_sampler.t()} or :no_sampler but got #{inspect(sampler)}"
      end
    else
      opts
    end
  end
end
