defmodule RecoverableStreamEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :recoverable_stream_ex,
      version: "1.0.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex & Docs
      description: description(),
      package: package(),
      name: "RecoverableStreamEx",
      source_url: "https://github.com/sumerman/recoverable_stream_ex",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      mod: {RecoverableStreamEx, []},
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    By extracting evaluation of the source stream into a separate
    process `RecoverableStream` provides a way to isolate upstream
    errors and recover from them.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/sumerman/recoverable_stream_ex"}
    ]
  end

  defp deps do
    [
      {:postgrex, "~> 0.15", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false}
    ]
  end
end
