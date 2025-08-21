use Expert.IEx.Helpers

try do
  Mix.ensure_application!(:observer)
rescue
  _ -> nil
end
