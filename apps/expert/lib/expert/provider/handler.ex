defmodule Expert.Provider.Handler do
  @moduledoc """
  Behaviour for LSP request and notification handlers.
  """

  @doc """
  Handles an LSP request or notification.

  Returns `{:ok, response}` on success, or `{:error, reason}` on failure.
  For notifications that don't require a response, return `{:ok, nil}`.
  """
  @callback handle(request :: struct()) :: {:ok, term()} | {:error, term()}
end
