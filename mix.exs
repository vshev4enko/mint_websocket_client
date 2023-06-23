defmodule MintWebsocketClient.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/vshev4enko/mint_websocket_client"

  def project do
    [
      app: :mint_websocket_client,
      version: @version,
      elixir: "~> 1.14",
      deps: deps(),
      name: "MintWebsocketClient",
      source_url: @source_url,
      docs: [source_ref: "v#{@version}", main: "readme", extras: ["README.md"]],
      description: description(),
      package: package()
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:cowboy, "~> 2.9", optional: true},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false},
      {:mint_web_socket, "~> 1.0"}
    ]
  end

  defp description() do
    "Behaviour module for implementing websocket clients."
  end

  defp package() do
    [
      maintainers: ["Viacheslav Shevchenko"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
