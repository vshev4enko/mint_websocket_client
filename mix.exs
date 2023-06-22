defmodule MintWebsocketClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :mint_websocket_client,
      name: "MintWebsocketClient",
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "MintWebsocketClient",
        extras: ["README.md"]
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
      {:cowboy, "~> 2.9", optional: true},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false},
      {:mint_web_socket, "~> 1.0"}
    ]
  end
end
