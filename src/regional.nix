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
  # vt.default_red, _grn and _blu take one decimal value per colour.
  hexDigit = digit: lib.toLower digit;
  hexValue =
    text:
    lib.foldl' (total: digit: total * 16 + lib.strings.toInt (
      {
        a = "10"; b = "11"; c = "12"; d = "13"; e = "14"; f = "15";
      }.${hexDigit digit} or digit
    )) 0 (lib.stringToCharacters text);
  colorChannel =
    offset: lib.concatMapStringsSep "," (color: toString (hexValue (builtins.substring offset 2 color))) config.console.colors;

  consoleFonts = pkgs.buildEnv {
    name = "runix-console-fonts";
    paths = config.console.packages;
    pathsToLink = [ "/share/consolefonts" ];
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

    console = {
      keyMap = lib.mkOption {
        type = lib.types.str;
        default = "us";
        description = "Linux virtual console keymap.";
      };
      font = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
        default = "spleen-12x24";
        example = "ter-v22b";
        description = ''
          Font for the Linux virtual consoles: a name from the consolefonts of
          `console.packages`, such as spleen-16x32 for high-DPI screens or
          ter-v22b for Terminus, or a path to a PSF file. Null keeps the
          kernel's built-in font.
        '';
      };
      colors = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf (lib.types.strMatching "[0-9a-fA-F]{6}"));
        # The installer's palette: Runix green on a near-black background.
        default = [
          "0e1110" "e0574f" "00a35a" "d9a441" "4f8fd1" "b07fd1" "3fb5a5" "c8ccc6"
          "4d5450" "f0736a" "2fd07f" "f0c060" "74aef0" "cc9ef0" "66d6c6" "f1f3ef"
        ];
        description = ''
          The 16 Linux console colours as hex RGB, black first and bright
          white last. The kernel applies them from the first line of boot.
          Null keeps the kernel's own VGA colours.
        '';
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ pkgs.spleen ];
        defaultText = lib.literalExpression "[ pkgs.spleen ]";
        example = lib.literalExpression "[ pkgs.terminus_font ]";
        description = "Packages whose share/consolefonts `console.font` names a font from.";
      };
      bell.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the audible bell is enabled on Linux virtual consoles.";
      };
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
    # The framebuffer console normally takes over only once something is
    # printed, and that resets any font set before it. Take over at boot, so
    # the font set during activation stays.
    runix.kernel.parameters =
      lib.optional (config.console.font != null) "fbcon=nodefer"
      ++ lib.optionals (config.console.colors != null) [
        "vt.default_red=${colorChannel 0}"
        "vt.default_grn=${colorChannel 2}"
        "vt.default_blu=${colorChannel 4}"
      ];
    assertions = [
      {
        assertion = config.console.colors == null || builtins.length config.console.colors == 16;
        message = "console.colors needs exactly 16 colours";
      }
    ];
    runix.activationScripts = lib.optional (!config.runix.virtualMachine.enable) ''
      ${pkgs.kbd}/bin/loadkeys ${lib.escapeShellArg config.console.keyMap} || true
      ${lib.optionalString (config.console.font != null) ''
        font=${lib.escapeShellArg config.console.font}
        case "$font" in
          /*) ;;
          *)
            dir=${consoleFonts}/share/consolefonts
            for candidate in "$dir/$font" "$dir/$font.psfu" "$dir/$font.psf" "$dir/$font.psfu.gz" "$dir/$font.psf.gz"; do
              if [ -e "$candidate" ]; then font=$candidate; break; fi
            done
            ;;
        esac
        if [ -e "$font" ]; then
          # Each console has its own font; set it on the ones that log in.
          for tty in /dev/tty[1-6]; do
            [ -c "$tty" ] || continue
            ${pkgs.kbd}/bin/setfont -C "$tty" "$font" 2>/dev/null || true
          done
        else
          echo "runix: console font not found: $font" >&2
        fi
      ''}
      ${lib.optionalString (!config.console.bell.enable) ''
        for tty in /dev/tty[1-9]*; do
          [ -c "$tty" ] || continue
          ${pkgs.util-linux}/bin/setterm --term linux --blength 0 > "$tty" || true
        done
      ''}
    '';
  };
}
