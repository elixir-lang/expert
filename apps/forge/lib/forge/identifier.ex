defmodule Forge.Identifier do
  # Microseconds since Jan 1, 2024 UTC
  @epoch 1_704_070_800_000_000
  @atomics_key {__MODULE__, :atomics_key}
  @max_seq 4096

  # Modified snowflake layout for single-machine use:
  #
  #   Standard snowflake (Twitter):
  #     1 bit sign | 41 bits ms timestamp | 10 bits machine ID | 12 bits sequence
  #
  #   Expert ID:
  #     1 bit sign | 51 bits μs timestamp | 12 bits sequence
  #
  # Since this runs on a single machine, the 10-bit machine ID is
  # repurposed for the timestamp, and the time unit changes from
  # milliseconds to microseconds. This gives ~71 years of range
  # and makes sequence overflow (4096 IDs per μs) virtually impossible.

  @doc """
  Initializes the atomic counter. Called once at application start.
  """
  def start do
    with :not_found <- :persistent_term.get(@atomics_key, :not_found) do
      ref = :atomics.new(1, signed: false)
      :persistent_term.put(@atomics_key, ref)
    end

    :ok
  end

  @doc """
  Returns the next globally unique identifier.

  Uses a single atomic that packs both the microsecond timestamp and
  a per-microsecond sequence counter. A compare-and-swap loop guarantees
  uniqueness across all processes without serialization.
  """
  def next_global! do
    atomic_ref = :persistent_term.get(@atomics_key)
    do_next_global(atomic_ref)
  end

  def to_unix(id, unit \\ :millisecond) do
    {timestamp_us, _seq} = unpack(id)
    System.convert_time_unit(timestamp_us, :microsecond, unit)
  end

  def to_datetime(id) do
    id
    |> to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
  end

  def to_erl(id) do
    %DateTime{year: year, month: month, day: day, hour: hour, minute: minute, second: second} =
      to_datetime(id)

    {{year, month, day}, {hour, minute, second}}
  end

  defp unpack(packed) do
    {div(packed, @max_seq) + @epoch, rem(packed, @max_seq)}
  end

  defp pack(timestamp_us, seq) do
    (timestamp_us - @epoch) * @max_seq + seq
  end

  defp do_next_global(atomic_ref) do
    current = :atomics.get(atomic_ref, 1)
    advance(atomic_ref, current)
  end

  defp advance(atomic_ref, current) do
    {last_us, seq} = unpack(current)
    now_us = System.system_time(:microsecond)

    timestamp_and_sequence =
      if now_us > last_us do
        pack(now_us, 0)
      else
        pack(last_us, seq + 1)
      end

    case :atomics.compare_exchange(atomic_ref, 1, current, timestamp_and_sequence) do
      :ok ->
        timestamp_and_sequence

      current_value ->
        advance(atomic_ref, current_value)
    end
  end
end
