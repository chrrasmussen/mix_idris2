defmodule MixIdris.MixProject do
  use Mix.Project

  def project do
    [
      app: :mix_idris2,
      version: "0.1.0",
      elixir: "~> 1.5",
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  defp deps do
    []
  end

  defp description() do
    "Mix compiler for Idris 2"
  end

  defp package() do
    [
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE),
      exclude_patterns: [".DS_Store"],
      licenses: ["BSD-3-Clause"],
      links: %{"GitHub" => "https://github.com/chrrasmussen/mix_idris2"}
    ]
  end
end
