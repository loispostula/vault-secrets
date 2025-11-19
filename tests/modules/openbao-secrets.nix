{ nixosPath, self, ... }@args:

(import "${nixosPath}/tests/make-test-python.nix" (
  { pkgs, ... }:
  let
    ssh-keys = import "${self.inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
    openbao-port = 8200;
    openbao-address = "http://server:${toString openbao-port}";
  in
  rec {
    name = "openbao-secrets";
    nodes = {
      server =
        { pkgs, lib, ... }:
        let
          serverArgs = "-dev -dev-root-token-id='root' -dev-listen-address='0.0.0.0:${toString openbao-port}'";
        in
        {
          # An unsealed dummy openbao
          networking.firewall.allowedTCPPorts = [ openbao-port ];
          systemd.services.dummy-openbao = {
            wantedBy = [ "multi-user.target" ];
            path = with pkgs; [
              getent
              openbao
            ];
            script = "openbao server ${serverArgs}";
          };
        };

      client =
        {
          pkgs,
          config,
          lib,
          ...
        }:
        {
          imports = [ self.nixosModules.openbao-secrets ];

          systemd.services.test = {
            script = ''
              ls '${config.openbao-secrets.secrets.test}'
              cat '${config.openbao-secrets.secrets.test}/test_file' | grep 'Test file contents!'
              cat '${config.openbao-secrets.secrets.test}/check_escaping' | grep "\"'\`"
              cat '${config.openbao-secrets.secrets.test}/complex_json' | ${pkgs.jq}/bin/jq -r .key1 | grep "value1"
              cat '${config.openbao-secrets.secrets.test}/complex_json' | ${pkgs.jq}/bin/jq -r .key2.subkey | grep "subvalue"
              cat '${config.openbao-secrets.secrets.test}/complex_json' | ${pkgs.jq}/bin/jq -r .key3[0] | grep "listitem1"
              env
              echo $HELLO | grep 'Hello, World'
            '';
            wantedBy = [ "multi-user.target" ];
            serviceConfig.EnvironmentFile = "${config.openbao-secrets.secrets.test}/environment";
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = "yes";
          };

          services.openssh = {
            enable = true;
            settings.PermitRootLogin = "yes";
          };

          users.users.root = {
            password = "";
            openssh.authorizedKeys.keys = [ ssh-keys.snakeOilPublicKey ];
          };

          openbao-secrets = {
            openbaoAddress = openbao-address;
            secrets.test = { };
          };

          networking.hostName = "client";
        };

      supervisor =
        { pkgs, lib, ... }:
        {
          environment.systemPackages = [ pkgs.openbao ];
        };
    };

    # API: https://github.com/NixOS/nixpkgs/blob/master/nixos/lib/test-driver/test-driver.py
    testScript =
      let
        # A set of flake outputs mimicking what one would find in an actual flake defining a NixOS system
        fakeFlake = {
          nixosConfigurations.client = self.inputs.nixpkgs.lib.nixosSystem {
            modules = [ nodes.client ];
            inherit (pkgs) system;
          };
        };

        inherit
          (import self.inputs.nixpkgs {
            inherit (pkgs) system;
            overlays = [ self.outputs.overlays.default ];
          })
          openbao-push-approles
          openbao-push-approle-envs
          ;

        supervisor-setup = pkgs.writeShellScript "supervisor-setup" ''
          set -euo pipefail

          set -x

          OPENBAO_ADDR="${openbao-address}"
          OPENBAO_TOKEN=root

          export OPENBAO_ADDR OPENBAO_TOKEN

          # Set up Vault
          bao auth enable approle
          bao secrets enable -version=2 kv

          # Put secrets for the test unit into Vault
          bao kv put kv/test/environment HELLO='Hello, World'
          bao kv put kv/test/secrets \
            test_file='Test file contents!' \
            check_escaping="\"'\`" \
            complex_json='{"key1": "value1", "key2": {"subkey": "subvalue"}, "key3": ["listitem1", "listitem2"]}'

          # Set up SSH hostkey to connect to the client
          cat ${ssh-keys.snakeOilPrivateKey} > privkey.snakeoil
          chmod 600 privkey.snakeoil

          # Unset OPENBAO_ADDR and PATH to make sure those are set correctly in the scripts
          # We keep OPENBAO_TOKEN set because it's actually used to authenticate to openbao
          OPENBAO_ADDR=
          PATH=
          export OPENBAO_ADDR PATH

          # Push approles to openbao
          ${openbao-push-approles fakeFlake}/bin/openbao-push-approles test

          # Upload approle environments to the client
          ${
            openbao-push-approle-envs fakeFlake {
              getConfigurationOverrides =
                { attrName, ... }:
                {
                  client = {
                    # all of these are optional and the defaults for `hostname` and `sshUser` here would be fine.
                    # we specify them just for demonstration.
                    hostname = "client";
                    sshUser = "root";
                    sshOpts = [
                      "-o"
                      "StrictHostKeyChecking=no"
                      "-i"
                      "privkey.snakeoil"
                    ];
                  };
                }
                .${attrName};
            }
          }/bin/openbao-push-approle-envs
        '';
      in
      ''
        start_all()

        server.wait_for_unit("multi-user.target")
        server.wait_for_unit("dummy-openbao")
        server.wait_for_open_port(8200)

        supervisor.succeed("${supervisor-setup}")

        client.succeed("systemctl restart test")

        client.wait_for_unit("test-secrets")

        client.succeed("systemctl status test")
      '';
  }
))
  args
