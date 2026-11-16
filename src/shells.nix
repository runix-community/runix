# Interactive shells: completion for bash, zsh and fish. /etc/profile only
# reaches login shells; a terminal's shell reads these files instead.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.shells;
  share = "/run/current-system/sw/share";

  bashrc = pkgs.writeText "runix-bashrc" ''
    # Runix: interactive bash.
    [ -z "''${PS1-}" ] && return
    [ -n "''${__RUNIX_BASHRC-}" ] && return
    __RUNIX_BASHRC=1
    export XDG_DATA_DIRS="''${XDG_DATA_DIRS:-${share}}"
    shopt -s checkwinsize
    # Completions for commands, processes (pkill), services (sv) and every
    # installed package that ships them in share/bash-completion.
    if ! shopt -oq posix; then
      . ${pkgs.bash-completion}/share/bash-completion/bash_completion
    fi
  '';

  zshrc = pkgs.writeText "runix-zshrc" ''
    # Runix: interactive zsh.
    [[ -o interactive ]] || return
    fpath+=(${share}/zsh/site-functions ${share}/zsh/vendor-completions)
    autoload -Uz compinit && compinit -u
  '';

  fishConfig = pkgs.writeText "runix-fish-config" ''
    # Runix: completions and functions that installed packages ship.
    if not contains ${share}/fish/vendor_completions.d $fish_complete_path
      set -a fish_complete_path ${share}/fish/vendor_completions.d
    end
    if not contains ${share}/fish/vendor_functions.d $fish_function_path
      set -a fish_function_path ${share}/fish/vendor_functions.d
    end
  '';

  # A hand-written file stays; a missing one or Runix's own link is replaced.
  link = source: target: ''
    if [ ! -e ${target} ] || [ -L ${target} ]; then
      ln -sfn ${source} ${target}
    fi
  '';
in
{
  options.runix.shells.completion = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Tab completion in interactive bash, zsh and fish: /etc/bashrc loads
      bash-completion, /etc/zshrc runs compinit, and /etc/fish/config.fish
      adds the system's completion folders.
    '';
  };

  config = lib.mkIf cfg.completion {
    runix.packages = [ pkgs.bash-completion ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/fish
        ${link bashrc "/etc/bashrc"}
        ${link zshrc "/etc/zshrc"}
        ${link fishConfig "/etc/fish/config.fish"}
      ''
    ];
  };
}
