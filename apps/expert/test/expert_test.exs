defmodule Expert.ExpertTest do
  use ExUnit.Case, async: true
  use Patch

  describe "handle_request/2" do
    test "it replies with server_not_initialized on initialization error" do
      reason = :something_bad

      patch(Expert.State, :initialize, fn _state, _request ->
        {:error, reason}
      end)

      assigns = start_supervised!(GenLSP.Assigns, id: make_ref())
      GenLSP.Assigns.merge(assigns, %{state: %{}})

      initialize_request = %GenLSP.Requests.Initialize{id: 1}
      lsp = %GenLSP.LSP{mod: Expert, assigns: assigns}

      {:reply, response, _lsp} = Expert.handle_request(initialize_request, lsp)

      message = to_string(reason)
      error_code = GenLSP.Enumerations.ErrorCodes.server_not_initialized()

      assert %GenLSP.ErrorResponse{code: ^error_code, data: nil, message: ^message} = response
    end
  end
end
