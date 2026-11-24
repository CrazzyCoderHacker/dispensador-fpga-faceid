#!/usr/bin/env bash
# Corre todas las pruebas con Icarus Verilog. Uso (Git Bash):  bash sim/run_all.sh
set -u
cd "$(dirname "$0")/.."
export PATH="/c/ProgramData/chocolatey/bin:$PATH"
mkdir -p sim/build
TESTS="tb_divu tb_bolus_limiter tb_infusion_ctrl tb_system"
status=0
for t in $TESTS; do
  iverilog -g2005 -o sim/build/$t.vvp -s $t sim/$t.v sim/altsource_probe_stub.v rtl/*.v || { echo "$t: ERROR DE COMPILACION"; status=1; continue; }
  (cd sim/build && vvp -n $t.vvp > $t.log 2>&1)
  r=$(grep "RESULT" sim/build/$t.log || echo "$t RESULT: sin resultado (revisar sim/build/$t.log)")
  echo "$r"
  echo "$r" | grep -q "FAIL 0" || status=1
done
[ $status -eq 0 ] && echo "TODAS LAS PRUEBAS PASARON" || echo "HAY PRUEBAS FALLIDAS"
exit $status
