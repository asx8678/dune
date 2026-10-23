# Outside the Dune namespace: atoms containing `Dune` are restricted in a sandbox.
defmodule ReductionsCheckWaiter do
  def wait(ms), do: Process.sleep(ms)
end

defmodule Dune.Eval.ProcessTest do
  use ExUnit.Case, async: true

  alias Dune.Eval.Process, as: EvalProcess

  defmodule WaitAllowlist do
    use Dune.Allowlist, extend: Dune.Allowlist.Default

    allow ReductionsCheckWaiter, only: [:wait]
  end

  describe "check_interval/1" do
    test "polls without pausing while the remaining budget could run out" do
      assert EvalProcess.check_interval(0) == 0
      assert EvalProcess.check_interval(30_000) == 0
      assert EvalProcess.check_interval(1_999_999) == 0
    end

    test "sleeps for as long as the remaining budget can't run out, up to 10 ms" do
      assert EvalProcess.check_interval(2_000_000) == 1
      assert EvalProcess.check_interval(10_000_000) == 5
      assert EvalProcess.check_interval(2_000_000_000) == 10
    end
  end

  test "the reductions checker sleeps while code with a large budget waits" do
    task =
      Task.async(fn ->
        Dune.eval_string("ReductionsCheckWaiter.wait(300)",
          allowlist: WaitAllowlist,
          max_reductions: 2_000_000_000,
          timeout: 1_000
        )
      end)

    checker = find_checker(50)
    {:reductions, before} = Process.info(checker, :reductions)
    Process.sleep(100)
    {:reductions, later} = Process.info(checker, :reductions)

    # Polling in a tight loop runs millions of reductions in 100 ms.
    assert later - before < 100_000
    assert %Dune.Success{value: :ok} = Task.await(task)
  end

  # The checker is the process with check_max_reductions/3 on its stack. It
  # starts just after the evaluation does, so look again a few times.
  defp find_checker(attempts) do
    checker =
      Enum.find(Process.list(), fn pid ->
        case Process.info(pid, :current_stacktrace) do
          {:current_stacktrace, stack} ->
            Enum.any?(stack, &match?({EvalProcess, :check_max_reductions, 3, _}, &1))

          nil ->
            false
        end
      end)

    cond do
      checker != nil ->
        checker

      attempts > 0 ->
        Process.sleep(5)
        find_checker(attempts - 1)

      true ->
        flunk("found no reductions checker")
    end
  end
end
