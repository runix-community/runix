# kmscon on tty1: a console drawn with real fonts (Pango and FreeType), so
# text is anti-aliased and any font works, unlike the kernel console's 1-bit
# PSF bitmaps. It takes the getty's place and logs in with the same
# /bin/login, in Runix's console colours.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.console.kmscon;

  # console.colors: black, red, green, yellow, blue, magenta, cyan, white,
  # then their bright versions. kmscon wants "r, g, b".
  names = [
    "black"
    "red"
    "green"
    "yellow"
    "blue"
    "magenta"
    "cyan"
    "light-grey"
    "dark-grey"
    "light-red"
    "light-green"
    "light-yellow"
    "light-blue"
    "light-magenta"
    "light-cyan"
    "white"
  ];
  rgb =
    hex:
    lib.concatMapStringsSep ", " (offset: toString (lib.fromHexString (builtins.substring offset 2 hex))) [
      0
      2
      4
    ];
  colors = config.console.colors;
  palette = lib.optionals (colors != null) (
    [ "--palette=custom" ]
    ++ lib.imap0 (index: name: "--palette-${name}=${rgb (builtins.elemAt colors index)}") names
    ++ [
      "--palette-background=${rgb (builtins.elemAt colors 0)}"
      "--palette-foreground=${rgb (builtins.elemAt colors 7)}"
    ]
  );

  command = lib.escapeShellArgs (
    [
      "${cfg.package}/bin/kmscon"
      "--vt=1"
      "--font-engine=pango"
      "--font-name=${cfg.font.name}"
      "--font-size=${toString cfg.font.size}"
    ]
    ++ palette
    ++ cfg.extraArguments
    ++ [
      "--login"
      "--"
      "/bin/login"
      "-p"
    ]
  );
in
{
  options.console.kmscon = {
    enable = lib.mkEnableOption "kmscon on tty1, an anti-aliased console with real fonts";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kmscon;
      defaultText = lib.literalExpression "pkgs.kmscon";
      description = "kmscon package.";
    };
    font = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "Maple Mono";
        description = "Font family, as fontconfig names it.";
      };
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = pkgs.maple-mono.truetype;
        defaultText = lib.literalExpression "pkgs.maple-mono.truetype";
        description = "Package that provides the font; null when it is installed another way.";
      };
      size = lib.mkOption {
        type = lib.types.ints.positive;
        default = 18;
        description = "Font size in pixels.";
      };
    };
    extraArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--hwaccel" ];
      description = "More kmscon options; see kmscon --help.";
    };
  };

  config = lib.mkIf cfg.enable {
    fonts.packages = lib.optional (cfg.font.package != null) cfg.font.package;
    # kmscon takes its seat and the screen through libseat.
    runix.systemServices.seatd.enable = true;
    runix.services.getty = {
      command = lib.mkForce command;
      after = [
        "mdevd-coldplug"
        "seatd"
      ];
      log = false;
    };
  };
}
