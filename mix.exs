defmodule Exterm.MixProject do
  use Mix.Project

  def project do
    [
      app: :exterm,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      description:
        "A minimal Elixir application that serves a real terminal in the browser using Plug and Cowboy.",
      package: [
        name: "exterm",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/metehan/exterm"}
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Exterm.Application, []}
    ]
  end

  defp deps do
    [
      {:poison, "~> 5.0"},
      {:httpoison, "~> 1.8"},
      {:req_llm, "~> 1.0.0-rc.6"},
      {:floki, "~> 0.38.0"},
      {:jason, "~> 1.4"},
      {:plug_cowboy, "~> 2.7"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
