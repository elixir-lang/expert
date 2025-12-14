defmodule Engine do
  @moduledoc """
  The remote control boots another elixir application in a separate VM, injects
  the remote control application into it and allows the language server to execute tasks in the
  context of the remote VM.
  """

  alias Engine.Api.Proxy
  alias Engine.CodeAction
  alias Engine.CodeIntelligence
  alias Engine.Progress
  alias Forge.Project

  require Logger

  @excluded_apps [:patch, :nimble_parsec]
  @allowed_apps [:engine | Mix.Project.deps_apps()] -- @excluded_apps

  defdelegate schedule_compile(force?), to: Proxy

  defdelegate compile_document(document), to: Proxy

  defdelegate format(document), to: Proxy

  defdelegate reindex, to: Proxy

  defdelegate index_running?, to: Proxy

  defdelegate broadcast(message), to: Proxy

  defdelegate expand_alias(segments_or_module, analysis, position), to: Engine.Analyzer

  defdelegate list_modules, to: :code, as: :all_available

  defdelegate code_actions(document, range, diagnostics, kinds, trigger_kind),
    to: CodeAction,
    as: :for_range

  defdelegate complete(env), to: Engine.Completion, as: :elixir_sense_expand

  defdelegate complete_struct_fields(analysis, position),
    to: Engine.Completion,
    as: :struct_fields

  defdelegate definition(document, position), to: CodeIntelligence.Definition

  defdelegate references(analysis, position, include_definitions?),
    to: CodeIntelligence.References

  defdelegate modules_with_prefix(prefix), to: Engine.Modules, as: :with_prefix

  defdelegate modules_with_prefix(prefix, predicate), to: Engine.Modules, as: :with_prefix

  defdelegate docs(module, opts \\ []), to: CodeIntelligence.Docs, as: :for_module

  defdelegate register_listener(listener_pid, message_types), to: Engine.Dispatch

  defdelegate resolve_entity(analysis, position), to: CodeIntelligence.Entity, as: :resolve

  defdelegate struct_definitions, to: CodeIntelligence.Structs, as: :for_project

  defdelegate document_symbols(document), to: CodeIntelligence.Symbols, as: :for_document

  defdelegate workspace_symbols(query), to: CodeIntelligence.Symbols, as: :for_workspace

  def list_apps do
    for {app, _, _} <- :application.loaded_applications(),
        not Forge.Namespace.Module.prefixed?(app),
        do: app
  end

  def ensure_apps_started(token \\ Progress.noop_token()) do
    apps_to_start = [:elixir, :runtime_tools | @allowed_apps]

    Enum.reduce_while(apps_to_start, :ok, fn app_name, _ ->
      Progress.report(token, message: "Starting #{app_name}...")

      case :application.ensure_all_started(app_name) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def deps_paths do
    case :persistent_term.get({__MODULE__, :deps_paths}, :error) do
      :error ->
        {:ok, deps_paths} =
          Engine.Mix.in_project(fn _ ->
            Mix.Task.run("loadpaths")
            Mix.Project.deps_paths()
          end)

        :persistent_term.put({__MODULE__, :deps_paths}, deps_paths)
        deps_paths

      deps_paths ->
        deps_paths
    end
  end

  def with_lock(lock_type, func) do
    :global.trans({lock_type, self()}, func, [Node.self()])
  end

  def project_node? do
    !!:persistent_term.get({__MODULE__, :project}, false)
  end

  def get_project do
    :persistent_term.get({__MODULE__, :project}, nil)
  end

  def set_project(%Project{} = project) do
    :persistent_term.put({__MODULE__, :project}, project)
  end
end
