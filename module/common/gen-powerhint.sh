#!/system/bin/sh
# ---------------------------------------------------------------------------
# libperfmgr-hyperos - gerador de powerhint.json adaptado ao dispositivo
#
# Constroi um ficheiro de hints valido para o libperfmgr usando APENAS nos
# que realmente existem e sao gravaveis neste kernel/ROM.
#
# Regras importantes deduzidas do HintManager.cc (AOSP):
#   * "Nodes" vazio    -> HintManager devolve nullptr -> o servico morre (FATAL)
#   * "Actions" vazio  -> idem
#   * valores duplicados dentro de um no -> falha o parse
#   * uma Action tem de referenciar um no existente e um valor desse no
#   * (hint, no) nao pode repetir-se
# Por isso este gerador garante sempre pelo menos 1 no e 1 acao.
#
# uso: sh gen-powerhint.sh <ficheiro_saida> [adpf-config.json]
# ---------------------------------------------------------------------------

OUT=${1:-/data/adb/libperfmgr/powerhint.json}
ADPF=${2:-/data/adb/modules/libperfmgr-hyperos/common/adpf-config.json}

# Perfil equilibrado para a composicao do HyperOS (incluindo Blur):
# um pulso curto na GPU evita que a primeira frame do desfoque seja perdida,
# sem forcar a frequencia maxima ou criar um piso em repouso.
# Os valores podem ser sobrepostos apenas durante a geracao, por exemplo:
# PERFMGR_GPU_BLUR_MS=32 sh gen-powerhint.sh ...
GPU_LAUNCH_MS=${PERFMGR_GPU_LAUNCH_MS:-450}
GPU_INTERACTION_MS=${PERFMGR_GPU_INTERACTION_MS:-120}
GPU_BLUR_MS=${PERFMGR_GPU_BLUR_MS:-48}
CPU_LAUNCH_MS=${PERFMGR_CPU_LAUNCH_MS:-1200}
CPU_INTERACTION_MS=${PERFMGR_CPU_INTERACTION_MS:-250}

# bases sobrepostas nos testes. GPU_BASE, quando definido, e um diretorio
# devfreq/Mali ja identificado; nos aparelhos a autodeteccao continua igual.
CPU_BASE=${CPU_BASE:-/sys/devices/system/cpu}
STUNE_BASE=${STUNE_BASE:-/dev/stune}
GPU_BASE=${GPU_BASE:-}

TMPD=$(mktemp -d 2>/dev/null)
[ -n "$TMPD" ] || TMPD=/data/local/tmp/perfmgr-gen.$$
mkdir -p "$TMPD" 2>/dev/null
NODE_F=$TMPD/nodes
ACT_F=$TMPD/actions
: >"$NODE_F"
: >"$ACT_F"

# ------------------------------- utilitarios --------------------------------
dedupe() {
    # remove repetidos e espacos a mais (valores duplicados quebram o parse do HintManager)
    echo "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ *$//'
}

jarr() {
    # transforma "a b c" em ["a","b","c"]
    printf '['
    first=1
    for v in $1; do
        if [ $first -eq 1 ]; then first=0; else printf ','; fi
        printf '"%s"' "$v"
    done
    printf ']'
}

writable() {
    # 0 se o ficheiro existe e o dono (root) tem permissao de escrita
    [ -e "$1" ] || return 1
    m=$(stat -c %a "$1" 2>/dev/null) || return 1
    m=$(printf '%03d' "$m" 2>/dev/null)
    case "${m%??}" in
    2 | 3 | 6 | 7) return 0 ;;
    *) return 1 ;;
    esac
}

add_node() {
    # $1 nome | $2 caminho | $3 valores (json array) | $4 extras (json, comeca por ',')
    grep -q "\"Name\": \"$1\"" "$NODE_F" 2>/dev/null && return 0
    printf '    {"Name": "%s", "Path": "%s", "Values": %s%s}\n' "$1" "$2" "$3" "$4" >>"$NODE_F"
}

add_action() {
    # $1 hint | $2 no | $3 valor | $4 duracao (ms)
    printf '    {"PowerHint": "%s", "Node": "%s", "Value": "%s", "Duration": %s}\n' \
        "$1" "$2" "$3" "$4" >>"$ACT_F"
}

