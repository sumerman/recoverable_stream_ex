defmodule RecoverableStreamTest do
  use ExUnit.Case, async: true

  alias RecoverableStream, as: RS

  defp gen_stream_f() do
    fn
      nil -> Stream.iterate(1, fn x when x < 10 -> x + 1 end)
      10 -> Stream.iterate(11, fn x when x < 21 -> x + 1 end)
      x -> Stream.iterate(x + 1, &(&1 + 1))
    end
  end

  test "normal wrapped stream" do
    n = 9
    res = RS.run(gen_stream_f()) |> Stream.take(n)
    assert Enum.count(Enum.uniq(res)) == n
  end

  test "normal stream with early termination" do
    n = 100
    parent = self()
    ref = make_ref()

    gen_stream = fn _ ->
      stream_pid = self()

      spawn(fn ->
        mon_ref = Process.monitor(stream_pid)

        receive do
          {:DOWN, ^mon_ref, _, _, reason} ->
            send(parent, {:down, ref, reason})
        end
      end)

      Stream.iterate(1, &(&1 + 1))
    end

    _res =
      RS.run(gen_stream)
      |> Stream.take(n)
      |> Enum.into([])

    assert_receive {:down, ^ref, :normal}
  end

  test "recovery in a failing stream" do
    n = 20

    res =
      RS.run(gen_stream_f())
      |> Stream.take(n)
      |> Enum.into([])

    assert Enum.into(1..n, []) == res
  end

  test "number of retries" do
    n = 30

    assert {{:function_clause, _}, _} =
             catch_exit(
               RS.run(gen_stream_f())
               |> Stream.take(n)
               |> Enum.into([])
             )

    res =
      RS.run(gen_stream_f(), retry_attempts: 5)
      |> Stream.take(n)
      |> Enum.into([])

    assert Enum.into(1..n, []) == res
  end

  test "wrapper fun" do
    n = 20

    wrapper = fn f ->
      try do
        f.(%{})
      rescue
        FunctionClauseError -> :ok
      end
    end

    res =
      RS.run(gen_stream_f(), wrapper_fun: wrapper, retry_attempts: 0)
      |> Stream.take(n)
      |> Enum.into([])

    assert Enum.into(1..10, []) == res
  end
end
