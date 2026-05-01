defmodule Forge.Logging do
  require Logger

  defmacro timed(label, do: block) do
    if enabled?() do
      quote do
        timed_log(unquote(label), fn -> unquote(block) end)
      end
    else
      block
    end
  end

  def timed_log(label, threshold_ms \\ 1, function) when is_function(function, 0) do
    if enabled?() do
      {elapsed_us, result} = :timer.tc(function)
      elapsed_ms = elapsed_us / 1000

      if elapsed_ms >= threshold_ms do
        Logger.info("#{label} took #{Forge.Formats.time(elapsed_us)}")
      end

      result
    else
      function.()
    end
  end

  @debug_enabled? not is_nil(System.get_env("TIMINGS_ENABLED"))

  defp enabled? do
    @debug_enabled?
  end
end