max_ladder() {
    # valores descendentes para scaling_max_freq
    avail=$(cat "$1/scaling_available_frequencies" 2>/dev/null)
    max=$(cat "$1/cpuinfo_max_freq" 2>/dev/null)
    min=$(cat "$1/cpuinfo_min_freq" 2>/dev/null)
    if [ -n "$avail" ]; then
        echo "$avail" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -rn | awk 'NR==1 || (NR%2==1 && NR<=5)' | head -4
    else
        awk -v a="${max:-2000000}" -v b="${min:-500000}" 'BEGIN{
            print a
            split(sprintf("%d %d %d", int(a*0.85/1000)*1000, int(a*0.70/1000)*1000, int(a*0.55/1000)*1000), v, " ")
            for (i=1;i<=3;i++) if (v[i] > b) print v[i]
        }'
    fi
}

min_ladder() {
    # valores ascendentes para scaling_min_freq (0 = sem boost)
    avail=$(cat "$1/scaling_available_frequencies" 2>/dev/null)
    max=$(cat "$1/cpuinfo_max_freq" 2>/dev/null)
    min=$(cat "$1/cpuinfo_min_freq" 2>/dev/null)
    if [ -n "$avail" ]; then
        echo "$avail" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk 'NR==1 || (NR%2==1 && NR<=5)' | head -4
    else
        awk -v a="${max:-2000000}" -v b="${min:-500000}" 'BEGIN{
            print b
            split(sprintf("%d %d %d", int(a*0.45/1000)*1000, int(a*0.65/1000)*1000, int(a*0.85/1000)*1000), v, " ")
            for (i=1;i<=3;i++) if (v[i] > b && v[i] < a) print v[i]
        }'
    fi
}

# --------------------------- detecao: clusters CPU --------------------------
detect_cpu() {
    for pol in "$CPU_BASE"/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        idx=${pol##*/policy}
        case "$idx" in
        '' | *[!0-9]*) idx=0 ;;
        esac

        fmax=$pol/scaling_max_freq
        fmin=$pol/scaling_min_freq

        if writable "$fmax"; then
            vals=$(dedupe "$(max_ladder "$pol" | tr '\n' ' ')")
            [ -n "$vals" ] && add_node "CPUPolicy${idx}MaxFreq" "$fmax" \
                "$(jarr "$vals")" ', "DefaultIndex": 0, "ResetOnInit": true, "WriteOnly": true'
        fi

        if writable "$fmin"; then
            vals=$(dedupe "$(min_ladder "$pol" | tr '\n' ' ')")
            [ -n "$vals" ] && {
                add_node "CPUPolicy${idx}MinFreq" "$fmin" \
                    "$(jarr "$vals")" ', "DefaultIndex": 0, "ResetOnInit": true, "WriteOnly": true'
                # boost de arranque/interacao: 3.o valor da escada (se existir)
                boost=$(echo "$vals" | tr ' ' '\n' | grep -E '^[0-9]+$' | sed -n '3p')
                [ -n "$boost" ] || boost=$(echo "$vals" | tr ' ' '\n' | grep -E '^[0-9]+$' | tail -n 1)
                CPU_BOOST_NODES="$CPU_BOOST_NODES CPUPolicy${idx}MinFreq=$boost"
            }
        fi
    done
}

