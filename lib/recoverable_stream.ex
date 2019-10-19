defmodule RecoverableStream do
  @moduledoc """
  By extracting source stream evaluation into a separate process
  `RecoverableStream` provides a way to isolate upstream errors
  and recover from them.

  This module contains public API.
  """

  defmodule TasksPool do
    @moduledoc """
    A default `Supervisor` for tasks spawned by `RecoverableStream`.
    """

    @doc """
    A template `child_spec` for a custom `Task.Supervisor`.

    ## Example

        iex> {:ok, _} = Supervisor.start_child(
        ...>             RecoverableStreamEx.Supervisor,
        ...>             RecoverableStream.TasksPool.child_spec(:my_sup))
        ...> RecoverableStream.run(
        ...>     fn x -> Stream.repeatedly(fn -> x end) end,
        ...>     task_supervisor: :my_sup
        ...> ) |> Stream.take(2) |> Enum.into([])
        [nil, nil]

    """
    def child_spec(name),
      do: Supervisor.Spec.supervisor(Task.Supervisor, [[name: name]], id: name)
  end

  defmodule RecoverableStreamCtx do
    @moduledoc false
    defstruct [
      :task,
      :supervisor,
      :reply_ref,
      :retries_left,
      :stream_fun,
      :wrapper_fun,
      last_value: nil
    ]
  end

  @type last_value_t :: nil | any()
  @type stream_arg_t :: any()

  @type stream_fun ::
          (last_value_t() -> Enumerable.t())
          | (last_value_t(), stream_arg_t() -> Enumerable.t())

  @type inner_reduce_fun :: (stream_arg_t() -> none())
  @type wrapper_fun :: (inner_reduce_fun() -> none())

  @type run_option ::
          {:retry_attempts, non_neg_integer()}
          | {:wrapper_fun, wrapper_fun()}
          | {:task_supervisor, atom() | pid()}

  @spec run(stream_fun(), [run_option()]) :: Enumerable.t()
  @doc """
  Evaluates passed `t:stream_fun/0` inside a new `Task` then runs
  produced stream, forwarding data back to the caller.

  Returns a new `Stream` that gathers data forwarded by the `Task`.
  Data is forwarded element by element. Batching is to be implemented
  explicitly. For example `Postgrex.stream/3` sends data in chunks
  by default.

  ## Stream function

  `t:stream_fun/0` must be a function that accepts one or two arguments.

  - The first argument is either `nil` or the last value received from a
  stream before recovery.
  - The second argument is an arbitrary term passed from `t:wrapper_fun/0`

  The function should return a `Stream` (although, any `Enumerable` could work).

  ## Example

      iex> gen_stream_f = fn
      ...>   nil -> Stream.iterate(1, fn x when x < 2 -> x + 1 end)
      ...>     x -> Stream.iterate(x + 1, &(&1+1))
      ...> end
      iex> RecoverableStream.run(gen_stream_f)
      ...> |> Stream.take(4)
      ...> |> Enum.into([])
      [1, 2, 3, 4]

  ## Options

  - `:retry_attempts` (defaults to `1`) the total number of times
    error recovery is performed before an error is propagated.

    Retries counter is **not** reset upon a successful recovery!

  - `:task_supervisor` either pid or a name of `Task.Supervisor`
     to supervise a stream-reducer `Task`.
     (defaults to `RecoverableStream.TaskPool`)

     See `RecoverableStream.TasksPool.child_spec/1` for details.

  - `:wrapper_fun` is a funciton that wraps a stream reducer running
     inside a `Task` (defaults to `fun f -> f.(%{}) end`).

     Useful when the `t:stream_fun/0` must be run within a certain
     context. E.g. `Postgrex.stream/3` only works inside
     `Postgrex.transaction/3`.

     See [Readme](./readme.html#a-practical-example)
     for a more elaborate example.
  """
  def run(new_stream_fun, options \\ []) do
    retries = Keyword.get(options, :retry_attempts, 1)
    wfun = Keyword.get(options, :wrapper_fun, fn f -> f.(%{}) end)
    supervisor = Keyword.get(options, :task_supervisor, TasksPool)

    Stream.resource(
      fn -> start_fun(new_stream_fun, wfun, supervisor, retries, nil) end,
      &next_fun/1,
      &after_fun/1
    )
  end

  defp start_fun(new_stream_fun, wrapper_fun, supervisor, retries, last_value)
       when (is_function(new_stream_fun, 1) or is_function(new_stream_fun, 2)) and
              is_integer(retries) and retries >= 0 do
    owner = self()
    reply_ref = make_ref()

    t =
      Task.Supervisor.async_nolink(supervisor, fn ->
        wrapper_fun.(fn stream_arg ->
          if is_function(new_stream_fun, 1) do
            new_stream_fun.(last_value)
          else
            new_stream_fun.(last_value, stream_arg)
          end
          |> stream_reducer(owner, reply_ref)
        end)
      end)

    %RecoverableStreamCtx{
      task: t,
      supervisor: supervisor,
      reply_ref: reply_ref,
      retries_left: retries,
      stream_fun: new_stream_fun,
      wrapper_fun: wrapper_fun,
      last_value: last_value
    }
  end

  defp next_fun(ctx) do
    %{
      task: %Task{ref: tref, pid: tpid},
      supervisor: sup,
      reply_ref: rref,
      retries_left: retries
    } = ctx

    send(tpid, {:ready, rref})

    receive do
      {^tref, {:done, ^rref}} ->
        Process.demonitor(tref, [:flush])
        {:halt, ctx}

      # TODO add an optional retries reset
      {:data, ^rref, x} ->
        {[x], %{ctx | last_value: x}}

      {:DOWN, ^tref, _, _, :normal} ->
        {:halt, ctx}

      {:DOWN, ^tref, _, _, reason} when retries < 1 ->
        exit({reason, {__MODULE__, :next_fun, ctx}})

      {:DOWN, ^tref, _, _, _reason} ->
        {[], start_fun(ctx.stream_fun, ctx.wrapper_fun, sup, retries - 1, ctx.last_value)}
    end

    # TODO consider adding a timeout
  end

  defp after_fun(%{task: %Task{ref: tref, pid: tpid}, reply_ref: rref} = ctx) do
    send(tpid, {:done, rref})

    receive do
      {:DOWN, ^tref, _, _, :normal} ->
        :ok

      {:DOWN, ^tref, _, _, reason} ->
        exit({reason, {__MODULE__, :after_fun, ctx}})
    after
      100 ->
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
    |> Stream.run()

    {:done, reply_ref}
  end
end
