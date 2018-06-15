defmodule RecoverableStreamEx do
  use Application

  def start(_type, _args) do
    opts = [
      strategy: :one_for_one,
      name: RecoverableStreamEx.Supervisor
    ]

    children = [
      RecoverableStream.TasksPool.child_spec()
    ]
    
    Supervisor.start_link(children, opts)
  end
end