# ------------------------------- detecao: GPU -------------------------------
detect_gpu() {
    GPU_DIR=""
    # Uma base explicita e util para testes e kernels que exponham um alias
    # incomum. Nunca e definida pela instalacao normal.
    if [ -n "$GPU_BASE" ] && [ -d "$GPU_BASE" ]; then
        GPU_DIR=$GPU_BASE
    fi
    # Adreno (Qualcomm)
    if [ -z "$GPU_DIR" ]; then
        for d in /sys/class/kgsl/kgsl-3d0; do
            [ -d "$d/devfreq" ] && GPU_DIR=$d/devfreq && break
        done
    fi
    # Mali / genérico devfreq
    if [ -z "$GPU_DIR" ]; then
        for d in /sys/class/devfreq/*; do
            [ -d "$d" ] || continue
            case "$d" in *gpu* | *kgsl* | *mali*)
                if [ -f "$d/min_freq" ] || [ -f "$d/max_freq" ]; then GPU_DIR=$d && break; fi
                ;;
            esac
        done
    fi
    # Mali com nos "hint_"
    [ -z "$GPU_DIR" ] && for d in /sys/devices/platform/*.mali*; do
        if [ -f "$d/hint_min_freq" ] || [ -f "$d/hint_max_freq" ]; then GPU_DIR=$d && break; fi
    done

    [ -n "$GPU_DIR" ] || return 0

    gmin=$GPU_DIR/min_freq
    gmax=$GPU_DIR/max_freq
    [ -f "$gmin" ] || gmin=$GPU_DIR/hint_min_freq
    [ -f "$gmax" ] || gmax=$GPU_DIR/hint_max_freq

    if writable "$gmin"; then
        avail=$(cat "$GPU_DIR/available_frequencies" 2>/dev/null)
        if [ -n "$avail" ]; then
            # O topo e removido antes da amostragem: um efeito Blur nao deve
            # pedir OPP maximo. Se so existir o OPP maximo, nao criamos hint
            # de GPU e deixamos o governor fazer a escolha segura.
            all=$(echo "$avail" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n)
            top=$(echo "$all" | tail -n 1)
            vals=$(echo "$all" | awk -v top="$top" '$1 < top' | awk 'NR==1 || (NR%2==1 && NR<=5)' | head -4 | tr '\n' ' ')
        else
            # Sem uma tabela nao ha como distinguir OPP intermediario do
            # maximo. Conservamos apenas o minimo atual, se for menor que max.
            cur=$(cat "$gmin" 2>/dev/null)
            hi=$(cat "$gmax" 2>/dev/null)
            case "$cur:$hi" in
            *[!0-9:]* | :* | *:) vals="" ;;
            *) [ "$cur" -lt "$hi" ] && vals=$cur || vals="" ;;
            esac
        fi
        vals=$(dedupe "$vals")
        [ -n "$vals" ] && {
            add_node "GPUMinFreq" "$gmin" "$(jarr "$vals")" \
                ', "DefaultIndex": 0, "ResetOnInit": true, "WriteOnly": true'
            # Dois degraus: abertura usa o primeiro patamar acima do idle;
            # Blur/interacao usa o seguinte por poucos milissegundos. Isto
            # evita fixar a GPU no maximo, que e o maior custo de bateria.
            GPU_BOOST=$(echo "$vals" | tr ' ' '\n' | grep -E '^[0-9]+$' | sed -n '2p')
            # Um unico valor seguro ja e o idle; nesse caso nao ha boost.
            # Com dois ou mais, o segundo e um degrau intermediario valido.
            if [ -n "$GPU_BOOST" ]; then
                GPU_BLUR_BOOST=$(echo "$vals" | tr ' ' '\n' | grep -E '^[0-9]+$' | sed -n '3p')
                [ -n "$GPU_BLUR_BOOST" ] || GPU_BLUR_BOOST=$GPU_BOOST
            fi
        }
    fi
    # GpuSysfsPath e usado pelo GpuCapacityNode (ADPF GPU boost) e so faz sentido
    # no layout Mali ("hint_min_freq"); em Adreno deixamos vazio e o ADPF ignora o boost de GPU
    case "$gmin" in
    *hint_min_freq) GPU_SYSFS_DIR=$GPU_DIR ;;
    *) GPU_SYSFS_DIR="" ;;
    esac
}

# --------------------------- detecao: schedtune -----------------------------
detect_stune() {
    for g in top-app foreground; do
        f=$STUNE_BASE/$g/schedtune.boost
        if writable "$f"; then
            add_node "StuneBoost" "$f" '["0","10","20","30","50"]' \
                ', "DefaultIndex": 0, "ResetOnInit": true' 
            STUNE_NODE=StuneBoost
            return 0
        fi
    done
    STUNE_NODE=""
}

# --------------------------------- acoes ------------------------------------
build_actions() {
    if [ -n "$CPU_BOOST_NODES" ]; then
        first_node=""
        first_val=""
        for pair in $CPU_BOOST_NODES; do
            node=${pair%%=*}
            val=${pair##*=}
            if [ -n "$val" ]; then
                # Mantem o boost de abertura separado do pulso de frame.
                # O valor e moderado e expira, logo nao cria um piso de CPU.
                add_action LAUNCH "$node" "$val" "$CPU_LAUNCH_MS"
                [ -z "$first_node" ] && { first_node="$node"; first_val="$val"; }
            fi
        done
        # O toque precisa apenas do cluster eficiente: deixar os restantes
        # clusters livres evita gasto desnecessario em scroll e transicoes.
        if [ -n "$first_node" ] && [ -n "$first_val" ]; then
            add_action INTERACTION "$first_node" "$first_val" "$CPU_INTERACTION_MS"
        fi
    fi

    # O Blur do HyperOS e uma carga curta de composicao. DISPLAY_UPDATE_IMMINENT
    # e enviado junto da proxima atualizacao do SurfaceFlinger, por isso o pulso
    # abaixo aquece a GPU para a primeira frame sem pedir frequencia maxima.
    if [ -n "$GPU_BOOST" ]; then
        add_action LAUNCH GPUMinFreq "$GPU_BOOST" "$GPU_LAUNCH_MS"
    fi
    if [ -n "$GPU_BLUR_BOOST" ]; then
        add_action INTERACTION GPUMinFreq "$GPU_BLUR_BOOST" "$GPU_INTERACTION_MS"
        add_action DISPLAY_UPDATE_IMMINENT GPUMinFreq "$GPU_BLUR_BOOST" "$GPU_BLUR_MS"
    fi

    [ -n "$STUNE_NODE" ] && {
        add_action LAUNCH "$STUNE_NODE" 50 "$CPU_LAUNCH_MS"
        add_action INTERACTION "$STUNE_NODE" 30 "$CPU_INTERACTION_MS"
    }

    # garantir pelo menos uma acao
    if [ ! -s "$ACT_F" ]; then
        add_action LAUNCH PerfMgrNoOp 1 1
    fi
}

# ---------------------------- no de recurso (fallback) ----------------------
add_fallback_node() {
    # usado quando o kernel nao expoe nenhum no aproveitavel:
    # um no do tipo "Property" e sempre valido para o HintManager
    add_node "PerfMgrNoOp" "vendor.perfmgr.noop" '["0","1"]' \
        ', "Type": "Property", "DefaultIndex": 0' 
}

# ---------------------------------- main ------------------------------------
CPU_BOOST_NODES=""
GPU_BOOST=""
GPU_BLUR_BOOST=""
GPU_SYSFS_DIR=""
STUNE_NODE=""

detect_cpu
detect_gpu
detect_stune

if [ ! -s "$NODE_F" ]; then
    add_fallback_node
fi
build_actions

# nunca devolve vazio: se algo falhou, usa um conjunto minimo garantido
[ -s "$NODE_F" ] || add_node "PerfMgrNoOp" "vendor.perfmgr.noop" '["0","1"]' ', "Type": "Property", "DefaultIndex": 0' 
[ -s "$ACT_F" ] || add_action LAUNCH PerfMgrNoOp 1 1

mkdir -p "$(dirname "$OUT")" 2>/dev/null
{
    printf '{\n'
    printf '  "Nodes": [\n'
    awk '{ printf "%s%s", sep, $0; sep=",\n" } END { if (NR) printf "\n" }' "$NODE_F"
    printf '  ],\n'
    printf '  "Actions": [\n'
    awk '{ printf "%s%s", sep, $0; sep=",\n" } END { if (NR) printf "\n" }' "$ACT_F"
    printf '  ]'
    # So ha uma virgula se outro campo vier a seguir. Sem o ADPF (por
    # exemplo, em regeneracao manual incompleta), o ficheiro continua JSON
    # valido e o HAL pode usar os Nodes/Actions seguros.
    if [ -n "$GPU_SYSFS_DIR" ] || [ -f "$ADPF" ]; then
        printf ','
    fi
    printf '\n'
    if [ -n "$GPU_SYSFS_DIR" ]; then
        printf '  "GpuSysfsPath": "%s"' "$GPU_SYSFS_DIR"
        [ -f "$ADPF" ] && printf ','
        printf '\n'
    fi
    if [ -f "$ADPF" ]; then
        printf '  "AdpfConfig": '
        cat "$ADPF"
    fi
    printf '}\n'
} >"$OUT"

# validacao minima
if ! grep -q '"Nodes"' "$OUT" 2>/dev/null || ! grep -q '"Actions"' "$OUT" 2>/dev/null; then
    printf '{\n  "Nodes": [\n    {"Name": "PerfMgrNoOp", "Path": "vendor.perfmgr.noop", "Values": ["0","1"], "Type": "Property", "DefaultIndex": 0}\n  ],\n  "Actions": [\n    {"PowerHint": "LAUNCH", "Node": "PerfMgrNoOp", "Value": "1", "Duration": 1}\n  ]\n}\n' >"$OUT"
fi

rm -rf "$TMPD" 2>/dev/null
exit 0
