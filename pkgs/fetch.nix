{ pkgs }:
let
  pfetch = pkgs.pfetch.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./pfetch-runix.patch ];
  });

  fastfetch = pkgs.fastfetch.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      install -m 0644 ${../assets/runix-logo-fastfetch.txt} src/logo/ascii/r/runix.txt
      substituteInPlace src/logo/ascii/r.inc \
        --replace-fail \
          'static const FFlogo R[] = {' \
          'static const FFlogo R[] = {
    #ifdef FASTFETCH_DATATEXT_LOGO_RUNIX
    // Runix
    {
        .names = { "Runix" },
        .lines = FASTFETCH_DATATEXT_LOGO_RUNIX,
        .colors = {
            FF_COLOR_FG_RGB "125;125;125",
            FF_COLOR_FG_RGB "0;151;80",
        },
        .colorKeys = FF_COLOR_FG_RGB "0;151;80",
        .colorTitle = FF_COLOR_FG_RGB "0;151;80",
    },
    #endif'
    '';
  });
in
{
  inherit fastfetch pfetch;
}
