# Generate and push approles to openbao
{
  writeShellScriptBin,
  jq,
  bash,
  openbao,
  openssh,
  coreutils,
  lib,
}:
# Inputs: a flake with `nixosConfigurations`

# Usage:
# apps.x86_64-linux.openbao-push-approle-envs = { type = "app"; program = "${pkgs.openbao-push-approle-envs self}/bin/openbao-push-approle-envs"; }

{
  nixosConfigurations ? { },
  darwinConfigurations ? { },
  ...
}:
rec {
  overrideable = final: {
    hostNameOverrides = { };
    getHostName =
      { attrName, config, ... }:
      final.hostNameOverrides.${attrName} or (
        if ((!(config.networking ? domain)) || (isNull config.networking.domain)) then
          config.networking.hostName
        else
          "${config.networking.hostName}.${config.networking.domain}"
      );
    getConfigurationOverrides = params: { };
  };

  type = "derivation";

  __toString =
    self:
    let

      final = lib.fix self.overrideable;

      # The script that writes the approle to the openbao server
      pushApproleEnv =
        {
          approleName,
          openbaoAddress,
          environmentFile,
          ...
        }@params:
        let
          configOverrides = {
            hostname = final.getHostName params;
            sshUser = null;
            sshOpts = [ ];
          }
          // final.getConfigurationOverrides params;

          host = "${
            if configOverrides.sshUser != null then "${configOverrides.sshUser}@" else ""
          }${configOverrides.hostname}";

          push = ''
            ${./openbao-get-approle-env.sh} ${approleName} | ssh ${lib.escapeShellArg host} ${lib.escapeShellArgs configOverrides.sshOpts} ''${SSH_OPTS:-} "sudo mkdir -p ${builtins.dirOf environmentFile}; sudo tee ${environmentFile} >/dev/null"
          '';
        in
        ''
          export OPENBAO_ADDR="${openbaoAddress}"

          ${./openbao-ensure-token.sh}

          if [[ $# -eq 0 ]] || [[ " $@ " =~ " ${approleName} " ]]; then
            # If we don't get any arguments, or the current approle name is in the arguments list, push it
            echo "Uploading ${approleName} to ${configOverrides.hostname}"
            set -x
            ${push}
            set +x
          fi
        '';

      # Get all approles for openbao-secrets in configuration
      approleParamsForMachine =
        attrName: cfg:
        let
          vs = cfg.config.openbao-secrets;
          prefix = lib.optionalString (!isNull vs.approlePrefix) "${vs.approlePrefix}-";
        in
        builtins.attrValues (
          builtins.mapAttrs (
            name: secret:
            builtins.removeAttrs
              (
                vs
                // secret
                // {
                  approleName = "${prefix}${name}";
                  inherit name attrName;
                  inherit (cfg) config;
                }
              )
              [
                "__toString"
                "secrets"
              ]
          ) vs.secrets
        );

      # Find all configurations that have openbao-secrets defined
      configsWithSecrets = lib.filterAttrs (
        _: cfg: cfg.config ? openbao-secrets && cfg.config.openbao-secrets.secrets != { }
      ) (nixosConfigurations // darwinConfigurations);

      # Get all approles for all NixOS configurations in the given flake
      approleParamsForAllMachines = builtins.mapAttrs approleParamsForMachine configsWithSecrets;

      # All approles for all NixOS configurations plus the extra approles
      allApproleParams = builtins.concatLists (builtins.attrValues approleParamsForAllMachines);

      # Check whether all the elements in the list are unique
      allUnique =
        lst:
        let
          allUnique' =
            builtins.foldl'
              (
                { traversed, result }:
                x:
                if !result || builtins.elem x traversed then
                  {
                    inherit traversed;
                    result = false;
                  }
                else
                  {
                    traversed = traversed ++ [ x ];
                    result = true;
                  }
              )
              {
                traversed = [ ];
                result = true; # In an empty list, all elements are unique
              };
        in
        (allUnique' lst).result;

      # A script to write all approles
      pushAllApproleEnvs =
        assert allUnique (map (x: x.approleName) allApproleParams);
        lib.concatMapStringsSep "\n" pushApproleEnv allApproleParams;
    in
    writeShellScriptBin "openbao-push-approle-envs" ''
      set -euo pipefail
      export PATH=$PATH''${PATH:+':'}'${
        lib.makeBinPath [
          jq
          openbao
          bash
          coreutils
          openssh
        ]
      }'
      ${pushAllApproleEnvs}
    '';

  # Allows to ergonomically override `overrideable` values with a simple function application
  # Accepts either an attrset with override values, or a function of
  # `final` (which will contain the final version of all the overrideable functions)
  __functor =
    self: overrides:
    self
    // {
      overrideable =
        s:
        (self.overrideable s)
        // (if builtins.isFunction overrides then overrides s (self.overrideable s) else overrides);
    };

  __functionArgs = builtins.mapAttrs (_: _: false) (overrideable { });
}
