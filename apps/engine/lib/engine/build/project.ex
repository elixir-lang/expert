defmodule Engine.Build.Project do
  alias Engine.Build
  alias Engine.Build.Isolation
  alias Engine.Compilation.DependencyTracer
  alias Engine.Compilation.ProjectTracer
  alias Engine.Compilation.Tracers
  alias Engine.Module.Loader
  alias Engine.Plugin
  alias Engine.Progress
  alias Forge.Internet
  alias Forge.Project
  alias Mix.Task.Compiler.Diagnostic

  require Logger

  @dependency_compile_partition_env "MIX_OS_DEPS_COMPILE_PARTITION_COUNT"

  def compile(%Project{kind: :mix} = project, force?) do
    Engine.Mix.in_project(fn project_module ->
      project = Project.set_project_module(project, project_module)
      title = "Building #{Project.display_name(project)}"
      Logger.info(title)

      with_build_progress(title, "Compilation finished", fn token ->
        do_compile(project, force?, token)
      end)
    end)
  end

  def compile(%Project{}, _force?) do
    :ok
  end

  def fetch_deps(%Project{kind: :mix} = project) do
    Engine.Mix.in_project(project, fn project_module ->
      project = Project.set_project_module(project, project_module)
      title = "Fetching dependencies for #{Project.display_name(project)}"
      Logger.info(title)

      with_build_progress(title, "Dependency fetch finished", fn token ->
        prepare_for_project_build(token)
        trace_dependency_compilation(project, token)
        load_plugins(token)
        :ok
      end)
    end)
  end

  def fetch_deps(%Project{}) do
    :ok
  end

  def refresh_runtime(%Project{kind: :mix} = project) do
    Engine.Mix.in_project(project, fn project_module ->
      project = Project.set_project_module(project, project_module)
      title = "Refreshing runtime for #{Project.display_name(project)}"

      Progress.with_progress(title, fn token ->
        {elapsed_ms, result} = timed(fn -> do_refresh_runtime(token) end)
        message = "Runtime refreshed in #{format_duration(elapsed_ms)}"

        {:done, result, message}
      end)
    end)
  rescue
    exception ->
      Logger.warning(
        "Runtime refresh failed: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      {:error, exception}
  catch
    kind, reason ->
      Logger.warning("Runtime refresh failed: #{Exception.format_banner(kind, reason)}")
      {:error, {kind, reason}}
  end

  def refresh_runtime(%Project{}) do
    :ok
  end

  defp with_build_progress(title, final_message_prefix, fun) when is_function(fun, 1) do
    Progress.with_progress(title, fn token ->
      Build.set_progress_token(token)

      try do
        {elapsed_ms, result} = timed(fn -> fun.(token) end)
        message = "#{final_message_prefix} in #{format_duration(elapsed_ms)}"

        {:done, result, message}
      after
        Build.clear_progress_token()
      end
    end)
  end

  defp do_refresh_runtime(token) do
    Progress.report(token, message: "Loading compiled modules...")

    {elapsed_ms, _result} = timed(fn -> maybe_load_modules() end)
    Progress.log_info("Loaded compiled modules in #{format_duration(elapsed_ms)}")

    Progress.report(token, message: "Refreshing code paths...")

    {elapsed_ms, result} =
      timed(fn ->
        Engine.Mix.ensure_hex_and_rebar()
        Mix.Task.run(:loadpaths)
      end)

    Progress.log_info("Refreshed code paths in #{format_duration(elapsed_ms)}")

    result
  end

  defp do_compile(project, force?, token) do
    Mix.Task.clear()

    if force?, do: prepare_for_project_build(token)

    trace_dependency_compilation(project, token)

    if force?, do: load_plugins(token)

    case compile_project(project, force?, token) do
      {:error, diagnostics} ->
        diagnostics =
          diagnostics
          |> List.wrap()
          |> Build.Error.refine_diagnostics()

        {:error, diagnostics}

      {status, diagnostics} when status in [:ok, :noop] ->
        Logger.info(
          "Compile completed with status #{status} " <>
            "Produced #{length(diagnostics)} diagnostics " <>
            inspect(diagnostics)
        )

        Build.Error.refine_diagnostics(diagnostics)
    end
  end

  defp compile_project(project, force?, token) do
    Mix.Task.clear()
    Progress.report(token, message: "Compiling #{Project.display_name(project)}")

    {elapsed_ms, result} =
      timed(fn ->
        Tracers.with_project(project, [ProjectTracer], fn ->
          compile_in_isolation(force?)
        end)
      end)

    message = "mix compile took #{format_duration(elapsed_ms)}"
    log_progress(token, message)

    result
  end

  def maybe_load_modules do
    if Elixir.Features.lazy_loading?() do
      modules_to_load =
        for {mod, _, false} <- :code.all_available() do
          List.to_atom(mod)
        end

      Logger.info("Loading #{length(modules_to_load)} modules")
      Loader.load_all(modules_to_load)
    end
  end

  defp compile_in_isolation(force?) do
    compile_fun = fn ->
      Engine.Mix.ensure_hex_and_rebar()
      Mix.Task.run(:compile, mix_compile_opts(force?))
    end

    case Isolation.invoke(compile_fun) do
      {:ok, result} ->
        result

      {:error, {exception, [{_mod, _fun, _arity, meta} | _]}} ->
        diagnostic = %Diagnostic{
          file: Keyword.get(meta, :file),
          severity: :error,
          message: Exception.message(exception),
          compiler_name: "Elixir",
          position: Keyword.get(meta, :line, 1)
        }

        {:error, [diagnostic]}
    end
  end

  defp prepare_for_project_build(token) do
    if Internet.connected_to_internet?() do
      Progress.report(token, message: "mix local.hex")
      Mix.Task.run("local.hex", ~w(--force --if-missing))

      Progress.report(token, message: "mix local.rebar")
      Mix.Task.run("local.rebar", ~w(--force --if-missing))

      Progress.report(token, message: "mix deps.get")
      Mix.Task.run("deps.get")
    else
      Logger.warning("Could not connect to hex.pm, dependencies will not be fetched")
    end

    Progress.report(token, message: "mix loadconfig")
    Mix.Task.run(:loadconfig)
  end

  defp trace_dependency_compilation(project, token) do
    Progress.report(token, message: "mix deps.loadpaths")

    {elapsed_ms, _result} =
      timed(fn ->
        Tracers.with([DependencyTracer], fn ->
          run_deps_loadpaths_with_clean_project_stack(project)
        end)
      end)

    message = "mix deps.loadpaths took #{format_duration(elapsed_ms)}"
    log_progress(token, message)
  end

  defp run_deps_loadpaths_with_clean_project_stack(project) do
    with_dependency_compile_partitions_serialized(fn ->
      Engine.Mix.in_project_with_clean_stack(project, fn _ ->
        Mix.Task.clear()
        Mix.Dep.clear_cached()
        Mix.Project.clear_deps_cache()
        Mix.Task.rerun("deps.loadpaths")
      end)
    end)
  end

  defp with_dependency_compile_partitions_serialized(fun) when is_function(fun, 0) do
    # As of Elixir 1.20, the compiler options are not propagated to the deps
    # compiler partition workers, so we need to force the partitions to 1
    # to ensure the DependencyTracer runs for every trace event.
    # See https://github.com/elixir-lang/elixir/issues/15457
    original = System.fetch_env(@dependency_compile_partition_env)
    System.put_env(@dependency_compile_partition_env, "1")

    try do
      fun.()
    after
      restore_env(@dependency_compile_partition_env, original)
    end
  end

  defp restore_env(name, {:ok, value}), do: System.put_env(name, value)
  defp restore_env(name, :error), do: System.delete_env(name)

  defp load_plugins(token) do
    Progress.report(token, message: "Loading plugins")
    Plugin.Discovery.run()
  end

  defp mix_compile_opts(force?) do
    opts =
      ~w(
        --return-errors
        --ignore-module-conflict
        --all-warnings
        --docs
        --debug-info
        --no-protocol-consolidation
    )

    # mix compile runs deps.loadpath, which checks and compiles
    # deps under DependencyTracer, before compiling the project code.
    # Skipping the compile-time deps check prevents Mix from compiling any
    # remaining deps later using ProjectTracer instead.
    opts = ["--no-deps-check" | opts]

    if force?, do: ["--force" | opts], else: opts
  end

  defp log_progress(token, message) do
    Progress.log_info(message)
    Progress.report(token, message: message)
  end

  defp timed(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
