# Web client: a page of any #displayN (N >= 2), not only #display2. See README, "One app per screen".
s/L=fn\(\)\.startsWith\(`#display2`\)\?`display2`:`primary`/L=(fn().match(\/^#(display[0-9]+)\/)||[])[1]||`primary`/
s/me=Dt\.startsWith\(`#display2`\)\?`display2`:`primary`/me=(Dt.match(\/^#(display[0-9]+)\/)||[])[1]||`primary`/
s/\/\^#display2-\(right\|left\|up\|down\)\//\/^#display[0-9]+-(right|left|up|down)\//
s/ur\.startsWith\(`#display2`\)\)\{j=`display2`;/\/^#display[0-9]+\/.test(ur)){j=ur.match(\/^#(display[0-9]+)\/)[1];/
s/Ho=Pe\(\)\.startsWith\(`#display2`\)\?`display2`:`primary`/Ho=(Pe().match(\/^#(display[0-9]+)\/)||[])[1]||`primary`/
s/\.startsWith\(`#display2`\)/.startsWith(`#display`)/g
s/\b(L|j|me|Ho)===`display2`/\1!==`primary`/g
s/\b(L|j|me|Ho)!==`display2`/\1===`primary`/g
s/o\.endsWith\(`_display2`\)/o.endsWith(`_${L}`)/
s/s=o\.slice\(0,-9\)/s=o.slice(0,-L.length-1)/
s/\$\{t\}_display2/${t}_${Ho}/
s/r\.displays\.includes\(`display2`\)/r.displays.some(e=>e!==`primary`)/
