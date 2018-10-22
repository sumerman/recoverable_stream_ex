defmodule RecoverableStream do

  defmodule TasksPool do
    def name, do: __MODULE__
    def child_spec,
      do: Supervisor.Spec.supervisor(Task.Supervisor, [[name: name()]], id: name())
  end

  defmodule RecoverableStreamCtx do
    defstruct [
      :task,
      :reply_ref,
      :retries_left,
      :stream_fun,
      :wrapper_fun,
      last_value: nil,
    ]
  end

  def run(new_stream_f, opts \\ []) do
    retries = Keyword.get(opts, :retry_attempts, 1)
    wfun = Keyword.get(opts, :wrapper_fun, fn f -> f.(%{}) end)
    Stream.resource(
      fn -> start_fun(new_stream_f, wfun, retries, nil) end,
      &next_fun/1,
      &after_fun/1
    )
  end

  defp start_fun(new_stream_f, wrapper_fun, retries, last_value)
  when (is_function(new_stream_f, 1) or is_function(new_stream_f, 2))
  and is_integer(retries) and retries >= 0 do
    owner = self()
    reply_ref = make_ref()

    t = Task.Supervisor.async_nolink TasksPool, fn ->
      wrapper_fun.(fn opts ->
        if is_function(new_stream_f, 1) do
          new_stream_f.(last_value)
        else
          new_stream_f.(last_value, opts)
        end
        |> stream_reducer(owner, reply_ref) 
      end)
    end

    %RecoverableStreamCtx{
      task: t,
      reply_ref: reply_ref,
      retries_left: retries,
      stream_fun: new_stream_f,
      wrapper_fun: wrapper_fun,
      last_value: last_value
    }
  end

  defp next_fun(%{task: %Task{ref: tref, pid: tpid}, reply_ref: rref, retries_left: retries} = ctx) do
    send(tpid, {:ready, rref})
    receive do
      {^tref, {:done, ^rref}} ->
        Process.demonitor(tref, [:flush])
        {:halt, ctx}

      {:data, ^rref, x} ->
        {[x], %{ctx | last_value: x}}

      {:DOWN, ^tref, _, _, :normal} ->
        {:halt, ctx}

      {:DOWN, ^tref, _, _, reason} when retries < 1 ->
        exit({reason, {__MODULE__, :next_fun, ctx}})

      {:DOWN, ^tref, _, _, _reason} ->
        {[], start_fun(ctx.stream_fun, ctx.wrapper_fun, retries - 1, ctx.last_value)}
    end
    # TODO consider adding a timeout
  end

  defp after_fun(%{task: %Task{ref: tref, pid: tpid}, reply_ref: rref} = ctx) do
    send(tpid, {:done, rref})
    receive do
      {:DOWN, ^tref, _, _, :normal} -> :ok
      {:DOWN, ^tref, _, _, reason} -> 
        exit({reason, {__MODULE__, :after_fun, ctx}})
    after 100 -> 
      Process.demonitor(tref, [:flush])
      Task.Supervisor.terminate_child(TasksPool, tpid)
    end
  end

  defp stream_reducer(stream, owner, reply_ref) do
    mon_ref = Process.monitor(owner)

    stream
    |> Stream.each(fn x ->
      receive do
        {:done, ^reply_ref} ->
          exit(:normal)
        {:ready, ^reply_ref} ->
          send(owner, {:data, reply_ref, x})
        {:DOWN, ^mon_ref, _, ^owner, reason} ->
          exit(reason)
      end
      # TODO consider adding a timeout

    end) 
    |> Stream.run

    {:done, reply_ref}
  end

end
