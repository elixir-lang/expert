Mix.install([:benchee])

alias Forge.Project

alias Engine.Search.Store.Backends.Ets
alias Engine.Search.Store.Backends.Ets.Schema
alias Engine.Search.Store.Backends.Ets.Schemas
alias Forge.VM.Versions

defmodule BenchHelper do
  def wait_for_registration do
    case :global.registered_names() do
      [] ->
        Process.sleep(100)
        wait_for_registration()

      _ ->
        :ok
    end
  end

  def random_path(entries) do
    Enum.random(entries).path
  end

  def random_id(entries) do
    Enum.random(entries).id
  end

  def random_ids(entries, count) do
    entries
    |> Enum.take_random(count)
    |> Enum.map(& &1.id)
  end
end

cwd = __DIR__
project = Project.new("file://#{cwd}")

Engine.set_project(project)
Project.ensure_workspace(project)

versions = Versions.current()
indexes_path = Project.workspace_path(project, ["indexes", versions.erlang, versions.elixir])
data_dir = Path.join(cwd, "data")

File.mkdir_p!(indexes_path)
File.cp_r!(data_dir, indexes_path)

{:ok, ets} = Ets.start_link(project)

BenchHelper.wait_for_registration()
Ets.prepare(ets)

entries = Ets.select_all()

Benchee.run(
  %{
    "find_by_subject" => fn _ ->
      Ets.find_by_subject(Enum, :module, :reference)
    end,
    "find_by_subject, type_wildcard" => fn _ ->
      Ets.find_by_subject(Enum, :_, :reference)
    end,
    "find_by_subject, subtype_wildcard" => fn _ ->
      Ets.find_by_subject(Enum, :module, :_)
    end,
    "find_by_subject, two wildcards" => fn _ ->
      Ets.find_by_subject(Enum, :_, :_)
    end,
    "find_by_references" => fn %{ids: ids} ->
      Ets.find_by_ids(ids, :module, :_)
    end,
    "delete_by_path" => fn %{path: path} ->
      Ets.delete_by_path(path)
    end
  },
  before_each: fn _ ->
    ids = BenchHelper.random_ids(entries, 50)
    path = BenchHelper.random_path(entries)
    %{path: path, ids: ids}
  end
)

File.rm_rf(Project.workspace_path(project))
