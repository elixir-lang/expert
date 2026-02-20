if Code.ensure_loaded?(:logger_handler) do
  defmodule Expert.Logging.LoggerHandler do
    @moduledoc """
    Compatibility wrapper for logger handler behaviour on OTP 27+.

    `use Expert.Logging.LoggerHandler` expands to `@behaviour :logger_handler`,
    so handler modules can depend on a stable project-local module name while
    still using the native OTP behaviour.
    """

    defmacro __using__(_opts) do
      quote do
        @behaviour :logger_handler
      end
    end
  end
else
  defmodule Expert.Logging.LoggerHandler do
    @moduledoc """
    Compatibility wrapper for logger handler behaviour on OTP 25/26.

    OTP 25/26 do not provide `:logger_handler`, so this module defines the
    minimal callback contract required by our handlers and `use
    Expert.Logging.LoggerHandler` expands to that local behaviour.
    """

    @callback log(:logger.log_event(), map()) :: term()

    defmacro __using__(_opts) do
      quote do
        @behaviour Expert.Logging.LoggerHandler
      end
    end
  end
end
