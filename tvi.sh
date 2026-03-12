#!/usr/bin/env bash
# vidfade.sh v2.4 - Interactive video trim/crop/fade with mpv+ffmpeg
set -euo pipefail

# Config & defaults
FFMPEG="ffmpeg -y -hide_banner -loglevel warning"
FFPROBE="ffprobe -v error"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/vidfade.conf"
: ${RES:=1920x1080} ${FIN:=2} ${FOUT:=3} ${FSIZE:=60} ${LSPC:=80} ${SPD:=160} ${QUALITY:=good}
[[ -f "$CFG" ]] && . "$CFG"
case "$QUALITY" in draft)PRESET=veryfast CRF=23;;best)PRESET=veryslow CRF=15;;*)PRESET=slow CRF=18;;esac

# Helpers
die(){ printf '%s: %s\n' "${0##*/}" "$*" >&2;exit 2;}
have(){ type -P "$1" >/dev/null;}
ask(){ local v;read -rep "$1 " v </dev/tty;printf '%s' "${v:-$2}";}
esc(){ local s="$1";s="${s//\\/\\\\}";s="${s//:/\\:}";s="${s//=/\\=}";s="${s//,/\\,}";s="${s//\[/\\[}";s="${s//\]/\\]}";s="${s// /\\ }";printf '%s' "$s";}
to_sec(){ awk -v t="$1" 'BEGIN{n=split(t,a,":");print(n==1)?t+0:(n==2)?a[1]*60+a[2]:a[1]*3600+a[2]*60+a[3]}';}
hex2dec(){ printf '%d' "0x$1";}
invclr(){ printf '%02x%02x%02x' $((255-$(hex2dec ${1:0:2}))) $((255-$(hex2dec ${1:2:2}))) $((255-$(hex2dec ${1:4:2})));}

# Check deps
for c in ffmpeg ffprobe mpv socat awk od realpath head grep setsid gimp audacity eog nano;do have "$c"||die "Missing: $c";done

# Probe: duration|fps|hasaudio|width,height|rotation
probe(){ 
    local dur fps has_audio width height rot
    dur=$($FFPROBE -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null|head -1)
    width=$($FFPROBE -select_streams v:0 -show_entries stream=width -of csv=p=0 "$1" 2>/dev/null|head -1)
    height=$($FFPROBE -select_streams v:0 -show_entries stream=height -of csv=p=0 "$1" 2>/dev/null|head -1)
    fps=$($FFPROBE -select_streams v:0 -show_entries stream=avg_frame_rate -of csv=p=0 "$1" 2>/dev/null|awk -F/ '{print($2==0)?25:$1/$2}')
    has_audio=0;$FFPROBE -select_streams a:0 -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null|grep -q '^[0-9]'&&has_audio=1
    rot=$($FFPROBE -select_streams v:0 -show_entries stream_tags=rotate -of csv=p=0 "$1" 2>/dev/null|awk '{d=$1+0;print(d%360+360)%360}')
    printf '%s|%s|%s|%s,%s|%s\n' "${dur:-0}" "${fps:-25}" "$has_audio" "${width:-0}" "${height:-0}" "${rot:-0}"
}

# Sample color at timestamp
avgclr(){ 
    local clr
    clr=$($FFMPEG -ss "$2" -i "$1" -vf scale=1:1,format=rgb24 -vframes 1 -f rawvideo - 2>/dev/null|od -An -tu1 -N3|awk '{printf "%02x%02x%02x",$1,$2,$3}')
    [[ "$clr" =~ ^[0-9a-f]{6}$ ]]&&printf '%s' "$clr"||printf '000000'
}

