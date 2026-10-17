#!/bin/sh
# Build the Commander X16 port of Marble Madness.
#
#   ./build.sh            assemble and link MARBLE.PRG from the sources here
#   ./build.sh --regen    first regenerate bank0-3.s, stubs.s, tables.inc and
#                         MMDATA.BIN from the NES ROM (overwrites hand edits!)
#
# Regeneration converts branches that the relocation pushed out of range into
# long branches automatically (recorded in long_branches.txt).
# Extra assembler options (debug builds, see README.md) come from $X16_DEFS.
# Needs ca65/ld65 (cc65) on PATH and python3; regeneration needs the ROM.
set -e
cd "$(dirname "$0")"
ROM="../Marble Madness (USA).nes"
mkdir -p obj

assemble_banks() {
    for b in 0 1 2 3; do
        ca65 --cpu 65C02 -U $X16_DEFS -o obj/bank$b.o bank$b.s
    done
}

if [ "$1" = "--regen" ] || [ ! -f bank0.s ] || [ ! -f MMDATA.BIN ]; then
    touch long_branches.txt
    while :; do
        python3 ../tools/emit_x16.py "$ROM" .
        fixed=0
        for b in 0 1 2 3; do
            if ! ca65 --cpu 65C02 -U $X16_DEFS -o obj/bank$b.o bank$b.s 2> obj/err.txt; then
                if grep -q "Range error" obj/err.txt; then
                    for ln in $(grep "Range error" obj/err.txt | sed 's/^[^:]*:\([0-9]*\):.*/\1/'); do
                        addr=$(sed -n "${ln}p" bank$b.s | sed 's/.*; \([0-9A-F]\{4\}\).*/\1/')
                        echo "$b $addr" >> long_branches.txt
                    done
                    fixed=1
                else
                    cat obj/err.txt; exit 1
                fi
            fi
        done
        [ $fixed = 0 ] && break
        echo "converted out-of-range branches, regenerating"
    done
else
    assemble_banks
fi
ca65 --cpu 65C02 -U $X16_DEFS -o obj/stubs.o stubs.s
ca65 --cpu 65C02 -U -g $X16_DEFS -o obj/runtime.o runtime.s
ld65 -C x16.cfg -m obj/marble.map -Ln obj/marble.lbl -o MARBLE.PRG \
    obj/runtime.o obj/bank0.o obj/bank1.o obj/bank2.o obj/bank3.o obj/stubs.o
echo "built MARBLE.PRG ($(wc -c < MARBLE.PRG) bytes); data file MMDATA.BIN"
