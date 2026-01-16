defmodule Expert.Project.SearchListenerTest do
  alias Expert.EngineApi
  alias Expert.Test.DispatchFake
  alias Forge.Project
  alias GenLSP.Notifications.WindowShowMessage
  alias GenLSP.Structures.ShowMessageParams

  use ExUnit.Case
  use Patch
  use DispatchFake

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures
  import Expert.Test.Protocol.TransportSupport

  setup do
    project = project()
    DispatchFake.start()

    start_supervised!({Expert.Project.SearchListener, project})

    {:ok, project: project}
  end

  describe "handling search_store_loading message" do
    setup [:with_patched_transport]

    test "shows window/showMessage notification", %{project: project} do
      EngineApi.broadcast(project, search_store_loading(project: project))

      expected_type = GenLSP.Enumerations.MessageType.info()
      expected_message = "Search index is loading for #{Project.name(project)}..."

      assert_receive {:transport,
                      %WindowShowMessage{
                        params: %ShowMessageParams{
                          type: ^expected_type,
                          message: ^expected_message
                        }
                      }}
    end
  end
end
