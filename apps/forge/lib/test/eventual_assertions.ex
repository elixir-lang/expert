defmodule Forge.Test.EventualAssertions do
  @moduledoc """
  Assertion macros for an eventually consistent world
  Sometimes, despite our best efforts, we want to assert that some condition holds, but it doesn't
  hold just _yet_. Enter `eventual_assertions`. This module will repeatedly try your assertions
  and stop when they're true (or false). It does all of this without using `Elixir.Process.sleep/1`.
  Use just like you would `assert` or `refute`
      assert_eventually User.find_by_id(my_id) == %User{short_name: "Stinky"}
      refute_eventually User.exists?(3)
  """
  defmacro __using__(_) do
    quote do
      require unquote(__MODULE__)
      import unquote(__MODULE__)
    end
  end

  defp do_eventually(func, {:=, _, [left, _right]} = assertion, timeout) do
    quote generated: true do
      timer_ref = Process.send_after(self(), :assert_timeout, unquote(timeout))

      asserter = fn ->
        unquote(func)(unquote(assertion))
      end

      unquote(left) = apply_assert(asserter, unquote(timeout), timer_ref)
    end
  end

  defp do_eventually(func, assertion, timeout) do
    quote generated: true do
      timer_ref = Process.send_after(self(), :assert_timeout, unquote(timeout))

      asserter = fn ->
        unquote(func)(unquote(assertion))
      end

      apply_assert(asserter, unquote(timeout), timer_ref)
    end
  end

  def apply_assert(assert, timeout, timer_ref) do
    rv = assert.()
    Process.cancel_timer(timer_ref)
    rv
  rescue
    e in ExUnit.AssertionError ->
      receive do
        :assert_timeout ->
          reraise %{e | message: e.message <> " after #{timeout} ms"}, __STACKTRACE__
      after
        1 ->
          apply_assert(assert, timeout, timer_ref)
      end
  end

  defmacro assert_eventually(assertion, timeout \\ 100) do
    do_eventually(:assert, assertion, timeout)
  end

  defmacro refute_eventually(assertion, timeout \\ 100) do
    do_eventually(:refute, assertion, timeout)
  end
end
