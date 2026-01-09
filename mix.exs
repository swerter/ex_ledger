defmodule ExLedger.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_ledger,
      version: "0.1.2",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["Michael J. Bruderer"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/swerter/ex_ledger"}
    ]
  end

  defp description do
    """
    An (partial) elixir implementation of ledger-cli plaintext bookkeeping system.
    """
  end

  defp releases do
    [
      exledger: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            freebsd: [os: :freebsd, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_parsec, "~> 1.0"},
      {:burrito, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
