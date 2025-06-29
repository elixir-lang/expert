defmodule Engine.ModuleMappings do
  defmodule State do
    defstruct module_to_file: %{}, file_to_modules: %{}

    def new do
      %__MODULE__{}
    end

    def file_for_module(%__MODULE__{} = state, module) do
      Map.get(state.module_to_file, module)
    end

    def modules_in_file(%__MODULE__{} = state, file_path) do
      Map.get(state.file_to_modules, file_path, [])
    end

    def update(%__MODULE__{} = state, module, file_path) do
      file_to_modules =
        case state.module_to_file do
          %{^module => ^file_path} ->
            # the module has already been associated with this path
            state.file_to_modules

          %{^module => old_path} ->
            # the module has changed its file
            remove_this_module? = fn old_module -> old_module == module end

            state.file_to_modules
            |> Map.update(old_path, [], &Enum.reject(&1, remove_this_module?))
            |> Map.update(file_path, [module], &[module | &1])

          _ ->
            # it didn't exist previously
            Map.update(state.file_to_modules, file_path, [module], &[module | &1])
        end

      module_to_file = Map.put(state.module_to_file, module, file_path)
      %__MODULE__{state | file_to_modules: file_to_modules, module_to_file: module_to_file}
    end
  end

  alias Forge.EngineApi.Messages

  use GenServer

  import Messages

  # Public
  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def file_for_module(module) do
    GenServer.call(__MODULE__, {:file_for_module, module})
  end

  def modules_in_file(file_path) do
    GenServer.call(__MODULE__, {:modules_in_file, file_path})
  end

  # GenServer callbacks

  @impl GenServer
  def init(_) do
    Engine.register_listener(self(), [module_updated()])
    {:ok, State.new()}
  end

  @impl GenServer
  def handle_call({:modules_in_file, file_path}, _from, %State{} = state) do
    {:reply, State.modules_in_file(state, file_path), state}
  end

  @impl GenServer
  def handle_call({:file_for_module, module}, _from, %State{} = state) do
    {:reply, State.file_for_module(state, module), state}
  end

  @impl GenServer
  def handle_info(module_updated(name: module_name, file: file_path), %State{} = state) do
    new_state = State.update(state, module_name, file_path)
    {:noreply, new_state}
  end
end
