defmodule Forge.Internet do
  def connected_to_internet? do
    # While there's no perfect way to check if a computer is connected to the internet,
    # it seems reasonable to gate pulling dependencies on a resolution check for hex.pm.
    # Yes, it's entirely possible that the DNS server is local, and that the entry is in cache,
    # but that's an edge case, and the build will just time out anyways.
    task =
      Task.async(fn ->
        case :inet.gethostbyname(~c"hex.pm", :inet) do
          {:ok, _} -> true
          _ -> false
        end
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, true} -> true
      _ -> false
    end
  end
end
