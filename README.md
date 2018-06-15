# RecoverableStreamEx

This is just an idea I was toying around with, **not a production code.**

Streams are the best way to handle "potentially infinite" data:
imagine a query scanning a table with a filter and returning rows
in batches. E.g. `Postgrex.stream/4` provides an interface like
that. 

But what happens if a connection to a database stutters?
The entire stream would fail. Then an app should retry. But what if
retrying from the beginning is expensive? E.g. it'd mean the database
has to re-scan hundreds of GBs. Can we avoid that? Can we make it 
transparent for a client-code?

`RecoverableStream` moves stream reduction into a separate process,
retries up to N times, from the last retrived value, then propagates
an error. 

## Basic usage

`RecoverableStream.run` function takes 2 parameters: a stream 
re-creation fun and a list of options. Stream creation function
is called with the last element, obtained from a stream or `nil`
and must return a new stream:

```Elixir
gen_stream_f = fn 
  # will fail after 10 elements
  nil -> Stream.iterate(1, fn x when x < 10 -> x + 1 end)
  x   -> Stream.iterate(x + 1, &(&1+1))
end

res = RecoverableStream.run(gen_stream_f, retry_attempts: 5)
	  |> Stream.take(20)
	  |> Enum.into([])

assert Enum.into(1..n, []) == res
```

## Practical Example

Assuming there is a table defined like:

```SQL
CREATE TABLE IF NOT EXISTS recoverable_stream_test (a integer PRIMARY KEY, b integer, c integer)
```

`RecoverableStream` can be used to wrap `Postgrex.stream`. 
Additional parameter `wrapper_fun` allows putting DB code into
a transaction. Wrapper fun is allowed to pass additional metadata
to the stream creation function.


```Elixir
gen_stream = fn last_val, %{conn: conn} ->
  [from, _, _] = last_val || [0, 0, 0] 
  Postgrex.stream(conn,  "SELECT a, b, c FROM recoverable_stream_test WHERE a > $1", [from])
  |> Stream.flat_map(fn(%Postgrex.Result{rows: rows}) -> rows end) 
end

wrapper_fun = fn f -> 
  Postgrex.transaction(db_pid, fn(conn) -> f.(%{conn: conn}) end)
end

RecoverableStream.run(gen_stream, wrapper_fun: wrapper_fun)
|> Stream.each(&IO.inspect/1)
|> Stream.run
```

