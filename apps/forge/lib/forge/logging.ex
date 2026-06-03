defmodule Forge.Logging do
  @debug_enabled? not is_nil(System.get_env("TIMINGS_ENABLED"))

  if @debug_enabled? do
    defmacro timed(label, do: block) do
      quote do
        timed_log(unquote(label), fn -> unquote(block) end)
      end
    end
  else
    defmacro timed(_label, do: block), do: block
  end

  if @debug_enabled? do
    def timed_log(label, threshold_ms \\ 1, function) when is_function(function, 0) do
      require Logger

      {elapsed_us, result} = :timer.tc(function)
      elapsed_ms = elapsed_us / 1000

      if elapsed_ms >= threshold_ms do
        Logger.info("#{label} took #{Forge.Formats.time(elapsed_us)}")
      end

      result
    end
  else
    def timed_log(_label, _threshold_ms \\ 1, function) when is_function(function, 0) do
      function.()
    end
  end
end
