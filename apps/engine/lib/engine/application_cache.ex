defmodule Engine.ApplicationCache do
  @moduledoc false

  use GenServer

  @applications __MODULE__.Applications
  @available_modules __MODULE__.AvailableModules
  @table_opts [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec application(module() | nil) :: atom() | nil
  def application(nil), do: nil

  def application(module) when is_atom(module) do
    case lookup_application(module) do
      {:ok, app} ->
        app

      :error ->
        app = Application.get_application(module)
        true = :ets.insert(@applications, {module, app})
        app
    end
  end

  @spec available_module?(module()) :: boolean()
  def available_module?(module) when is_atom(module) do
    :ets.member(@available_modules, module)
  end

  def clear do
    :ets.delete_all_objects(@applications)
    load_available_modules()

    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@applications, @table_opts)
    :ets.new(@available_modules, @table_opts)
    load_available_modules()

    {:ok, nil}
  end

  defp load_available_modules do
    :ets.delete_all_objects(@available_modules)

    modules =
      Enum.map(:code.all_available(), fn {module_charlist, _, _} ->
        {List.to_atom(module_charlist), true}
      end)

    true = :ets.insert(@available_modules, modules)
  end

  defp lookup_application(module) do
    case :ets.lookup(@applications, module) do
      [{^module, app}] -> {:ok, app}
      [] -> :error
    end
  end
end
