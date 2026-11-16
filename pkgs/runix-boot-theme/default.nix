# The Runix boot look: a GRUB theme and a Limine wallpaper, both drawn from
# the snowflake logo and the console palette (Runix green on near-black).
{
  runCommand,
  imagemagick,
  librsvg,
  grub2,
  rubik,
  spleen,
}:
let
  logo = ../../assets/runix-logo.svg;
in
runCommand "runix-boot-theme"
  {
    nativeBuildInputs = [
      imagemagick
      librsvg
      grub2
    ];
  }
  ''
    grub=$out/grub/runix
    mkdir -p $grub $out/limine
    cd $grub

    # Near-black with a soft green glow from the lower left and a faint
    # snowflake on the right.
    magick -size 3200x3200 radial-gradient:'#15301f-#0e1110' \
      -gravity center -crop 1920x1080-700+620 +repage base.png
    rsvg-convert -w 900 -h 900 ${logo} \
      | magick - -alpha on -channel A -evaluate multiply 0.045 +channel mark.png
    magick base.png mark.png -gravity east -geometry +-120+60 -composite \
      -depth 8 PNG24:background.png
    cp background.png $out/limine/background.png
    # Limine's look; the wallpaper line is added where its path is known.
    cat > $out/limine/theme.conf <<'LIMINE'
    interface_branding: Runix
    interface_branding_color: 2
    interface_branding_colour: 2
    wallpaper_style: stretched
    term_palette: 0e1110;e0574f;00a35a;d9a441;4f8fd1;b07fd1;3fb5a5;c8ccc6
    term_palette_bright: 4d5450;f0736a;2fd07f;f0c060;74aef0;cc9ef0;66d6c6;f1f3ef
    term_background: 600e1110
    term_foreground: c8ccc6
    term_background_bright: 4d5450
    term_foreground_bright: f1f3ef
    term_margin: 64
    LIMINE
    sed -i 's/^    //' $out/limine/theme.conf
    rm base.png mark.png

    rsvg-convert -w 72 -h 72 ${logo} -o logo.png

    # GRUB draws a styled box from nine pieces; give it all nine.
    solid() {
      for piece in c n s e w nw ne sw se; do
        magick -size $3x$3 xc:"$2" PNG32:$1_$piece.png
      done
    }

    # The selected entry: a green rounded box.
    solid select '#00a35a' 6
    magick -size 12x12 xc:none -fill '#00a35a' -draw 'roundrectangle 0,0 11,11 6,6' corner.png
    magick corner.png -crop 6x6+0+0 +repage PNG32:select_nw.png
    magick corner.png -crop 6x6+6+0 +repage PNG32:select_ne.png
    magick corner.png -crop 6x6+0+6 +repage PNG32:select_sw.png
    magick corner.png -crop 6x6+6+6 +repage PNG32:select_se.png
    rm corner.png

    solid scroll_frame '#1a201d' 2
    solid scroll_thumb '#00a35a' 2
    solid terminal_box '#141917' 8

    font=$(find ${rubik} -iname 'Rubik-Regular.ttf' -o -iname 'Rubik\[*.ttf' -o -iname 'Rubik-VariableFont*.ttf' | head -n1)
    grub-mkfont -s 15 -n Rubik -o rubik-15.pf2 "$font"
    grub-mkfont -s 20 -n Rubik -o rubik-20.pf2 "$font"
    grub-mkfont -b -s 20 -n Rubik -o rubik-bold-20.pf2 "$font"
    grub-mkfont -b -s 40 -n Rubik -o rubik-bold-40.pf2 "$font"
    # The console and the entry editor need a monospace font: Spleen, as
    # on the Linux console.
    grub-mkfont -n Spleen -o spleen-24.pf2 $(find ${spleen} -name 'spleen-12x24.bdf' | head -n1)

    cat > theme.txt <<'THEME'
    title-text: ""
    desktop-image: "background.png"
    desktop-image-scale-method: "stretch"
    desktop-color: "#0e1110"
    terminal-font: "Spleen Regular 24"
    terminal-box: "terminal_box_*.png"
    terminal-left: "8%"
    terminal-top: "24%"
    terminal-width: "84%"
    terminal-height: "58%"

    + image {
      left = 8%
      top = 11%
      file = "logo.png"
    }
    + label {
      left = 8%+92
      top = 11%+2
      width = 600
      height = 48
      text = "Runix"
      font = "Rubik Bold 40"
      color = "#f1f3ef"
    }
    + label {
      left = 8%+94
      top = 11%+50
      width = 600
      height = 24
      text = "A NixOS that runs on Runit"
      font = "Rubik Regular 15"
      color = "#6f7872"
    }

    + boot_menu {
      left = 8%
      top = 28%
      width = 52%
      height = 52%
      item_font = "Rubik Regular 20"
      item_color = "#c8ccc6"
      selected_item_font = "Rubik Bold 20"
      selected_item_color = "#0e1110"
      selected_item_pixmap_style = "select_*.png"
      item_height = 32
      item_padding = 8
      item_spacing = 14
      icon_width = 0
      icon_height = 0
      item_icon_space = 0
      scrollbar = true
      scrollbar_width = 4
      scrollbar_frame = "scroll_frame_*.png"
      scrollbar_thumb = "scroll_thumb_*.png"
    }

    + label {
      id = "__timeout__"
      left = 8%
      top = 84%+14
      width = 52%
      height = 22
      text = "Booting the first entry in %d s"
      font = "Rubik Regular 15"
      color = "#6f7872"
    }
    + label {
      left = 8%
      top = 84%+40
      width = 52%
      height = 22
      text = "Enter boots  ·  E edits the entry  ·  C opens the GRUB console"
      font = "Rubik Regular 15"
      color = "#4d5450"
    }
    THEME
    sed -i 's/^    //' theme.txt
  ''
