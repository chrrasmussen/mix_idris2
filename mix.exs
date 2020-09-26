defmodule MixIdris.MixProject do
  use Mix.Project

  def project do
    [
      app: :mix_idris2,
      version: "0.1.0",
      elixir: "~> 1.5",
      deps: deps()
    ]
  end

  defp deps do
    []
  end
end
