{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.wifi;
  stateDirectory = "/var/lib/runix/wifi";
  controlDirectory = "/run/wpa_supplicant";
  configFile = "${stateDirectory}/wpa_supplicant.conf";
  networkConfig = lib.concatMapAttrsStringSep "\n" (ssid: network: ''
    network={
      ssid=${builtins.toJSON ssid}
      key_mgmt=${if network.password == null then "NONE" else "WPA-PSK"}
      ${lib.optionalString (network.password != null) "psk=${builtins.toJSON network.password}"}
      ${lib.optionalString network.hidden "scan_ssid=1"}
    }
  '') cfg.networks;
  declarativeConfig = pkgs.writeText "runix-wpa-supplicant.conf" networkConfig;
  prepareState = ''
    mkdir -p ${controlDirectory}/client ${stateDirectory}
    if [ ! -e ${configFile} ]; then
      cat > ${configFile} <<'EOF'
    ctrl_interface=DIR=${controlDirectory} GROUP=wheel
    update_config=1
    EOF
    fi
    # Desktop shells (blxshell) join networks as the user, through the
    # control socket: let wheel use it, also in existing configs.
    ${pkgs.gnused}/bin/sed -i 's|^ctrl_interface=${controlDirectory}$|ctrl_interface=DIR=${controlDirectory} GROUP=wheel|' ${configFile} || true
    chmod 0600 ${configFile}
  '';
  interfaceScript = ''
    interface=${lib.escapeShellArg cfg.interface}
    if [ -z "$interface" ]; then
      for wireless in /sys/class/net/*/wireless; do
        [ -d "$wireless" ] || continue
        interface="''${wireless%/wireless}"
        interface="''${interface##*/}"
        break
      done
    fi
    [ -n "$interface" ] || {
      echo "runix-network: no wireless interface found" >&2
      exit 1
    }
  '';
  cli = pkgs.writeShellApplication {
    name = "runix-network";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.dhcpcd
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.util-linux
      pkgs.wpa_supplicant
    ];
    text = ''
      usage() {
        cat <<'EOF'
      Usage: runix-network COMMAND [ARGUMENTS]

      Commands:
        status                         Show Wi-Fi and IP status
        scan                           Scan for nearby networks
        connect SSID [PASSWORD]        Connect to an open or WPA network
        disconnect                     Disconnect Wi-Fi
        networks                       List saved networks
        forget NETWORK_ID              Remove a saved network
      EOF
      }

      ${interfaceScript}
      # Runs a wpa_cli command that must answer OK.
      cli() {
        reply=$(wpa_cli -p ${controlDirectory} -i "$interface" "$@")
        [ "$reply" = OK ] || { echo "runix-network: wpa_supplicant refused '$1 ''${2:-}': $reply" >&2; exit 1; }
      }
      action="''${1:-}"
      case "$action" in
        status)
          wpa_cli -p ${controlDirectory} -i "$interface" status
          ip address show dev "$interface"
          ;;
        scan)
          wpa_cli -p ${controlDirectory} -i "$interface" scan >/dev/null || true
          # Scans take several seconds on many cards; wait for results.
          tries=0
          while [ "$(wpa_cli -p ${controlDirectory} -i "$interface" scan_results | wc -l)" -le 1 ] && [ "$tries" -lt 10 ]; do
            sleep 1
            tries=$((tries + 1))
          done
          wpa_cli -p ${controlDirectory} -i "$interface" scan_results
          ;;
        connect)
          [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
          [ "$(id -u)" -eq 0 ] || { echo "runix-network: connect requires root" >&2; exit 1; }
          rfkill unblock wlan || true
          ip link set "$interface" up 2>/dev/null || {
            echo "runix-network: cannot bring up $interface (RF-kill still active?)" >&2
            exit 1
          }
          echo "runix-network: connecting to $2 ..."
          ssid=$2
          network_id=$(wpa_cli -p ${controlDirectory} -i "$interface" add_network)
          case "$network_id" in *[!0-9]*|"") echo "runix-network: failed to add network" >&2; exit 1 ;; esac
          ssid_hex=$(printf '%s' "$ssid" | od -An -tx1 | tr -d ' \n')
          cli set_network "$network_id" ssid "$ssid_hex"
          if [ "$#" -eq 3 ]; then
            psk=$(wpa_passphrase "$ssid" "$3" | grep -E '^[[:space:]]*psk=[0-9a-f]{64}$')
            psk=''${psk#*=}
            cli set_network "$network_id" psk "$psk"
          else
            cli set_network "$network_id" key_mgmt NONE
          fi
          cli set_network "$network_id" scan_ssid 1
          cli select_network "$network_id"
          cli enable_network "$network_id"
          cli reassociate
          # Saving is best effort: the connection works without it.
          wpa_cli -p ${controlDirectory} -i "$interface" save_config >/dev/null || true
          tries=0
          # Not `grep -q`: under pipefail, its early exit can fail the pipe
          # with SIGPIPE even when the line is there.
          until wpa_cli -p ${controlDirectory} -i "$interface" status | grep -x 'wpa_state=COMPLETED' >/dev/null; do
            tries=$((tries + 1))
            if [ "$tries" -ge 30 ]; then
              state=$(wpa_cli -p ${controlDirectory} -i "$interface" status | grep '^wpa_state=' || true)
              echo "runix-network: association with $ssid timed out (''${state:-no state})" >&2
              exit 1
            fi
            sleep 1
          done
          echo "runix-network: associated with $ssid, requesting DHCP lease ..."
          dhcpcd -n "$interface" || dhcpcd "$interface" || true
          tries=0
          # A 169.254 link-local address is not a lease; wait for a real one
          # and its default route.
          until ip -4 address show dev "$interface" | grep '^[[:space:]]*inet ' | grep -v ' 169\.254\.' >/dev/null &&
            ip -4 route show default dev "$interface" | grep '^default ' >/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -lt 45 ] || { echo "runix-network: joined $ssid, but got no address from DHCP" >&2; exit 1; }
            sleep 1
          done
          echo "runix-network: connected to $ssid"
          ;;
        disconnect)
          [ "$(id -u)" -eq 0 ] || { echo "runix-network: disconnect requires root" >&2; exit 1; }
          wpa_cli -p ${controlDirectory} -i "$interface" disconnect
          ;;
        networks)
          wpa_cli -p ${controlDirectory} -i "$interface" list_networks
          ;;
        forget)
          [ "$#" -eq 2 ] || { usage >&2; exit 2; }
          [ "$(id -u)" -eq 0 ] || { echo "runix-network: forget requires root" >&2; exit 1; }
          wpa_cli -p ${controlDirectory} -i "$interface" remove_network "$2" >/dev/null
          wpa_cli -p ${controlDirectory} -i "$interface" save_config >/dev/null
          ;;
        -h|--help|help) usage ;;
        *) usage >&2; exit 2 ;;
      esac
    '';
  };
