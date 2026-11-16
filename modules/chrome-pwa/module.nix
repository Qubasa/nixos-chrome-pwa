moduleConfig:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.chrome-pwa;
  name = "auto-fix-chrome-pwa";

  commandOf = prefix: package:
    let
      command = baseNameOf (lib.getExe package);
    in
    lib.throwIf (builtins.match "[A-Za-z0-9._+-]+" command == null)
      "services.chrome-pwa.browsers.${prefix}: unsupported executable name '${command}'"
      command;

  browserCases = lib.concatStrings (lib.mapAttrsToList
    (prefix: package: ''
      ${lib.escapeShellArg prefix}-*) command=${commandOf prefix package} ;;
    '')
    cfg.browsers);

  script = pkgs.writeShellScript "${name}.sh" ''
    set -euo pipefail
    PATH=${lib.makeBinPath (with pkgs; [ coreutils gnugrep gnused inotify-tools ])}

    fix() {
      local file=$1 command="" original fixed
      [ -f "$file" ] || return 0
      grep -q -- '^Exec=.*--app-id=' "$file" || return 0
      case "$(basename "$file")" in
        ${browserCases}
        *) ;;
      esac

      local -a rules=(-e 's|^#!/nix/store/[^ ]*/|#!/usr/bin/env |')
      if [ -n "$command" ]; then
        rules+=(-e "s|^Exec=[^ ]*|Exec=$command|")
      else
        rules+=(-e 's|^Exec=[^ ]*/|Exec=|')
      fi

      original=$(<"$file")
      fixed=$(sed "''${rules[@]}" <<<"$original")
      [ "$fixed" != "$original" ] || return 0
      printf '%s\n' "$fixed" >"$file"
      echo "Fixed $file"
    }

    mkdir -p "$HOME/.local/share/applications"
    places=()
    for dir in "$HOME/.local/share/applications" "$HOME/.gnome/apps" "$HOME/Desktop"; do
      if [ -d "$dir" ]; then
        places+=("$dir")
      fi
    done

    for dir in "''${places[@]}"; do
      for file in "$dir"/*.desktop; do
        fix "$file"
      done
    done

    inotifywait --monitor --quiet --event close_write --event moved_to \
      --format '%w%f' --include '\.desktop$' "''${places[@]}" |
      while IFS= read -r file; do
        fix "$file"
      done
  '';
in
{
  options.services.chrome-pwa = {
    enable = lib.mkEnableOption "Chrome PWA";

    browsers = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = { };
      example = lib.literalExpression "{ brave = pkgs.brave; chrome = pkgs.google-chrome; }";
      description = ''
        Browsers whose web app shortcuts are pinned to the browser's current
        executable. The attribute name is the shortcut file prefix, e.g. `brave`
        for `brave-<app-id>-Default.desktop`. The command comes from the package's
        `meta.mainProgram`, so existing shortcuts follow a renamed binary the next
        time the service starts.
      '';
    };
  };

  config = lib.mkIf cfg.enable (moduleConfig {
    inherit name;
    description = "Automatically fix chromes progressive web apps desktop shortcuts";
    serviceConfig = {
      # When a monitored directory is deleted, it will stop being monitored.
      # Even if it is later recreated it will not restart monitoring it.
      # Unfortunately the monitor does not kill itself when it stops monitoring,
      # so rather than creating our own restart mechanism, we leverage systemd to do this for us.
      Restart = "always";
      RestartSec = 0;
      ExecStart = "${script}";
    };
  });
}
