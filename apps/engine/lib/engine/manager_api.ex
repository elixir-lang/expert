defmodule Engine.ManagerApi do
  @moduledoc """
  Engine-node API for operations owned by the manager node.
  """

  alias Engine.Dispatch
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @search_timeout 5_000

  @spec search_store_replace(Project.t(), [Entry.t()]) :: :ok | {:error, term()}
  def search_store_replace(%Project{} = project, entries) do
    Dispatch.erpc_call(Expert.Search.Store, :replace, [project, entries], :infinity)
  end

  @spec search_store_update(Project.t(), Path.t(), [Entry.t()]) :: :ok | {:error, term()}
  def search_store_update(%Project{} = project, path, entries) do
    Dispatch.erpc_call(Expert.Search.Store, :update, [project, path, entries], :infinity)
  end

  @spec search_store_clear(Project.t(), Path.t()) :: :ok | {:error, term()}
  def search_store_clear(%Project{} = project, path) do
    Dispatch.erpc_call(Expert.Search.Store, :clear, [project, path])
  end

  @spec search_store_exact(Project.t(), Entry.subject_query(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def search_store_exact(%Project{} = project, subject \\ :_, constraints) do
    Dispatch.erpc_call(
      Expert.Search.Store,
      :exact,
      [project, subject, constraints],
      @search_timeout
    )
  end

  @spec search_store_prefix(Project.t(), String.t(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def search_store_prefix(%Project{} = project, prefix, constraints) do
    Dispatch.erpc_call(
      Expert.Search.Store,
      :prefix,
      [project, prefix, constraints],
      @search_timeout
    )
  end

  @spec search_store_fuzzy(Project.t(), Entry.subject(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def search_store_fuzzy(%Project{} = project, subject, constraints) do
    Dispatch.erpc_call(
      Expert.Search.Store,
      :fuzzy,
      [project, subject, constraints],
      @search_timeout
    )
  end

  @spec search_store_all(Project.t(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def search_store_all(%Project{} = project, constraints \\ []) do
    Dispatch.erpc_call(Expert.Search.Store, :all, [project, constraints], @search_timeout)
  end
end
