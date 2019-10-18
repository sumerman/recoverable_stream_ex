defmodule RecoverableStreamEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :recoverable_stream_ex,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {RecoverableStreamEx, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:postgrex, "~> 0.15", only: [:dev, :test], runtime: false}
    ]
  end
end