# Mark IN/OUT with mpv
mark(){
    local sock="/tmp/vidfade.$$.sock" pid s e
    mpv --input-ipc-server="$sock" --pause --keep-open --title="vidfade: mark IN/OUT" "$1" </dev/null >/dev/null 2>&1 & pid=$!
    for i in {1..50};do [[ -S "$sock" ]]&&break;kill -0 $pid 2>/dev/null||die "mpv died";sleep .1;done
    [[ -S "$sock" ]]||die "mpv timeout"
    gett(){ echo '{"command":["get_property","time-pos"]}'|socat -t2 - "$sock" 2>/dev/null|grep -oP '(?<="data":)[0-9.]+'||echo 0;}
    printf '[*] mpv: Space=play/pause, arrows=seek\n' >&2
    read -p "Mark START..." </dev/tty;s=$(gett);printf 'START=%ss\n' "$s" >&2
    read -p "Mark END..." </dev/tty;e=$(gett);printf 'END=%ss\n' "$e" >&2
    echo '{"command":["quit"]}'|socat - "$sock" &>/dev/null;wait $pid 2>/dev/null||true;rm -f "$sock"
    awk -v a="$s" -v b="$e" 'BEGIN{d=b-a;printf "%s|%s",(d<0)?0:d,a}'
}

# GIMP helper (non-blocking, prompts for rotate then crop)
gimp_aid(){
    local tmp="${1%.*}_crop_frame.png"
    printf 'Extracting frame...\n'
    # Use -frames:v 1 instead of -update 1, redirect stderr to hide warnings
    $FFMPEG -ss "$2" -i "$1" -frames:v 1 -y "$tmp" 2>/dev/null
    if [[ ! -f "$tmp" ]];then
        printf 'Frame extraction failed, skipping GIMP\n' >&2
        printf '|'
        return
    fi
    printf '\n=== GIMP Workflow ===\n'
    printf '1. Image → Transform → Arbitrary Rotation (note degrees)\n'
    printf '2. Image → Crop to Selection (fixed aspect 16:9)\n'
    printf '3. Leave GIMP open, return to terminal\n\n'
    setsid gimp "$tmp" </dev/null >/dev/null 2>&1 &
    disown
    sleep 1  # Give GIMP time to start
    read -p "Enter rotation degrees: " R </dev/tty
    read -p "Enter crop W:H:X:Y: " C </dev/tty
    printf '%s|%s' "$R" "$C"
}

# Thumbnail generator
gen_thumb(){
    local mid thumb title
    mid=$(awk -v d="$D" -v s="$S" 'BEGIN{print s+d/2}')
    thumb="${OUT%.*}_thumb.png"
    title=$(head -1 "$TXT"|tr '\n' ' ')
    printf 'Generating thumbnail...\n'
    $FFMPEG -ss "$mid" -i "$IN" -vf "scale=$W:$H:force_original_aspect_ratio=decrease,pad=$W:$H:(ow-iw)/2:(oh-ih)/2:0x$FADE,drawtext=fontfile=$(esc "$FONT_FILE"):text='$title':fontsize=$((FSIZE*60)):fontcolor=0x$FONT:x=(w-text_w)/2:y=(h-text_h)/2:shadowcolor=0x45555e@0.8:shadowx=8:shadowy=8" -frames:v 1 -y "$thumb" 2>/dev/null
    printf 'Saved: %s\n' "$thumb"
    have eog && setsid eog "$thumb" </dev/null >/dev/null 2>&1 & disown
}

