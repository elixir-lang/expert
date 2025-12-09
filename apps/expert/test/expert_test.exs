defmodule Expert.ExpertTest do
  use ExUnit.Case, async: false
  use Patch

  import Expert.Test.Protocol.TransportSupport

  test "sends an error message on engine initialization error" do
    with_patched_transport()

    assigns = start_supervised!(GenLSP.Assigns, id: make_ref())
    GenLSP.Assigns.merge(assigns, %{state: %{}})

    lsp = %GenLSP.LSP{mod: Expert, assigns: assigns}

    reason = :something_bad

    assert {:noreply, ^lsp} = Expert.handle_info({:engine_initialized, {:error, reason}}, lsp)

    error_message = "Failed to initialize: #{inspect(reason)}"
    error_message_type = GenLSP.Enumerations.MessageType.error()

    assert_receive {:transport,
                    %GenLSP.Notifications.WindowLogMessage{
                      params: %GenLSP.Structures.LogMessageParams{
                        type: ^error_message_type,
                        message: ^error_message
                      }
                    }}

    assert_receive {:transport,
                    %GenLSP.Notifications.WindowShowMessage{
                      params: %GenLSP.Structures.ShowMessageParams{
                        type: ^error_message_type,
                        message: ^error_message
                      }
                    }}
  end
end
