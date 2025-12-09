defmodule Forge.OS do
  def windows? do
    match?({:win32, _}, type())
  end

  # this is here to be mocked in tests
  def type do
    :os.type()
  end
end
