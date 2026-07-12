{
  description = "Nerves";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        elixir = pkgs.beam28Packages.elixir_1_18;
      in
      {
        devShells.noopencode = pkgs.mkShell {
          name = "slackapi";

          packages = with pkgs; [
            elixir
            dexter
            cmake # for building some of the deps :( crc32 from kafka
            inotify-tools
          ];

          env = {
            ERL_AFLAGS = "-kernel shell_history enabled";
          };

          shellHook = ''
            echo "$(elixir --version)"
            echo ""
            echo "Run 'mix setup' to install dependencies and set up the database."
            echo "Run 'mix phx.server' to start the development server."
          '';
        };

        devShells.default = pkgs.mkShell {
          name = "slackapi";

          packages = with pkgs; [
            autoconf
            automake
            curl
            beam28Packages.erlang
            fwup
            git
            beam28Packages.elixir_1_18
            rebar3
            squashfsTools
            libmnl
            sunxi-tools
            pkg-config
          ];

          env = {
            ERL_AFLAGS = "-kernel shell_history enabled";
          };

          shellHook = ''
            echo "$(elixir --version)"
          '';
        };
      }
    );
}
