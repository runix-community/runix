# Serving websites: Caddy for the sites, and a Cloudflare Tunnel to put them
# on your domain without opening ports or getting certificates (Cloudflare
# serves HTTPS). Caddy only listens on 127.0.0.1 when the tunnel fronts it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  caddy = config.runix.systemServices.caddy;
  tunnel = config.runix.systemServices.cloudflared;
  # A site named like ":80" is an address, served directly (on the local
  # network), never through the tunnel.
  isAddress = host: lib.hasPrefix ":" host;
  tunneled = host: caddy.behindTunnel && !isAddress host;
  bindsLowPorts = !caddy.behindTunnel || lib.any isAddress (lib.attrNames caddy.sites);

  siteType = lib.types.submodule {
    options = {
      root = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/srv/www/example.org";
        description = "Directory of files to serve.";
      };
      proxy = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "127.0.0.1:3000";
        description = "Address of an app to pass requests to, instead of serving files.";
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "More Caddyfile directives for this site.";
      };
    };
  };

  # Behind the tunnel, Cloudflare does HTTPS: Caddy serves plain HTTP on
  # localhost and picks the site by the Host header.
  caddyfile = pkgs.writeText "Caddyfile" (
    ''
      {
        admin off
        ${lib.optionalString caddy.behindTunnel "auto_https off"}
      }
    ''
    + lib.concatMapAttrsStringSep "\n" (host: site: ''
      ${if tunneled host then "http://${host}:${toString caddy.port}" else host} {
        ${lib.optionalString (tunneled host) "bind 127.0.0.1"}
        encode zstd gzip
        ${lib.optionalString (site.root != null) ''
          root * ${site.root}
          file_server
        ''}
        ${lib.optionalString (site.proxy != null) "reverse_proxy ${site.proxy}"}
        ${site.extraConfig}
      }
    '') caddy.sites
  );

  tunnelConfig = pkgs.writeText "cloudflared.yml" (
    ''
      tunnel: ${tunnel.tunnelId}
      credentials-file: ${tunnel.credentialsFile}
      ingress:
    ''
    + lib.concatMapAttrsStringSep "" (host: service: ''
      - hostname: ${host}
        service: ${service}
    '') tunnel.ingress
    + ''
      - service: http_status:404
    ''
  );
in
{
  options.runix.systemServices = {
    caddy = {
      enable = lib.mkEnableOption "the Caddy web server";
      sites = lib.mkOption {
        type = lib.types.attrsOf siteType;
        default = { };
        example = {
          ":80".root = "/srv/www";
          "example.org".root = "/srv/www/example.org";
          "app.example.org".proxy = "127.0.0.1:3000";
        };
        description = ''
          Sites by host name. A name like ":80" is an address instead:
          every request on that port, served directly, for the local network.
        '';
      };
      behindTunnel = lib.mkOption {
        type = lib.types.bool;
        default = tunnel.enable;
        defaultText = lib.literalExpression "config.runix.systemServices.cloudflared.enable";
        description = ''
          Serve plain HTTP on 127.0.0.1 for a Cloudflare Tunnel. Off, Caddy
          answers on ports 80 and 443 and gets certificates itself, which
          needs those ports reachable from the internet.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Local port behind the tunnel.";
      };
    };

    cloudflared = {
      enable = lib.mkEnableOption "a Cloudflare Tunnel";
      tunnelId = lib.mkOption {
        type = lib.types.str;
        example = "6ff42ae2-765d-4adf-8112-31c55c1551ef";
        description = "The tunnel's UUID, from `cloudflared tunnel create NAME`.";
      };
      credentialsFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/cloudflared/tunnel.json";
        description = "The tunnel's credentials, kept out of the Nix store.";
      };
      ingress = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "example.org" = "http://127.0.0.1:8080";
        };
        description = ''
          What each public host name reaches. Caddy's sites are added
          automatically when Caddy runs behind the tunnel.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf caddy.enable {
      assertions = lib.mapAttrsToList (host: site: {
        assertion = (site.root == null) != (site.proxy == null);
        message = "runix.systemServices.caddy.sites.${host}: set exactly one of root and proxy";
      }) caddy.sites;
      runix.groups.caddy.gid = 239;
      runix.users.caddy = {
        uid = 239;
        gid = 239;
        home = "/var/lib/caddy";
        shell = "/bin/false";
      };
      runix.packages = [ pkgs.caddy ];
      runix.preparationScripts = [
        "install -d -m 0750 -o 239 -g 239 /var/lib/caddy"
      ]
      # Site folders exist from the start; fill them as root (or chown them).
      ++ lib.mapAttrsToList (
        _: site: "[ -e ${lib.escapeShellArg site.root} ] || install -d -m 0755 ${lib.escapeShellArg site.root}"
      ) (lib.filterAttrs (_: site: site.root != null) caddy.sites);
      # Ports 80 and 443 without root, for Caddy serving them directly.
      boot.kernel.sysctl = lib.mkIf bindsLowPorts {
        "net.ipv4.ip_unprivileged_port_start" = 80;
      };
      runix.services.caddy = {
        user = "caddy";
        group = "caddy";
        environment = {
          HOME = "/var/lib/caddy";
          XDG_DATA_HOME = "/var/lib/caddy";
          XDG_CONFIG_HOME = "/var/lib/caddy";
        };
        command = "${lib.getExe pkgs.caddy} run --adapter caddyfile --config ${caddyfile}";
      };
      runix.systemServices.cloudflared.ingress = lib.mkIf caddy.behindTunnel (
        lib.mapAttrs (_: _: "http://127.0.0.1:${toString caddy.port}") (
          lib.filterAttrs (host: _: !isAddress host) caddy.sites
        )
      );
    })

    (lib.mkIf tunnel.enable {
      runix.packages = [ pkgs.cloudflared ];
      runix.preparationScripts = [ "install -d -m 0700 /var/lib/cloudflared" ];
      runix.services.cloudflared = {
        after = lib.optional caddy.enable "caddy";
        script = ''
          if [ ! -r ${lib.escapeShellArg tunnel.credentialsFile} ]; then
            echo "cloudflared: ${tunnel.credentialsFile} is missing" >&2
            exec ${pkgs.coreutils}/bin/sleep 60
          fi
          exec ${lib.getExe pkgs.cloudflared} tunnel --no-autoupdate --config ${tunnelConfig} run
        '';
      };
    })
  ];
}
