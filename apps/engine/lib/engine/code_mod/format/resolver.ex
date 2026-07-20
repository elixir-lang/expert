defmodule Engine.CodeMod.Format.Resolver do
  @moduledoc """
  Resolves the formatter function and options for a file.

  Resolution is uncached and evaluates the governing `.formatter.exs`;
  callers should go through `Engine.CodeMod.Format.Cache.fetch_formatter/2`
  instead.
  """

  alias Elixir.Features
  alias Engine.CodeMod.Format
  alias Forge.Project

  require Logger

  @built_in_locals_without_parens [
    # Special forms
    alias: 1,
    alias: 2,
    case: 2,
    cond: 1,
    for: :*,
    import: 1,
    import: 2,
    quote: 1,
    quote: 2,
    receive: 1,
    require: 1,
    require: 2,
    try: 1,
    with: :*,

    # Kernel
    def: 1,
    def: 2,
    defp: 1,
    defp: 2,
    defguard: 1,
    defguardp: 1,
    defmacro: 1,
    defmacro: 2,
    defmacrop: 1,
    defmacrop: 2,
    defmodule: 2,
    defdelegate: 2,
    defexception: 1,
    defoverridable: 1,
    defstruct: 1,
    destructure: 2,
    raise: 1,
    raise: 2,
    reraise: 2,
    reraise: 3,
    if: 2,
    unless: 2,
    use: 1,
    use: 2,

    # Stdlib,
    defrecord: 2,
    defrecord: 3,
    defrecordp: 2,
    defrecordp: 3,

    # Testing
    assert: 1,
    assert: 2,
    assert_in_delta: 3,
    assert_in_delta: 4,
    assert_raise: 2,
    assert_raise: 3,
    assert_receive: 1,
    assert_receive: 2,
    assert_receive: 3,
    assert_received: 1,
    assert_received: 2,
    doctest: 1,
    doctest: 2,
    refute: 1,
    refute: 2,
    refute_in_delta: 3,
    refute_in_delta: 4,
    refute_receive: 1,
    refute_receive: 2,
    refute_receive: 3,
    refute_received: 1,
    refute_received: 2,
    setup: 1,
    setup: 2,
    setup_all: 1,
    setup_all: 2,
    test: 1,
    test: 2,

    # Mix config
    config: 2,
    config: 3,
    import_config: 1
  ]

  @spec resolve(Project.t(), Path.t()) :: {Format.formatter_function(), keyword()}
  def resolve(%Project{} = project, file_path) do
    fetch_formatter = fn _ -> Mix.Tasks.Format.formatter_for_file(file_path) end

    {formatter_function, opts} =
      if Engine.project_node?() do
        case mix_formatter_from_task(project, file_path) do
          {:ok, result} ->
            result

          :error ->
            formatter_opts =
              case find_formatter_exs(project, file_path) do
                {:ok, opts} ->
                  opts

                :error ->
                  Logger.warning("Could not find formatter options for file #{file_path}")
                  []
              end

            formatter = fn source ->
              formatted_source = Code.format_string!(source, formatter_opts)
              IO.iodata_to_binary([formatted_source, ?\n])
            end

            {formatter, formatter_opts}
        end
      else
        fetch_formatter.(nil)
      end

    opts =
      Keyword.update(
        opts,
        :locals_without_parens,
        @built_in_locals_without_parens,
        &(@built_in_locals_without_parens ++ &1)
      )

    {wrap_with_try_catch(formatter_function), opts}
  end

  defp wrap_with_try_catch(formatter_fn) do
    fn code ->
      try do
        {:ok, formatter_fn.(code)}
      rescue
        e -> {:error, e}
      end
    end
  end

  defp find_formatter_exs(%Project{} = project, file_path) do
    root_dir = Project.root_path(project)
    do_find_formatter_exs(root_dir, file_path)
  end

  defp do_find_formatter_exs(root_path, root_path) do
    formatter_exs_contents(root_path)
  end

  defp do_find_formatter_exs(root_path, current_path) do
    if File.exists?(current_path) do
      with :error <- formatter_exs_contents(current_path) do
        parent =
          current_path
          |> Path.join("..")
          |> Path.expand()

        do_find_formatter_exs(root_path, parent)
      end
    else
      # the current path doesn't exist, it doesn't make sense to keep looking
      # for the .formatter.exs in its parents. Look for one in the root directory
      do_find_formatter_exs(root_path, Path.join(root_path, ".formatter.exs"))
    end
  end

  defp formatter_exs_contents(current_path) do
    formatter_exs = Path.join(current_path, ".formatter.exs")

    with true <- File.exists?(formatter_exs),
         {formatter_terms, _binding} <- Code.eval_file(formatter_exs) do
      {:ok, formatter_terms}
    else
      _ ->
        :error
    end
  end

  defp mix_formatter_from_task(%Project{} = project, file_path) do
    root_path = Project.root_path(project)
    deps_paths = Engine.deps_paths()

    task_module =
      if Features.formatter_has_plugin_loader?() do
        Mix.Tasks.Format
      else
        Mix.Tasks.Future.Format
      end

    formatter_and_opts =
      task_module.formatter_for_file(file_path,
        root: root_path,
        deps_paths: deps_paths,
        plugin_loader: fn plugins -> Enum.filter(plugins, &Code.ensure_loaded?/1) end
      )

    {:ok, formatter_and_opts}
  rescue
    ex ->
      Logger.error("Cannot find formatter due to: #{inspect(ex)}")
      :error
  end
end
