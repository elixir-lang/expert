defmodule Expert.Search.Store.Backend do
  @moduledoc """
  Behaviour for project-scoped search store backends.
  """

  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @type version :: pos_integer()
  @type priv_state :: term()
  @type load_state :: :empty | :stale
  @type field_name :: atom()
  @type name :: term()
  @type wildcard :: :_
  @type subject_query :: Entry.subject() | wildcard()
  @type type_query :: Entry.entry_type() | wildcard()
  @type subtype_query :: Entry.entry_subtype() | wildcard()
  @type block_structure :: %{Entry.block_id() => block_structure()} | %{}
  @type accumulator :: any()
  @type reducer_fun :: (Entry.t(), accumulator() -> accumulator())

  @callback new(Project.t()) :: {:ok, priv_state()} | {:error, any()}
  @callback prepare(priv_state()) :: {:ok, load_state()} | {:error, any()}
  @callback sync(Project.t()) :: :ok | {:error, any()}
  @callback insert(Project.t(), [Entry.t()]) :: :ok
  @callback drop(Project.t()) :: boolean() | :ok
  @callback destroy(Project.t()) :: :ok
  @callback reduce(Project.t(), accumulator(), reducer_fun()) :: accumulator()
  @callback replace_all(Project.t(), [Entry.t()]) :: :ok
  @callback delete_by_path(Project.t(), Path.t()) :: {:ok, [Entry.entry_id()]} | {:error, any()}
  @callback structure_for_path(Project.t(), Path.t()) :: {:ok, block_structure()} | :error
  @callback find_by_subject(Project.t(), subject_query(), type_query(), subtype_query()) :: [
              Entry.t()
            ]
  @callback find_by_prefix(Project.t(), subject_query(), type_query(), subtype_query()) :: [
              Entry.t()
            ]
  @callback find_by_ids(Project.t(), [Entry.entry_id()], type_query(), subtype_query()) :: [
              Entry.t()
            ]
  @callback siblings(Project.t(), Entry.t()) :: [Entry.t()] | :error | {:ok, [Entry.t()]}
  @callback parent(Project.t(), Entry.t()) :: {:ok, Entry.t()} | :error

  @optional_callbacks sync: 1
end
