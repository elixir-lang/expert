defmodule Expert.EngineApi do
  alias Expert.ProjectNode
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project

  alias Forge.CodeIntelligence

  require Logger

  def start_link(%Project{} = project) do
    :ok = ensure_epmd_started()
    start_net_kernel(project)

    node = Project.node_name(project)

    with {:ok, node_pid} <- ProjectNode.start(project, glob_paths()),
         :ok <- ensure_apps_started(node) do
      {:ok, node, node_pid}
    end
  end

  defp start_net_kernel(%Project{} = project) do
    manager = Project.manager_node_name(project)
    :net_kernel.start(manager, %{name_domain: :longnames})
  end

  defp ensure_apps_started(node) do
    :rpc.call(node, Engine, :ensure_apps_started, [])
  end

  defp ensure_epmd_started do
    case System.cmd("epmd", ~w(-daemon)) do
      {"", 0} ->
        :ok

      _ ->
        {:error, :epmd_failed}
    end
  end

  def call(%Project{} = project, m, f, a \\ []) do
    project
    |> Project.node_name()
    |> :erpc.call(m, f, a)
  end

  def elixir_executable(%Project{} = project) do
    root_path = Project.root_path(project)

    {path_result, env} =
      with nil <- version_manager_path_and_env("asdf", root_path),
           nil <- version_manager_path_and_env("mise", root_path),
           nil <- version_manager_path_and_env("rtx", root_path) do
        {File.cd!(root_path, fn -> System.find_executable("elixir") end), System.get_env()}
      end

    case path_result do
      nil ->
        {:error, :no_elixir}

      executable when is_binary(executable) ->
        {:ok, executable, env}
    end
  end

  @excluded_apps [:patch, :nimble_parsec]
  @allowed_apps [:engine | Mix.Project.deps_apps()] -- @excluded_apps

  defp app_globs do
    app_globs = Enum.map(@allowed_apps, fn app_name -> "/**/#{app_name}*/ebin" end)
    ["/**/priv" | app_globs]
  end

  def glob_paths do
    for entry <- :code.get_path(),
        entry_string = List.to_string(entry),
        entry_string != ".",
        Enum.any?(app_globs(), &PathGlob.match?(entry_string, &1, match_dot: true)) do
      entry
    end
  end

  defp version_manager_path_and_env(manager, root_path) do
    with true <- is_binary(System.find_executable(manager)),
         env = reset_env(manager, root_path),
         {path, 0} <- System.cmd(manager, ~w(which elixir), cd: root_path, env: env) do
      {String.trim(path), env}
    else
      _ ->
        nil
    end
  end

  # We launch expert by asking the version managers to provide an environment,
  # which contains path munging. This initial environment is present in the running
  # VM, and needs to be undone so we can find the correct elixir executable in the project.
  defp reset_env("asdf", _root_path) do
    orig_path = System.get_env("PATH_SAVE", System.get_env("PATH"))

    Enum.map(System.get_env(), fn
      {"ASDF_ELIXIR_VERSION", _} -> {"ASDF_ELIXIR_VERSION", nil}
      {"ASDF_ERLANG_VERSION", _} -> {"ASDF_ERLANG_VERSION", nil}
      {"PATH", _} -> {"PATH", orig_path}
      other -> other
    end)
  end

  defp reset_env("rtx", root_path) do
    {env, _} = System.cmd("rtx", ~w(env -s bash), cd: root_path)

    env
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(fn
      "export " <> key_and_value ->
        [key, value] =
          key_and_value
          |> String.split("=", parts: 2)
          |> Enum.map(&String.trim/1)

        {key, value}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp reset_env("mise", root_path) do
    {env, _} = System.cmd("mise", ~w(env -s bash), cd: root_path)

    env
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(fn
      "export " <> key_and_value ->
        [key, value] =
          key_and_value
          |> String.split("=", parts: 2)
          |> Enum.map(&String.trim/1)

        {key, value}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def schedule_compile(%Project{} = project, force?) do
    call(project, Engine, :schedule_compile, [force?])
  end

  def compile_document(%Project{} = project, %Document{} = document) do
    call(project, Engine, :compile_document, [document])
  end

  def expand_alias(
        %Project{} = project,
        segments_or_module,
        %Analysis{} = analysis,
        %Position{} = position
      ) do
    call(project, Engine, :expand_alias, [
      segments_or_module,
      analysis,
      position
    ])
  end

  def list_modules(%Project{} = project) do
    call(project, Engine, :list_modules)
  end

  def project_apps(%Project{} = project) do
    call(project, Engine, :list_apps)
  end

  def format(%Project{} = project, %Document{} = document) do
    call(project, Engine, :format, [document])
  end

  def code_actions(
        %Project{} = project,
        %Document{} = document,
        %Range{} = range,
        diagnostics,
        kinds,
        trigger_kind
      ) do
    call(project, Engine, :code_actions, [
      document,
      range,
      diagnostics,
      kinds,
      trigger_kind
    ])
  end

  def complete(%Project{} = project, %Env{} = env) do
    Logger.info("Completion for #{inspect(env.position)}")
    call(project, Engine, :complete, [env])
  end

  def complete_struct_fields(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    call(project, Engine, :complete_struct_fields, [
      analysis,
      position
    ])
  end

  def definition(%Project{} = project, %Document{} = document, %Position{} = position) do
    call(project, Engine, :definition, [document, position])
  end

  def references(
        %Project{} = project,
        %Analysis{} = analysis,
        %Position{} = position,
        include_definitions?
      ) do
    call(project, Engine, :references, [
      analysis,
      position,
      include_definitions?
    ])
  end

  def modules_with_prefix(%Project{} = project, prefix)
      when is_binary(prefix) or is_atom(prefix) do
    call(project, Engine, :modules_with_prefix, [prefix])
  end

  def modules_with_prefix(%Project{} = project, prefix, predicate)
      when is_binary(prefix) or is_atom(prefix) do
    call(project, Engine, :modules_with_prefix, [prefix, predicate])
  end

  @spec docs(Project.t(), module()) :: {:ok, CodeIntelligence.Docs.t()} | {:error, any()}
  def docs(%Project{} = project, module, opts \\ []) when is_atom(module) do
    call(project, Engine, :docs, [module, opts])
  end

  def register_listener(%Project{} = project, listener_pid, message_types)
      when is_pid(listener_pid) and is_list(message_types) do
    call(project, Engine, :register_listener, [
      listener_pid,
      message_types
    ])
  end

  def broadcast(%Project{} = project, message) do
    call(project, Engine, :broadcast, [message])
  end

  def reindex(%Project{} = project) do
    call(project, Engine, :reindex, [])
  end

  def index_running?(%Project{} = project) do
    call(project, Engine, :index_running?, [])
  end

  def resolve_entity(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    call(project, Engine, :resolve_entity, [analysis, position])
  end

  def struct_definitions(%Project{} = project) do
    call(project, Engine, :struct_definitions, [])
  end

  def document_symbols(%Project{} = project, %Document{} = document) do
    call(project, Engine, :document_symbols, [document])
  end

  def workspace_symbols(%Project{} = project, query) do
    call(project, Engine, :workspace_symbols, [query])
  end

  defdelegate stop(project), to: ProjectNode
end
