defmodule JidoBedrock.MixProject do
  use Mix.Project

  @version "0.2.0-alpha.0"
  @source_url "https://github.com/agentjido/jido_bedrock"
  @description "Bedrock-backed persistence adapters for Jido runtimes."

  def project do
    [
      app: :jido_bedrock,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # Hackney 4.x is incompatible with the current HTTPoison/ExAws dependency chain.
      hex: [
        ignore_advisories: [
          "CVE-2026-47075",
          "CVE-2026-47076",
          "CVE-2026-47071",
          "CVE-2026-47069"
        ]
      ],

      # Documentation
      name: "Jido Bedrock",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package(),

      # Test coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90],
        export: "cov",
        ignore_modules: [
          ~r/^JidoBedrockTest$/,
          ~r/^Jido\.Bedrock\.Case(\.|$)/,
          ~r/^Jido\.Bedrock\.RealBedrockCase(\.|$)/
        ]
      ],

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix, :jido_memory],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.lcov": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:jido, "~> 2.3"},
      bedrock_dep(),
      {:splode, "~> 0.3.0"},
      {:telemetry, "~> 1.3"},

      # Dev/Test quality
      {:jido_memory, "~> 1.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:doctor, "~> 0.23.0", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.10", only: :dev, runtime: false}
    ]
  end

  defp bedrock_dep do
    env_path =
      System.get_env("BEDROCK_PATH")
      |> case do
        path when is_binary(path) and path != "" -> Path.expand(path)
        _ -> nil
      end

    local_path = Path.expand("../bedrock", __DIR__)

    resolved_path =
      cond do
        Mix.env() not in [:dev, :test] ->
          nil

        is_binary(env_path) and File.exists?(Path.join(env_path, "mix.exs")) ->
          env_path

        File.exists?(Path.join(local_path, "mix.exs")) ->
          local_path

        true ->
          nil
      end

    if resolved_path do
      {:bedrock, path: resolved_path}
    else
      {:bedrock, github: "bedrock-kv/bedrock", branch: "main"}
    end
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      test: "test --exclude flaky",
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "config",
        "guides",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "usage-rules.md"
      ],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_bedrock/changelog.html",
        "Discord" => "https://jido.run/discord",
        "Documentation" => "https://hexdocs.pm/jido_bedrock",
        "GitHub" => @source_url,
        "Website" => "https://jido.run"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ]
    ]
  end
end
