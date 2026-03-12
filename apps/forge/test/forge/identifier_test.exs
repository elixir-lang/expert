defmodule Forge.IdentifierTest do
  use ExUnit.Case, async: true

  alias Forge.Identifier

  setup do
    Identifier.start()
    :ok
  end

  describe "next_global!/0" do
    test "returns a positive integer" do
      [id] = generate_ids(1)
      assert is_integer(id)
      assert id > 0
    end

    test "ids from a single process increase" do
      ids = generate_ids(1000)

      assert ids == Enum.sort(ids)
    end

    test "ids don't duplicate in a single process" do
      ids = generate_ids(1000)

      assert ids == Enum.uniq(ids)
    end

    test "returns unique IDs across multiple processes" do
      ids_per_process = 500

      all_ids =
        1..20
        |> Task.async_stream(fn _ ->
          generate_ids(ids_per_process)
        end)
        |> Enum.flat_map(fn {:ok, ids} -> ids end)

      assert length(all_ids) == 20 * ids_per_process
      assert Enum.uniq(all_ids) == all_ids
    end
  end

  describe "to_unix/2" do
    test "returns milliseconds by default" do
      id = Identifier.next_global!()
      unix_ms = Identifier.to_unix(id)
      now_ms = System.system_time(:millisecond)

      assert_in_delta unix_ms, now_ms, 100
    end

    test "returns seconds when requested" do
      id = Identifier.next_global!()
      unix_s = Identifier.to_unix(id, :second)
      now_s = System.system_time(:second)

      assert_in_delta unix_s, now_s, 1
    end

    test "returns microseconds when requested" do
      id = Identifier.next_global!()
      unix_us = Identifier.to_unix(id, :microsecond)
      now_us = System.system_time(:microsecond)

      assert_in_delta unix_us, now_us, 100_000
    end
  end

  describe "to_datetime/1" do
    test "returns a DateTime close to now" do
      id = Identifier.next_global!()
      assert %DateTime{} = datetime = Identifier.to_datetime(id)

      now = DateTime.utc_now()
      diff = DateTime.diff(now, datetime, :millisecond)
      assert_in_delta diff, 0, 100
    end
  end

  describe "to_erl/1" do
    test "matches the current time" do
      id = Identifier.next_global!()
      {{year, month, day}, {hour, minute, _second}} = Identifier.to_erl(id)
      {{now_year, now_month, now_day}, {now_hour, now_minute, _}} = :calendar.universal_time()

      assert year == now_year
      assert month == now_month
      assert day == now_day
      assert hour == now_hour
      assert minute == now_minute
    end
  end

  defp generate_ids(n) when is_integer(n) do
    for _ <- 1..n do
      Identifier.next_global!()
    end
  end
end