in
{
  options.runix.systemServices.wifi = {
    enable = lib.mkEnableOption "Wi-Fi through wpa_supplicant and dhcpcd";
    interface = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Wireless interface name, or empty to detect it automatically.";
    };
    networks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            password = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "WPA passphrase, or null for an open network.";
            };
            hidden = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether the network hides its SSID.";
            };
          };
        }
      );
      default = { };
      description = "Networks written to a new persistent wpa_supplicant configuration.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.runix.systemServices.networkManager.enable;
        message = "runix.systemServices.wifi cannot be used with NetworkManager";
      }
    ];
    runix.systemServices.dhcpcd.enable = true;
    runix.packages = [
      cli
      pkgs.wpa_supplicant
    ];
    runix.preparationScripts = [ prepareState ];
    runix.services = {
      wpa-supplicant = {
        script = ''
          ${prepareState}
          ${interfaceScript}
          ${pkgs.util-linux}/bin/rfkill unblock wlan || true
          ${pkgs.iproute2}/bin/ip link set "$interface" up
          exec ${pkgs.wpa_supplicant}/bin/wpa_supplicant -i "$interface" -c ${configFile}${
            lib.optionalString (cfg.networks != { }) " -I ${declarativeConfig}"
          }
        '';
        after = [ "mdevd-coldplug" ];
        check = ''
          ${interfaceScript}
          [ "$(${pkgs.wpa_supplicant}/bin/wpa_cli -p ${controlDirectory} -i "$interface" ping)" = PONG ]
        '';
      };
      dhcpcd.after = [ "wpa-supplicant" ];
    };
  };
}
