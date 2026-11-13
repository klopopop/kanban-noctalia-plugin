#!/usr/bin/env bash
# Рисует листок-стикер картинкой (в API 43 у ui.* нет поворота):
# бумага с лёгким градиентом, текст рукописным шрифтом, полупрозрачный скотч
# с рваными краями поверх верхней кромки, мягкая тень, поворот всего листка.
#
#   sticker.sh OUT TEXT PAPER ANGLE TAPE_ANGLE TAPE_SHIFT TAPE(0/1) FONT SCALE [FOOTER] [TAPE_COLOR] [FOOTER_COLOR]
#
# FOOTER — мелкая строка внизу листка (срок, метки); TAPE_COLOR — цвет скотча
# (#rrggbbaa; красный у просроченных).
#
# Текст передаётся аргументом и пишется в OUT.txt (caption:@файл — без
# интерпретации %-escape и @). Кеш старше 60 дней чистится тут же.
#
# Размеры — в логических пикселях × SCALE; холст фиксированный, чтобы
# повёрнутый листок всегда помещался в одну и ту же ячейку.
set -euo pipefail
out=$1 text=$2 paper=$3 angle=$4 tang=$5 tshift=$6 tape=$7 font=$8 k=$9
footer=${10:-} tapeColor=${11:-#F2EEE3CC} footColor=${12:-#22262F99}

dir=$(dirname "$out")
mkdir -p "$dir"
find "$dir" -maxdepth 1 -type f -mtime +60 -delete 2>/dev/null || true
txt="$out.txt"
printf '%s' "$text" > "$txt"

px() { awk -v v="$1" -v k="$k" 'BEGIN { printf "%d", v * k + 0.5 }'; }

PW=$(px 146) PH=$(px 136)     # бумага
CW=$(px 176) CH=$(px 172)     # холст ячейки
TW=$(px 60) TH=$(px 19)       # скотч
PAD=$(px 11) PS=$(px 17)
LIFT=$(( TH / 2 ))            # бумага ниже на полскотча — скотч заходит за край

if [[ "$tape" == 1 ]]; then textTop=$(( LIFT + TH / 2 + $(px 4) )); else textTop=$(( LIFT + PAD )); fi
textW=$(( PW - 2 * PAD ))
FS=$(px 12)
footH=0
[[ -n "$footer" ]] && footH=$(( FS + $(px 6) ))
textH=$(( LIFT + PH - PAD - textTop - footH ))

# Скотч: полоса с рваными (зубчатыми) торцами.
tapePoly() {
  awk -v w="$TW" -v h="$TH" -v k="$k" -v seed="$tshift$tang" 'BEGIN {
    srand(seed + 0); n = 6; s = h / n; pts = ""
    for (i = 0; i <= n; i++) pts = pts sprintf("%d,%d ", w - rand() * 3 * k, i * s)
    for (i = n; i >= 0; i--) pts = pts sprintf("%d,%d ", rand() * 3 * k, i * s)
    print pts
  }'
}

tapeLayer=()
if [[ "$tape" == 1 ]]; then
  tapeLayer=(
    \( -size "${TW}x${TH}" xc:none -fill "$tapeColor" -draw "polygon $(tapePoly)"
       -fill '#FFFFFF2E' -draw "rectangle 0,$(( TH / 4 )) ${TW},$(( TH / 3 ))"
       -background none -rotate "$tang" \)
    -gravity north -geometry "+${tshift}+0" -compose over -composite -gravity northwest
  )
fi

footLayer=()
if [[ -n "$footer" ]]; then
  printf '%s' "$footer" > "$out.foot.txt"
  footLayer=(
    \( +size -background none -fill "$footColor" -font "$font" -pointsize "$FS" label:@"$out.foot.txt"
       -crop "${textW}x$(( FS * 2 ))+0+0" +repage \)
    -geometry "+${PAD}+$(( LIFT + PH - PAD - FS - $(px 2) ))" -compose over -composite
  )
fi

magick \
  -size "${PW}x$(( PH + LIFT ))" xc:none \
  \( -size "${PW}x${PH}" xc:"$paper" \
     \( -size "${PW}x${PH}" gradient:'#FFFFFF24-#0000001C' \) -compose over -composite \
     \( -size "${PW}x$(px 10)" gradient:'#00000000-#00000014' \) -gravity south -compose over -composite -gravity northwest \) \
  -geometry "+0+${LIFT}" -compose over -composite \
  \( -size "${textW}x" -background none -fill '#22262F' -font "$font" -pointsize "$PS" \
     -interline-spacing "$(px 1)" caption:@"$txt" -crop "${textW}x${textH}+0+0" +repage \) \
  -geometry "+${PAD}+${textTop}" -compose over -composite \
  "${footLayer[@]}" \
  "${tapeLayer[@]}" \
  \( +clone -background '#000000' -shadow "55x$(px 3)+$(px 1)+$(px 4)" \) +swap \
  -background none -compose over -layers merge +repage \
  -background none -rotate "$angle" \
  -gravity center -background none -extent "${CW}x${CH}" \
  "$out.tmp.png"
mv -f "$out.tmp.png" "$out"
rm -f "$txt" "$out.foot.txt"
