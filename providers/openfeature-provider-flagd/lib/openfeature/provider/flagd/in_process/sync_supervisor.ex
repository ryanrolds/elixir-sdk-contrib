defmodule OpenFeature.Provider.Flagd.InProcess.SyncSupervisor do
  @moduledoc false

  # One per initialized provider, so a sync process that crash-loops exhausts its own restart budget
  # and dies alone instead of taking the shared DynamicSupervisor, and every other provider's sync,
  # down with it.

  use Supervisor, restart: :temporary

  alias OpenFeature.Provider.Flagd.InProcess
  alias OpenFeature.Provider.Flagd.InProcess.Sync

  @spec start_link({InProcess.t(), binary(), reference()}) :: Supervisor.on_start()
  def start_link({_provider, _domain, _ref} = args), do: Supervisor.start_link(__MODULE__, args)

  @impl true
  def init({provider, domain, ref}) do
    children = [{Sync, {provider, domain, ref, self()}}]
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end
end
