defmodule Forge.Identifier do
  import Bitwise

  @epoch 1_704_070_800_000
  @seq_mask (1 <<< 12) - 1

  @doc """
  Returns the next globally unique identifier.
  """
  def next_global! do
    now_ms = System.system_time(:millisecond)
    {last_ms, seq} = Process.get(:snowflake_state, {0, 0})

    {use_ms, next_seq} =
      if now_ms == last_ms do
        seq = seq + 1 &&& @seq_mask
        if seq == 0, do: wait_next_ms(last_ms), else: {now_ms, seq}
      else
        {now_ms, 0}
      end

    Process.put(:snowflake_state, {use_ms, next_seq})

    (use_ms - @epoch) <<< 16 ||| next_seq
  end

  def to_unix(id), do: (id >>> 16) + @epoch

  def to_datetime(id) do
    id
    |> to_unix()
    |> DateTime.from_unix!(:millisecond)
  end

  def to_erl(id) do
    %DateTime{year: year, month: month, day: day, hour: hour, minute: minute, second: second} =
      to_datetime(id)

    {{year, month, day}, {hour, minute, second}}
  end

  defp wait_next_ms(last_ms) do
    now_ms = System.system_time(:millisecond)
    if now_ms <= last_ms, do: wait_next_ms(last_ms), else: {now_ms, 0}
  end
end
