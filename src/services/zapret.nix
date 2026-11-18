# zapret: gets past deep packet inspection that blocks or slows sites, such as
# YouTube and Discord in Russia. nfqws rewrites the first packets of matching
# connections so the inspection cannot read them; the rest of the traffic is
# untouched. The default strategy is "general" from
# github:Flowseal/zapret-discord-youtube, with its lists of hosts.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.zapret;

  flowseal = pkgs.fetchFromGitHub {
    owner = "Flowseal";
    repo = "zapret-discord-youtube";
    rev = "2401b7a13837139b0265632464ba563dddbf80d8";
    hash = "sha256-/MjMxKemN5qKbEMEkLzF0jTAlOv4EwnHwmrmWotbqXw=";
  };
  bin = "${flowseal}/bin";
  lists = "${flowseal}/lists";

  # Hosts to add or leave alone, beside Flowseal's lists. Never empty, since
  # nfqws treats an empty list as "every host".
  userList =
    name: hosts:
    pkgs.writeText name (lib.concatLines (if hosts == [ ] then [ "domain.invalid" ] else hosts));
  general = "--hostlist=${lists}/list-general.txt --hostlist=${userList "zapret-hosts" cfg.hosts}";
  exclude = "--hostlist-exclude=${lists}/list-exclude.txt --hostlist-exclude=${userList "zapret-exclude" cfg.excludeHosts} --ipset-exclude=${lists}/ipset-exclude.txt";

  ports = lib.concatStringsSep ", ";
  queue = 200;
  # Set by nfqws on packets it sends itself, so they are not queued again.
  mark = "0x40000000";
  rules = pkgs.writeText "zapret.nft" ''
    table inet zapret {
      chain postrouting {
        type filter hook postrouting priority srcnat + 1; policy accept;
        meta mark & ${mark} == ${mark} return
        tcp dport { ${ports cfg.tcpPorts} } ct original packets 1-9 queue flags bypass to ${toString queue}
        udp dport { ${ports cfg.udpPorts} } ct original packets 1-9 queue flags bypass to ${toString queue}
      }
      chain prerouting {
        type filter hook prerouting priority dstnat + 1; policy accept;
        tcp sport { ${ports cfg.tcpPorts} } ct reply packets 1-3 queue flags bypass to ${toString queue}
      }
    }
  '';
  nft = "${pkgs.nftables}/bin/nft";
in
{
  options.runix.systemServices.zapret = {
    enable = lib.mkEnableOption ''
      zapret, which gets past censorship that inspects traffic, as in Russia.
      It unblocks YouTube, Discord and the sites in Flowseal's lists. If they
      still do not load, try another strategy from
      github:Flowseal/zapret-discord-youtube'';
    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "rutracker.org" ];
      description = "More blocked sites to unblock. Subdomains are included.";
    };
    excludeHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Sites zapret must leave alone, for ones that break with it.";
    };
    tcpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "80"
        "443"
        "2053"
        "2083"
        "2087"
        "2096"
        "8443"
      ];
      description = "TCP ports whose connections go through nfqws.";
    };
    udpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "443"
        "19294-19344"
        "50000-50100"
      ];
      description = "UDP ports whose connections go through nfqws: QUIC and Discord voice.";
    };
    strategy = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # QUIC (HTTP/3) to the listed sites.
        "--filter-udp=443 ${general} ${exclude} --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=${bin}/quic_initial_www_google_com.bin"
        # Discord voice.
        "--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord=${bin}/ACTIVE_DISCORD_UDP.bin --dpi-desync-fake-stun=${bin}/ACTIVE_DISCORD_UDP.bin --dpi-desync-repeats=6"
        # Discord media servers.
        "--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=${bin}/tls_clienthello_www_google_com.bin"
        # YouTube and Google.
        "--filter-tcp=443 --hostlist=${lists}/list-google.txt --ip-id=zero --dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=${bin}/tls_clienthello_www_google_com.bin"
        # Everything else in the lists.
        "--filter-tcp=80,443 ${general} ${exclude} --dpi-desync=multisplit --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=${bin}/tls_clienthello_4pda_to.bin"
      ];
      description = ''
        nfqws profiles, tried in order; the first whose filters match a
        connection is used. Payload files from Flowseal's repository are under
        ${"$"}{flowseal}/bin; see `nfqws --help`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    runix.packages = [ pkgs.zapret ];

    runix.services.zapret = {
      script = ''
        ${pkgs.kmod}/bin/modprobe -qa nfnetlink_queue nft_queue nf_conntrack || true
        # Without this, conntrack drops the overlapping packets nfqws sends.
        echo 1 > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal
        ${nft} delete table inet zapret 2>/dev/null || true
        ${nft} -f ${rules}
        exec ${pkgs.zapret}/bin/nfqws --qnum=${toString queue} --dpi-desync-fwmark=${mark} --uid=65534:65534 \
          ${lib.concatStringsSep " --new \\\n  " cfg.strategy}
      '';
      # Traffic passes untouched while nfqws is down ("bypass"), but the
      # rules are removed anyway.
      finish = "${nft} delete table inet zapret 2>/dev/null || true";
    };
  };
}
