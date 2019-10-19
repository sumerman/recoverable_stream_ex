defmodule RecoverableStreamTaskPoolTest do
  use ExUnit.Case, async: true

  doctest RecoverableStream.TasksPool

  alias RecoverableStream, as: RS

  setup_all do
    {:ok, sup_pid} =
      Supervisor.start_child(
        RecoverableStreamEx.Supervisor,
        RS.TasksPool.child_spec(__MODULE__)
      )

    %{supervisor: sup_pid}
  end

  test "passing an optional supervisor by name" do
    res =
      sup_check_stream()
      |> RS.run(task_supervisor: __MODULE__)
      |> Stream.take(1)
      |> Enum.into([])

    assert [true] == res
  end

  test "passing an optional supervisor by pid", %{supervisor: sup_pid} do
    res =
      sup_check_stream()
      |> RS.run(task_supervisor: sup_pid)
      |> Stream.take(1)
      |> Enum.into([])

    assert [true] == res
  end

  defp sup_check_stream(),
    do: fn _last_val ->
      [{_id, child, _type, _modules}] = Supervisor.which_children(__MODULE__)

      Stream.repeatedly(fn -> child == self() end)
    end
end
