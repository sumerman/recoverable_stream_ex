defmodule PostgresTest do
  use ExUnit.Case, async: true

  # supresses failed stream log lines
  @moduletag capture_log: true

  setup_all do
    pg_hostname = System.get_env("PG_HOST") || "localhost"
    pg_username = System.get_env("PG_USER") || "postgres"
    pg_password = System.get_env("PG_PASS") || ""
    {:ok, _} = Application.ensure_all_started(:postgrex)

    {:ok, pid} =
      Postgrex.start_link(
        database: "postgres",
        hostname: pg_hostname,
        username: pg_username,
        password: pg_password
      )

    %{db_conn: pid}
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
