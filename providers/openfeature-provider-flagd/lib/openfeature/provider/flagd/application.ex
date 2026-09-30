defmodule OpenFeature.Provider.Flagd.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: OpenFeature.Provider.Flagd.InProcess.Registry},
      {Task.Supervisor, name: OpenFeature.Provider.Flagd.InProcess.TaskSupervisor},
      {DynamicSupervisor, name: OpenFeature.Provider.Flagd.InProcess.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OpenFeature.Provider.Flagd.Supervisor)
  end
end