#############################################################################
# MAIN
#############################################################################
THUMB_ONLY=0
[[ "${1:-}" == "--thumb" ]]&&{ THUMB_ONLY=1;shift;}
[[ $# -lt 1 ]]&&die "Usage: ${0##*/} video.mp4 [--thumb]"
IN="$(realpath "$1")"||die "Bad input: $1"
OUT="${IN%.*}_edited.mp4"

# Probe
IFS='|' read DUR FPS HASA WH ROT <<<$(probe "$IN")
W=${WH%,*};H=${WH#*,}
printf '=== vidfade v2.4 ===\nInput: %s\nDuration: %ss | FPS: %s | Audio: %s | %dx%d | Rotation: %s°\n' \
    "$IN" "$DUR" "$FPS" "$([[ $HASA -eq 1 ]]&&echo yes||echo no)" "$W" "$H" "$ROT"

# Trim
printf '\n=== Trim ===\n'
IFS='|' read D S <<<$(mark "$IN")
[[ -z "$D" || $(awk -v d="$D" 'BEGIN{print(d<=0)}') -eq 1 ]]&&{ S=$(to_sec $(ask "Start [0]:" 0));D=$(awk -v t="$DUR" -v s="$S" 'BEGIN{print t-s}');}
printf 'Trim: %ss + %ss\n' "$S" "$D"

# Settings
printf '\n=== Settings ===\n'
QUALITY=$(ask "Quality [draft/good/best] [$QUALITY]:" "$QUALITY")
case "$QUALITY" in draft)PRESET=veryfast CRF=23;;best)PRESET=veryslow CRF=15;;*)PRESET=slow CRF=18;;esac
printf 'Using: preset=%s crf=%s\n' "$PRESET" "$CRF"
RES=$(ask "Resolution [$RES]:" "$RES");W=${RES%x*};H=${RES#*x}
FIN=$(ask "Fade-in [$FIN]:" "$FIN");FOUT=$(ask "Fade-out [$FOUT]:" "$FOUT")

# Colors (INVERTED - sampled becomes font, inverted becomes fade)
printf '\n=== Colors ===\n'
SAMP=$(awk -v s="$S" -v d="$D" 'BEGIN{print s+((d/2>2)?2:d/2)}')
SAMPLED=$(avgclr "$IN" "$SAMP");FADE=$(invclr "$SAMPLED");FONT=$SAMPLED
printf 'Sampled: #%s → Fade: #%s | Font: #%s\n' "$SAMPLED" "$FADE" "$FONT"
[[ $(ask "Override? [y/N]:" n) =~ ^[Yy] ]]&&{ FADE=$(ask "Fade hex [$FADE]:" "$FADE");FONT=$(ask "Font hex [$FONT]:" "$FONT");}

# Orientation
printf '\n=== Orientation ===\n'
VFROT="";META=()
if [[ -n "$ROT" && "$ROT" != "0" ]];then
    printf 'Detected: %s°\n' "$ROT"
    [[ $(ask "Normalize? [Y/n]:" y) =~ ^[Yy]|^$ ]]&&{
        case $ROT in 
            90)VFROT="transpose=1";;
            180)VFROT="transpose=2,transpose=2";;
            270)VFROT="transpose=2";;
            *)VFROT="rotate=$(awk -v d="$ROT" 'BEGIN{pi=atan2(0,-1);print d*pi/180}'):fillcolor=0x${FADE}@1";;
        esac
        META=(-metadata:s:v:0 rotate=0)
    }
fi
[[ $H -gt $W ]]&&printf 'WARNING: Portrait %dx%d\n' "$W" "$H"

# Crop/Rotate
printf '\n=== Crop/Rotate ===\n'
VFCROP="";R="";C=""
if [[ $(ask "GIMP aid? [y/N]:" n) =~ ^[Yy] ]] && have gimp;then
    IFS='|' read R C <<<$(gimp_aid "$IN" "$SAMP")
else
    R=$(ask "Rotate deg []:" "")
    C=$(ask "Crop W:H:X:Y []:" "")
fi
[[ -n "$C" ]]&&VFCROP="crop=$C"
[[ -n "$R" && -z "$VFROT" ]]&&VFROT="rotate=$(awk -v d="$R" 'BEGIN{pi=atan2(0,-1);print d*pi/180}'):fillcolor=0x${FADE}@1"

# Title
printf '\n=== Title ===\n'
TXT="${IN%.*}.ffmpegtext.txt";[[ ! -f "$TXT" ]]&&printf 'Title\nSubtitle\n' >"$TXT"
FONT_FILE="$HOME/.fonts/MonomakhUnicode.otf";[[ ! -f "$FONT_FILE" ]]&&FONT_FILE="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FSIZE=$(ask "Font size [$FSIZE]:" "$FSIZE");LSPC=$(ask "Line spacing [$LSPC]:" "$LSPC");SPD=$(ask "Scroll speed [$SPD]:" "$SPD")
[[ $(ask "Edit text? [Y/n]:" y) =~ ^[Yy]|^$ ]]&&${EDITOR:-nano} "$TXT" </dev/tty >/dev/tty 2>&1

