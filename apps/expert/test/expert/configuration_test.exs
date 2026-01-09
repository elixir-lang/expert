defmodule Expert.ConfigurationTest do
  use ExUnit.Case, async: false

  alias Expert.Configuration
  alias Expert.Configuration.WorkspaceSymbols
  alias GenLSP.Notifications.WorkspaceDidChangeConfiguration
  alias GenLSP.Structures.DidChangeConfigurationParams

  setup do
    :persistent_term.erase(Expert.Configuration)

    Configuration.new()
    |> Configuration.set()

    :ok
  end

  describe "new/0 and new/1" do
    test "creates configuration with default values" do
      config = Configuration.new()

      assert config.workspace_symbols.min_query_length == 2
      assert config.dialyzer_enabled? == false
    end

    test "accepts keyword list of attributes" do
      config = Configuration.new(workspace_symbols: %WorkspaceSymbols{min_query_length: 0})

      assert config.workspace_symbols.min_query_length == 0
    end

    test "set/1 stores configuration in persistent_term" do
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 5}]
      |> Configuration.new()
      |> Configuration.set()

      assert Configuration.get().workspace_symbols.min_query_length == 5
    end
  end

  describe "on_change/1 with workspace_symbols.min_query_length" do
    test "parses nested setting correctly" do
      settings = %{"workspaceSymbols" => %{"minQueryLength" => 0}}

      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 0
    end

    test "accepts any non-negative integer" do
      settings = %{"workspaceSymbols" => %{"minQueryLength" => 5}}

      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 5
    end

    test "defaults to 2 when setting is missing" do
      settings = %{}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 2
    end

    test "defaults to 2 when workspaceSymbols is present but minQueryLength is missing" do
      settings = %{"workspaceSymbols" => %{}}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 2
    end

    test "defaults to 2 when value is not a non-negative integer" do
      settings = %{"workspaceSymbols" => %{"minQueryLength" => "0"}}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)
      assert updated.workspace_symbols.min_query_length == 2

      settings = %{"workspaceSymbols" => %{"minQueryLength" => -1}}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)
      assert updated.workspace_symbols.min_query_length == 2

      settings = %{"workspaceSymbols" => %{"minQueryLength" => 1.5}}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)
      assert updated.workspace_symbols.min_query_length == 2
    end

    test "can override a previously set value" do
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 0}]
      |> Configuration.new()
      |> Configuration.set()

      settings = %{"workspaceSymbols" => %{"minQueryLength" => 3}}

      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 3
    end
  end

  describe "race condition prevention" do
    defmodule DummyServer do
      use GenServer

      alias Expert.Configuration
      alias GenLSP.Notifications.WorkspaceDidChangeConfiguration
      alias GenLSP.Structures.DidChangeConfigurationParams

      def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
      def update_config(pid, settings), do: GenServer.cast(pid, {:update_config, settings})
      def slow_noop(pid, delay), do: GenServer.cast(pid, {:slow_noop, delay})

      @impl GenServer
      def init(test_pid), do: {:ok, test_pid}

      @impl GenServer
      def handle_cast({:update_config, settings}, test_pid) do
        change = %WorkspaceDidChangeConfiguration{
          params: %DidChangeConfigurationParams{settings: settings}
        }

        {:ok, _} = Configuration.on_change(change)
        send(test_pid, :update_finished)
        {:noreply, test_pid}
      end

      def handle_cast({:slow_noop, delay}, test_pid) do
        Process.sleep(delay)
        send(test_pid, :noop_finished)
        {:noreply, test_pid}
      end
    end

    test "config update persists even when a slow handler completes afterwards" do
      # Start with initial config
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 5}]
      |> Configuration.new()
      |> Configuration.set()

      {:ok, pid} = DummyServer.start_link(self())

      # 1. slow_noop starts processing (takes 50ms)
      # 2. update_config is queued and waits
      # 3. slow_noop finishes, update_config starts and updates config
      # 4. update_config finishes

      DummyServer.slow_noop(pid, 50)
      DummyServer.update_config(pid, %{"workspaceSymbols" => %{"minQueryLength" => 0}})

      assert_receive :noop_finished, 100
      assert_receive :update_finished, 100

      # The update should persist, not be overwritten by the slow handler
      assert Configuration.get().workspace_symbols.min_query_length == 0
    end
  end

  defp build_change(settings) do
    %WorkspaceDidChangeConfiguration{
      params: %DidChangeConfigurationParams{
        settings: settings
      }
    }
  end
end
