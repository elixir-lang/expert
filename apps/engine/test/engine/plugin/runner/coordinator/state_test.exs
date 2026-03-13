defmodule Engine.Plugin.Coordinator.StateTest do
  use ExUnit.Case

  alias Engine.Plugin.Runner
  alias Engine.Plugin.Runner.Coordinator.State
  alias Forge.Document
  alias Forge.Plugin.V1

  setup do
    start_supervised!(Runner.Supervisor)

    on_exit(fn ->
      Runner.clear_config()
    end)

    {:ok, state: State.new()}
  end

  test "with no configured plugins" do
    assert {[], _} = State.run_all(%State{}, nil, :diagnostic, 50)
  end

  defmodule FailsInit do
    use V1.Diagnostic, name: :fails_init

    def init do
      {:error, :failed}
    end

    def diagnose(subject) do
      {:ok, [subject]}
    end
  end

  test "a plugin is deactivated if it fails to initialize" do
    assert :error = Runner.register(FailsInit)
    refute :fails_init in Runner.enabled_plugins()
  end

  defmodule Echo do
    use V1.Diagnostic, name: :echo

    def diagnose(subject) do
      {:ok, [subject]}
    end
  end

  defmodule MultipleResults do
    use V1.Diagnostic, name: :multiple_results

    def diagnose(subject) do
      {:ok, [subject, subject]}
    end
  end

  describe "plugins completing successfully" do
    test "results are returned for a single plugin", %{state: state} do
      Runner.register(Echo)
      doc = %Document{}
      assert {[^doc], _} = State.run_all(state, doc, :diagnostic, 50)
    end

    test "results are aggregated for multiple plugins", %{state: state} do
      Runner.register(Echo)
      Runner.register(MultipleResults)

      doc = %Document{}
      assert {[^doc, ^doc, ^doc], _} = State.run_all(state, doc, :diagnostic, 50)
    end
  end

  describe "failure modes" do
    defmodule TimesOut do
      use V1.Diagnostic, name: :times_out

      def diagnose(subject) do
        Process.sleep(5000)
        {:ok, [subject]}
      end
    end

    defmodule Crashes do
      use V1.Diagnostic, name: :crashes

      def diagnose(subject) do
        45 = subject
        {:ok, [subject]}
      end
    end

    defmodule Errors do
      use V1.Diagnostic, name: :errors

      def diagnose(_) do
        {:error, :invalid_subject}
      end
    end

    defmodule BadReturn do
      use V1.Diagnostic, name: :bad_return

      def diagnose(subject) do
        {:ok, subject}
      end
    end

    test "timeouts are logged", %{state: state} do
      Runner.register(TimesOut)

      assert {[], state} = State.run_all(state, %Document{}, :diagnostic, 50)
      assert State.failure_count(state, TimesOut) == 1
    end

    test "crashing plugins are logged", %{state: state} do
      Runner.register(Crashes)
      assert {[], state} = State.run_all(state, %Document{}, :diagnostic, 50)
      assert State.failure_count(state, Crashes) == 1
    end

    test "a plugin that returns an error is logged", %{state: state} do
      Runner.register(Errors)

      assert {[], state} = State.run_all(state, %Document{}, :diagnostic, 50)
      assert State.failure_count(state, Errors) == 1
    end

    test "a plugin that doesn't return a list is logged", %{state: state} do
      Runner.register(BadReturn)

      assert {[], state} = State.run_all(state, %Document{}, :diagnostic, 50)
      assert State.failure_count(state, BadReturn) == 1
    end

    test "a plugin is disabled if it fails 10 times", %{state: state} do
      Runner.register(Crashes)

      assert :crashes in Runner.enabled_plugins()

      Enum.reduce(1..10, state, fn _, state ->
        {_, state} = State.run_all(state, %Document{}, :diagnostic, 50)
        state
      end)

      refute :crashes in Runner.enabled_plugins()
    end
  end
end