# Audio
printf '\n=== Audio ===\n'
EWAV="";AFLT=""
if [[ $HASA -eq 1 ]];then
    # Optional enhancement (before Audacity)
    [[ $(ask "Auto-enhance (highpass 200Hz, denoise)? [y/N]:" n) =~ ^[Yy] ]]&&AFLT="highpass=f=200,afftdn=nr=12,alimiter=limit=0.95"
    
    # Audacity workflow
    if [[ $(ask "Audacity? [y/N]:" n) =~ ^[Yy] ]] && have audacity;then
        EWAV="${IN%.*}_audio.wav"
        printf 'Extracting to: %s\n' "$EWAV"
        # Apply enhancement before Audacity if selected
        if [[ -n "$AFLT" ]];then
            $FFMPEG -ss "$S" -t "$D" -i "$IN" -af "$AFLT" "$EWAV" 2>/dev/null
            printf 'Pre-enhanced with: %s\n' "$AFLT"
        else
            $FFMPEG -ss "$S" -t "$D" -i "$IN" "$EWAV" 2>/dev/null
        fi
        printf '\n=== AUDACITY ===\n'
        printf 'Export to: %s\n' "$EWAV"
        printf 'Format: WAV (Microsoft) 16-bit PCM\n'
        printf 'Leave Audacity open, return here when done\n\n'
        setsid audacity "$EWAV" </dev/null >/dev/null 2>&1 &
        disown
        sleep 1  # Give Audacity time to start
        read -p "Press Enter when exported..." </dev/tty
        [[ ! -s "$EWAV" ]]&&{ printf 'WAV missing/empty, skipping\n';EWAV="";}
    fi
fi

# Build filters
printf '\n=== Encoding ===\n'
FOUT_ST=$(awk -v d="$D" -v f="$FOUT" 'BEGIN{printf "%.3f",d-f}')
PRE="";[[ -n "$VFROT" ]]&&PRE="${VFROT},";[[ -n "$VFCROP" ]]&&PRE="${PRE}${VFCROP},"

# Text starts 2s before video
VFP="${PRE}setpts=PTS-STARTPTS,scale=$W:$H:force_original_aspect_ratio=decrease,pad=$W:$H:(ow-iw)/2:(oh-ih)/2:0x$FADE"
VFP="${VFP},drawtext=fontfile=$(esc "$FONT_FILE"):textfile=$(esc "$TXT"):fontsize=$FSIZE:fontcolor=0x$FONT:line_spacing=$LSPC:shadowcolor=0x45555e@0.8:shadowx=5:shadowy=6:x=(w-text_w)/2+20:y=h+20-($SPD*(t+2))"
VFP="${VFP},fade=t=in:st=0:d=$FIN:color=0x$FADE,fade=t=out:st=$FOUT_ST:d=$FOUT:color=0x$FADE"

# Thumbnail only mode
[[ $THUMB_ONLY -eq 1 ]]&&{ gen_thumb;exit 0;}

# External audio takes precedence
printf 'Output: %s\n' "$OUT"
if [[ -n "$EWAV" ]];then
    $FFMPEG -ss "$S" -t "$D" -i "$IN" -i "$EWAV" -map 0:v -map 1:a "${META[@]}" -vf "$VFP" -c:v libx264 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT"
else
    $FFMPEG -ss "$S" -t "$D" -i "$IN" -map 0:v -map 0:a "${META[@]}" -vf "$VFP" -c:v libx264 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart "$OUT"
fi

# Save config
[[ $(ask "Save settings? [y/N]:" n) =~ ^[Yy] ]]&&{
    mkdir -p "${CFG%/*}"
    printf 'RES=%s\nFIN=%s\nFOUT=%s\nFSIZE=%s\nLSPC=%s\nSPD=%s\nQUALITY=%s\n' "$RES" "$FIN" "$FOUT" "$FSIZE" "$LSPC" "$SPD" "$QUALITY" >"$CFG"
    printf 'Saved: %s\n' "$CFG"
}

# Cleanup
[[ -n "$EWAV" && -f "$EWAV" && ! $(ask "Keep WAV? [y/N]:" n) =~ ^[Yy] ]]&&rm -f "$EWAV"

printf '\n=== Done ===\n%s | %s | %ss\n' "$(du -h "$OUT"|cut -f1)" "$OUT" "$D"
[[ $(ask "Thumbnail? [y/N]:" n) =~ ^[Yy] ]]&&gen_thumb
[[ $(ask "Play? [y/N]:" n) =~ ^[Yy] ]]&&have mpv&&mpv "$OUT" 2>/dev/null||true

