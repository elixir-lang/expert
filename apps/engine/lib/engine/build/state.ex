defmodule Engine.Build.State do
  alias Elixir.Features
  alias Engine.Build
  alias Engine.Compilation.Tracer
  alias Engine.Plugin
  alias Engine.Progress
  alias Forge.Document
  alias Forge.EngineApi.Messages
  alias Forge.Project
  alias Forge.VM.Versions

  require Logger

  import Messages

  defstruct project: nil,
            build_number: 0,
            uri_to_document: %{},
            project_compile: :none

  def new(%Project{} = project) do
    %__MODULE__{project: project}
  end

  def on_timeout(%__MODULE__{} = state) do
    new_state =
      case state.project_compile do
        :none -> state
        :force -> compile_project(state, true)
        :normal -> compile_project(state, false)
      end

    # We need to compile the individual documents even after the project is
    # compiled because they might have unsaved changes, and we want that state
    # to be the latest state of the project.
    new_state =
      Enum.reduce(new_state.uri_to_document, state, fn {_uri, document}, state ->
        compile_file(state, document)
      end)

    %{new_state | uri_to_document: %{}, project_compile: :none}
  end

  def on_file_compile(%__MODULE__{} = state, %Document{} = document) do
    %__MODULE__{
      state
      | uri_to_document: Map.put(state.uri_to_document, document.uri, document)
    }
  end

  def on_project_compile(%__MODULE__{} = state, force?) do
    if force? do
      %__MODULE__{state | project_compile: :force}
    else
      %__MODULE__{state | project_compile: :normal}
    end
  end

  def ensure_build_directory(%__MODULE__{} = state) do
    # If the project directory isn't there, for some reason the main build fails, so we create it here
    # to ensure that the build will succeed.
    project = state.project
    build_path = Project.versioned_build_path(project)

    unless Versions.compatible?(build_path) do
      Logger.info("Build path #{build_path} was compiled on a previous erlang version. Deleting")

      if File.exists?(build_path) do
        File.rm_rf(build_path)
      end
    end

    maybe_delete_old_builds(project)

    unless File.exists?(build_path) do
      File.mkdir_p!(build_path)
      Versions.write(build_path)
    end
  end

  defp compile_project(%__MODULE__{} = state, initial?) do
    state = increment_build_number(state)
    project = state.project

    Build.with_lock(fn ->
      work_done_token = Progress.begin(building_label(project))

      try do
        compile_requested_message =
          project_compile_requested(project: project, build_number: state.build_number)

        Engine.broadcast(compile_requested_message)
        {elapsed_us, result} = :timer.tc(fn -> Build.Project.compile(project, initial?) end)
        elapsed_ms = to_ms(elapsed_us)

        {compile_message, diagnostics} =
          case result do
            :ok ->
              message =
                project_compiled(status: :success, project: project, elapsed_ms: elapsed_ms)

              {message, []}

            {:ok, diagnostics} ->
              message =
                project_compiled(status: :success, project: project, elapsed_ms: elapsed_ms)

              {message, List.wrap(diagnostics)}

            {:error, diagnostics} ->
              message = project_compiled(status: :error, project: project, elapsed_ms: elapsed_ms)

              {message, List.wrap(diagnostics)}
          end

        diagnostics_message =
          project_diagnostics(
            project: project,
            build_number: state.build_number,
            diagnostics: diagnostics
          )

        Engine.broadcast(compile_message)
        Engine.broadcast(diagnostics_message)
        Plugin.diagnose(project, state.build_number)
      after
        Tracer.clear_build_token()
        Progress.complete(work_done_token)
      end
    end)

    state
  end

  def compile_file(%__MODULE__{} = state, %Document{} = document) do
    state = increment_build_number(state)
    project = state.project

    Build.with_lock(fn ->
      Engine.broadcast(file_compile_requested(uri: document.uri))

      safe_compile_func = fn ->
        Engine.Mix.in_project(fn _ -> Build.Document.compile(document) end)
      end

      {elapsed_us, result} = :timer.tc(fn -> safe_compile_func.() end)

      elapsed_ms = to_ms(elapsed_us)

      {compile_message, diagnostics} =
        case result do
          {:ok, diagnostics} ->
            message =
              file_compiled(
                project: project,
                build_number: state.build_number,
                status: :success,
                uri: document.uri,
                elapsed_ms: elapsed_ms
              )

            {message, diagnostics}

          {:error, diagnostics} ->
            message =
              file_compiled(
                project: project,
                build_number: state.build_number,
                status: :error,
                uri: document.uri,
                elapsed_ms: elapsed_ms
              )

            {message, diagnostics}
        end

      diagnostics =
        file_diagnostics(
          project: project,
          build_number: state.build_number,
          uri: document.uri,
          diagnostics: List.wrap(diagnostics)
        )

      Engine.broadcast(compile_message)
      Engine.broadcast(diagnostics)
      Plugin.diagnose(project, state.build_number, document)
    end)

    state
  end

  def set_compiler_options do
    Code.compiler_options(
      parser_options: parser_options(),
      tracers: [Engine.Compilation.Tracer]
    )

    :ok
  end

  def mix_compile_opts(initial?) do
    opts = ~w(
        --return-errors
        --ignore-module-conflict
        --all-warnings
        --docs
        --debug-info
        --no-protocol-consolidation
    )

    if initial? do
      ["--force " | opts]
    else
      opts
    end
  end

  def building_label(%Project{} = project) do
    "Building #{Project.display_name(project)}"
  end

  defp to_ms(microseconds) do
    microseconds / 1000
  end

  defp parser_options do
    [columns: true, token_metadata: true]
  end

  defp increment_build_number(%__MODULE__{} = state) do
    %__MODULE__{state | build_number: state.build_number + 1}
  end

  @two_month_seconds 86_400 * 31 * 2
  defp maybe_delete_old_builds(%Project{} = project) do
    build_root = Project.build_path(project)
    two_months_ago = System.system_time(:second) - @two_month_seconds

    case File.ls(build_root) do
      {:ok, entries} ->
        for file_name <- entries,
            absolute_path = Path.join(build_root, file_name),
            File.dir?(absolute_path),
            newest_beam_mtime(absolute_path) <=
              two_months_ago do
          File.rm_rf!(absolute_path)
        end

      _ ->
        :ok
    end
  end

  defp newest_beam_mtime(directory) do
    directory
    |> Path.join("**/*.beam")
    |> Path.wildcard()
    |> then(fn
      [] ->
        0

      beam_files ->
        beam_files
        |> Enum.map(&File.stat!(&1, time: :posix).mtime)
        |> Enum.max()
    end)
  end
end
