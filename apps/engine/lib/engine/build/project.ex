defmodule Engine.Build.Project do
  alias Engine.Build
  alias Engine.Build.Isolation
  alias Engine.Plugin
  alias Engine.Progress
  alias Forge.Project
  alias Mix.Task.Compiler.Diagnostic

  require Logger

  def compile(%Project{} = project, initial?) do
    Engine.Mix.in_project(fn _ ->
      Logger.info("Building #{Project.display_name(project)}")

      Progress.with_progress("Building #{Project.display_name(project)}", fn token ->
        Build.set_progress_token(token)

        try do
          {:done, do_compile(project, initial?, token)}
        after
          Build.clear_progress_token()
        end
      end)
    end)
  end

  defp do_compile(project, initial?, token) do
    Mix.Task.clear()

    if initial?, do: prepare_for_project_build(token)

    compile_fun = fn ->
      Mix.Task.clear()
      Progress.report(token, message: "Compiling #{Project.display_name(project)}")
      result = compile_in_isolation()
      Mix.Task.run(:loadpaths)
      result
    end

    case compile_fun.() do
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

  defp compile_in_isolation do
    compile_fun = fn -> Mix.Task.run(:compile, mix_compile_opts()) end

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
    if connected_to_internet?() do
      Progress.report(token, message: "mix local.hex")
      Mix.Task.run("local.hex", ~w(--force))

      Progress.report(token, message: "mix local.rebar")
      Mix.Task.run("local.rebar", ~w(--force))

      Progress.report(token, message: "mix deps.get")
      Mix.Task.run("deps.get")
    else
      Logger.warning("Could not connect to hex.pm, dependencies will not be fetched")
    end

    Progress.report(token, message: "mix loadconfig")
    Mix.Task.run(:loadconfig)

    if not Elixir.Features.compile_keeps_current_directory?() do
      Progress.report(token, message: "mix deps.compile")
      Mix.Task.run("deps.safe_compile", ~w(--skip-umbrella-children))
    end

    Progress.report(token, message: "Loading plugins")
    Plugin.Discovery.run()
  end

  defp connected_to_internet? do
    # While there's no perfect way to check if a computer is connected to the internet,
    # it seems reasonable to gate pulling dependencies on a resolution check for hex.pm.
    # Yes, it's entirely possible that the DNS server is local, and that the entry is in cache,
    # but that's an edge case, and the build will just time out anyways.
    case :inet_res.getbyname(~c"hex.pm", :a, 250) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp mix_compile_opts do
    ~w(
        --return-errors
        --ignore-module-conflict
        --all-warnings
        --docs
        --debug-info
        --no-protocol-consolidation
    )
  end
end
