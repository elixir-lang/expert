defmodule Engine.Search.Store.Backend do
  @moduledoc """
  A behaviour for search store backends
  """
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @type version :: pos_integer()

  @type priv_state :: term()
  @type load_state :: :empty | :stale
  @type field_name :: atom()
  @type name :: term
  @type metadata :: %{
          schema_version: version(),
          types: [Entry.entry_type()],
          subtypes: [Entry.entry_subtype()]
        }

  @type wildcard :: :_
  @type subject_query :: Entry.subject() | wildcard()
  @type type_query :: Entry.entry_type() | wildcard()
  @type subtype_query :: Entry.entry_subtype() | wildcard()
  @type block_structure :: %{Entry.block_id() => block_structure()} | %{}
  @type path_structures :: %{Path.t() => block_structure()}
  @type accumulator :: any()
  @type reducer_fun :: (Entry.t(), accumulator() -> accumulator())

  @doc """
  Create a new backend.
  This function must return quickly, as it's called from the store process
  """
  @callback new(Project.t()) :: {:ok, priv_state()} | {:error, any()}

  @doc """
  Prepares the backend for use.
  This receives the result of `new/1`, and sets up the store for use. When this function
  returns, the backend is considered ready for use.
  """
  @callback prepare(priv_state()) :: {:ok, load_state()}

  @doc """
  Synchronizes the backend to the file system (optional)
  """
  @callback sync(Project.t()) :: :ok | {:error, any()}

  @doc """
  Inserts all entries into the backend
  """
  @callback insert([Entry.t()]) :: :ok

  @doc """
  Drops all data from the backend, but keeps the underlying structure
  """
  @callback drop() :: boolean()

  @doc """
  Drops all data from the backend, and disposes of any underlying structure
  """
  @callback destroy(Project.t()) :: :ok

  @doc """
  Applies a reducer function to the backend's entries
  """
  @callback reduce(accumulator(), reducer_fun()) :: accumulator()

  @doc """
  Replaces all the entries in the store with those passed in
  """
  @callback replace_all([Entry.t()]) :: :ok

  @doc """
  Deletes all entries whose path is equal to the one passed in.
  """
  @callback delete_by_path(Path.t()) :: {:ok, [Entry.entry_id()]} | {:error, any()}

  @doc """
  Returns the block structure for the given path
  """
  @callback structure_for_path(Path.t()) :: {:ok, block_structure()} | :error

  @doc """
  Finds all entries
  """
  @callback find_by_subject(subject_query(), type_query(), subtype_query()) :: [Entry.t()]

  @doc """
  Finds all entries by prefix
  """
  @callback find_by_prefix(subject_query(), type_query(), subtype_query()) :: [Entry.t()]

  @doc """
  Finds entries whose ref attribute is in the given list
  """
  @callback find_by_ids([Entry.entry_id()], type_query(), subtype_query()) :: [Entry.t()]

  @doc """
  Returns all the sibling elements of the given element.

  Elements are returned in the order they appear in the source
  """
  @callback siblings(Entry.t()) :: [Entry.t()]

  @doc """
  Returns the parent block of the given entry, or :error if there is no parent
  """
  @callback parent(Entry.t()) :: {:ok, Entry.t()} | :error

  @optional_callbacks sync: 1
end
