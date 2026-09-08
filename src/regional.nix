{
  config,
  lib,
  pkgs,
  ...
}:
let
  localeSettings = {
    LANG = config.i18n.defaultLocale;
  }
  // config.i18n.extraLocaleSettings;
  localeEnvironment = localeSettings // {
    LOCALE_ARCHIVE = "${config.i18n.glibcLocales}/lib/locale/locale-archive";
    TZDIR = "${pkgs.tzdata}/share/zoneinfo";
  };
  fontLocalConfig = pkgs.writeText "runix-fontconfig-local.conf" config.fonts.fontconfig.localConf;
  fontDirectories = pkgs.writeText "runix-fontconfig-directories.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <dir>/run/current-system/sw/share/fonts</dir>
    </fontconfig>
  '';
in
{
  options = {
    time.timeZone = lib.mkOption {
      type = lib.types.strMatching "[^ ]+";
      default = "UTC";
      description = "IANA system timezone.";
    };

    i18n = {
      defaultLocale = lib.mkOption {
        type = lib.types.str;
        default = "en_US.UTF-8";
        description = "Default process locale.";
      };
      extraLocaleSettings = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Additional LC_* locale environment variables.";
      };
      glibcLocales = lib.mkOption {
        type = lib.types.package;
        default = pkgs.glibcLocales;
        description = "Locale archive package.";
      };
    };

    console.keyMap = lib.mkOption {
      type = lib.types.str;
      default = "us";
      description = "Linux virtual console keymap.";
    };

    fonts = {
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "System font packages.";
      };
      fontconfig = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to configure Fontconfig system-wide.";
        };
        localConf = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Contents of /etc/fonts/local.conf.";
        };
      };
    };

    services.xserver.xkb = {
      layout = lib.mkOption {
        type = lib.types.str;
        default = "us";
        description = "Comma-separated XKB layouts.";
      };
      variant = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Comma-separated XKB variants.";
      };
      options = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Comma-separated XKB options.";
      };
    };
  };

  config = {
    runix.packages = [
      config.i18n.glibcLocales
      pkgs.kbd
      pkgs.tzdata
    ]
    ++ lib.optional config.fonts.fontconfig.enable pkgs.fontconfig
    ++ config.fonts.packages;
    runix.environmentVariables =
      localeEnvironment
      // {
        XKB_DEFAULT_LAYOUT = config.services.xserver.xkb.layout;
        XKB_DEFAULT_VARIANT = config.services.xserver.xkb.variant;
        XKB_DEFAULT_OPTIONS = config.services.xserver.xkb.options;
      }
      // lib.optionalAttrs config.fonts.fontconfig.enable {
        FONTCONFIG_FILE = "/etc/fonts/fonts.conf";
      };
    runix.preparationScripts = [
      ''
        ln -sfn ${pkgs.tzdata}/share/zoneinfo/${config.time.timeZone} /etc/localtime
        printf '%s\n' ${lib.escapeShellArg config.i18n.defaultLocale} > /etc/locale.conf
        ${lib.optionalString config.fonts.fontconfig.enable ''
          mkdir -p /etc/fonts/conf.d
          ln -sfn ${pkgs.fontconfig.out}/etc/fonts/fonts.conf /etc/fonts/fonts.conf
          ln -sfn ${fontDirectories} /etc/fonts/conf.d/00-runix-font-directories.conf
          ${lib.optionalString (config.fonts.fontconfig.localConf != "") ''
            ln -sfn ${fontLocalConfig} /etc/fonts/local.conf
          ''}
        ''}
      ''
    ];
    runix.activationScripts = lib.optional (!config.runix.virtualMachine.enable) ''
      ${pkgs.kbd}/bin/loadkeys ${lib.escapeShellArg config.console.keyMap} || true
    '';
  };
}
