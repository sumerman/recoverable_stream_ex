defmodule RecoverableStreamTest do
  use ExUnit.Case, async: true

  alias RecoverableStream, as: RS

  # supresses failed stream log lines
  @moduletag capture_log: true

  setup_all do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, pid} = Postgrex.start_link(database: "postgres", username: "postgres", password: "")
    %{db_conn: pid}
  end

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

  test "postgrex example", %{db_conn: pid} do
    create_t =
      "CREATE TEMPORARY TABLE IF NOT EXISTS recoverable_stream_test" <>
        "(a integer PRIMARY KEY, b integer, c integer)"

    inserts =
      "INSERT INTO recoverable_stream_test " <>
        "SELECT a, a%3 AS b, a%5 AS c FROM generate_series(1, 1e5) a"

    Postgrex.transaction(pid, fn conn ->
      {:ok, _} = Postgrex.query(conn, create_t, [])
      {:ok, _} = Postgrex.query(conn, inserts, [])
    end)

    assert resumable_stream_from(pid) |> Enum.count() == 100_000
  end

  defp resumable_stream_from(pid) do
    gen_stream = fn last_val, %{conn: conn} ->
      [from, _, _] = last_val || [0, 0, 0]

      Postgrex.stream(conn, "SELECT * FROM recoverable_stream_test WHERE a > $1 ORDER BY a", [
        from
      ])
      |> Stream.flat_map(fn %Postgrex.Result{rows: rows} -> rows end)
      |> Stream.map(fn [a, _, _] = x ->
        if a == 10_000 and last_val == nil do
          exit(:wtf)
        end

        x
      end)
    end

    wrapper_fun = fn f ->
      Postgrex.transaction(pid, fn conn -> f.(%{conn: conn}) end)
    end

    RecoverableStream.run(gen_stream, wrapper_fun: wrapper_fun)
  end
end
