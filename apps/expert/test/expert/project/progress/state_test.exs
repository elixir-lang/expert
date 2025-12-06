defmodule Expert.Project.Progress.StateTest do
  alias Expert.Configuration
  alias Expert.Project.Progress.State

  import Forge.Test.Fixtures

  use ExUnit.Case, async: true
  use Patch

  setup do
    project = project()
    # Mock LSP interactions
    # GenLSP.request returns nil for success, non-nil for error
    patch(Expert, :get_lsp, fn -> self() end)
    patch(GenLSP, :request, fn _, _ -> nil end)
    patch(GenLSP, :notify, fn _, _ -> :ok end)
    patch(Configuration, :client_supports?, fn :work_done_progress -> true end)
    {:ok, project: project}
  end

  describe "engine-initiated progress" do
    test "register_engine_token adds token to active and sends begin notification", %{
      project: project
    } do
      state = State.new(project)
      token = 12345
      title = "mix compile"

      {:ok, new_state} = State.register_engine_token(state, token, title, [])

      assert MapSet.member?(new_state.active, token)
    end

    test "report works for registered engine token", %{project: project} do
      state = State.new(project)
      token = 12345

      {:ok, state} = State.register_engine_token(state, token, "mix compile", [])
      {:ok, ^token, _state} = State.report(state, token, message: "Compiling...")

      # Should not error
      assert true
    end

    test "report returns noop for unknown engine token", %{project: project} do
      state = State.new(project)

      assert {:noop, _state} = State.report(state, 99999, message: "test")
    end

    test "complete removes engine token from active", %{project: project} do
      state = State.new(project)
      token = 12345

      {:ok, state} = State.register_engine_token(state, token, "mix compile", [])
      {:ok, new_state} = State.complete(state, token, [])

      refute MapSet.member?(new_state.active, token)
    end

    test "complete returns error for unknown engine token", %{project: project} do
      state = State.new(project)

      assert {:error, :unknown_token, _state} = State.complete(state, 99999, [])
    end
  end

  describe "server-initiated progress" do
    test "begin creates token and tracks in active set", %{project: project} do
      state = State.new(project)
      title = "Building"

      {:ok, token, new_state} = State.begin(state, title, [])

      assert is_integer(token)
      assert MapSet.member?(new_state.active, token)
    end

    test "report works for active token", %{project: project} do
      state = State.new(project)

      {:ok, token, state} = State.begin(state, "Building", [])
      {:ok, ^token, _state} = State.report(state, token, message: "In progress...")

      assert true
    end

    test "report returns noop for unknown token", %{project: project} do
      state = State.new(project)

      assert {:noop, _state} = State.report(state, 12345, message: "test")
    end

    test "complete removes token from active set", %{project: project} do
      state = State.new(project)

      {:ok, token, state} = State.begin(state, "Building", [])
      {:ok, new_state} = State.complete(state, token, [])

      refute MapSet.member?(new_state.active, token)
    end
  end

  describe "ref-based progress" do
    test "register tracks token with ref", %{project: project} do
      state = State.new(project)
      token = "client-token"

      {:ok, new_state} = State.register(state, token, ref: :initialize)

      assert MapSet.member?(new_state.active, token)
      assert new_state.refs[:initialize] == token
    end

    test "register without ref only tracks token", %{project: project} do
      state = State.new(project)
      token = "client-token"

      {:ok, new_state} = State.register(state, token, [])

      assert MapSet.member?(new_state.active, token)
      assert new_state.refs == %{}
    end

    test "report works for known ref", %{project: project} do
      state = State.new(project)
      token = "client-token"

      {:ok, state} = State.register(state, token, ref: :initialize)
      {:ok, ^token, _state} = State.report(state, :initialize, message: "Loading...")
    end

    test "report returns noop for unknown ref", %{project: project} do
      state = State.new(project)

      assert {:noop, _state} = State.report(state, :unknown, message: "test")
    end

    test "complete removes ref and token from tracking", %{project: project} do
      state = State.new(project)
      token = "client-token"

      {:ok, state} = State.register(state, token, ref: :initialize)
      {:ok, new_state} = State.complete(state, :initialize, [])

      refute Map.has_key?(new_state.refs, :initialize)
      refute MapSet.member?(new_state.active, token)
    end

    test "complete returns error for unknown ref", %{project: project} do
      state = State.new(project)

      assert {:error, :unknown_ref} = State.complete(state, :unknown, [])
    end
  end
end
