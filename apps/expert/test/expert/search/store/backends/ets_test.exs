defmodule Expert.Search.Store.Backends.EtsTest do
  use ExUnit.Case, async: false

  import Forge.Test.Fixtures

  alias Expert.Search.Store.Backends.Ets
  alias Forge.Search.Indexer.Entry

  setup do
    project = project()
    Ets.destroy_all(project)

    on_exit(fn -> Ets.destroy_all(project) end)

    {:ok, project: project, runtime_versions: %{erlang: "engine-erlang", elixir: "engine-elixir"}}
  end

  test "incremental writes replace affected paths", %{
    project: project,
    runtime_versions: runtime_versions
  } do
    old_entry = definition(id: 1, subject: EtsBackend.Old, path: "/same.ex")
    new_entry = definition(id: 2, subject: EtsBackend.New, path: "/same.ex")

    {:ok, pid} = Ets.start_link(project, runtime_versions: runtime_versions)
    assert {:ok, :empty} = Ets.prepare(pid)

    assert :ok = Ets.replace_all(project, [old_entry])
    assert {:ok, [1]} = Ets.apply_index_update(project, [new_entry], [])

    assert [] = Ets.find_by_subject(project, EtsBackend.Old, :_, :_)
    assert [^new_entry] = Ets.find_by_subject(project, EtsBackend.New, :_, :_)

    GenServer.stop(pid)
  end

  defp definition(opts) do
    opts = Keyword.validate!(opts, [:id, :subject, path: "/file.ex"])

    %Entry{
      id: Keyword.fetch!(opts, :id),
      subject: Keyword.fetch!(opts, :subject),
      path: Keyword.fetch!(opts, :path),
      type: :module,
      subtype: :definition,
      block_id: :root
    }
  end
end
