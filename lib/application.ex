defmodule SimpleProxy.Application do

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SimpleProxy.Telemetry,
      {SimpleProxy.ConnectProxy, 4080}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SimpleProxy.Supervisor)
  end
end
