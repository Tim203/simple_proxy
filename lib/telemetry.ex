defmodule SimpleProxy.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus, metrics: metrics(), port: 4081}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      counter(
        "simple_proxy.metrics.requests",
        event_name: [:simple_proxy, :metrics, :requests],
        measurement: :add,
        tags: [:source, :target]
      ),
      counter(
        "simple_proxy.metrics.requests.local",
        event_name: [:simple_proxy, :metrics, :requests, :local],
        measurement: :add,
        tags: [:source, :path]
      )
    ]
  end
end
