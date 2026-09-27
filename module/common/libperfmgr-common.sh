#!/system/bin/sh
# ---------------------------------------------------------------------------
# libperfmgr-hyperos - funcoes partilhadas por todos os scripts do modulo
# Corre sob o ash do BusyBox (KernelSU / KernelSU Next / Magisk / APatch).
# ---------------------------------------------------------------------------

MODID=libperfmgr-hyperos
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"

PERSIST=/data/adb/libperfmgr
LOGDIR=$PERSIST/logs
LOGFILE=$LOGDIR/perfmgr.log
CONF=$MODDIR/perfmgr.conf
CONF_USER=$PERSIST/perfmgr.conf
VARIANT_FILE=$MODDIR/.variant
USER_HINT=$PERSIST/powerhint.json
PIXEL_HINT=/vendor/etc/perfmgr/powerhint.pixel.json

VENDOR_HINT=/vendor/etc/powerhint.json
DEBUG_HINT_DIR=/data/vendor/etc
DEBUG_HINT=$DEBUG_HINT_DIR/powerhint.json

SVC=vendor.power-hal-aidl
HAL_BIN=/vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr
SENDHINT=/vendor/bin/sendhint

HAL_LIBS="/vendor/lib64/libperfmgr.so
/vendor/lib64/libdisppower-pixel.so
/vendor/lib64/pixel-power-ext-V1-ndk.so
/vendor/lib64/android.hardware.power-V6-ndk.so
/vendor/lib64/android.hardware.thermal-V1-ndk.so"

# contexto SELinux do dominio criado por sepolicy.rule
CTX_EXEC=u:object_r:perfmgr_hal_exec:s0
CTX_LIB=u:object_r:same_process_hal_file:s0
CTX_ETC=u:object_r:vendor_configs_file:s0

# ------------------------------- logging -----------------------------------
pm_log() {
    # uso: pm_log TAG mensagem...
    tag=$1
    shift
    mkdir -p "$LOGDIR" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$tag] $*" >>"$LOGFILE" 2>/dev/null
}

pm_log_rotate() {
    [ -f "$LOGFILE" ] || return 0
    sz=$(stat -c %s "$LOGFILE" 2>/dev/null)
    [ -n "$sz" ] || return 0
    if [ "$sz" -gt 524288 ]; then
        tail -n 300 "$LOGFILE" >"$LOGFILE.tmp" 2>/dev/null &&
            mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null
    fi
}

# ----------------------------- configuracao --------------------------------
pm_conf_file() {
    # a configuracao do utilizador (persistente entre atualizacoes) tem prioridade
    if [ -f "$CONF_USER" ]; then
        echo "$CONF_USER"
    else
        echo "$CONF"
    fi
}

pm_conf_get() {
    # uso: pm_conf_get CHAVE [predefinicao]
    key=$1
    def=${2:-}
    for f in "$CONF_USER" "$CONF"; do
        [ -f "$f" ] || continue
        val=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$f" 2>/dev/null | tail -n 1)
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    done
    echo "$def"
}

pm_conf_set() {
    # uso: pm_conf_set CHAVE valor (escreve sempre na copia persistente)
    key=$1
    val=$2
    mkdir -p "$PERSIST" 2>/dev/null
    [ -f "$CONF_USER" ] || {
        # primeira utilizacao: herda os valores do modulo
        [ -f "$CONF" ] && cat "$CONF" >"$CONF_USER" 2>/dev/null
        printf '# configuracao do modulo libperfmgr-hyperos\n' >>"$CONF_USER" 2>/dev/null
    }
    if grep -q "^[[:space:]]*$key[[:space:]]*=" "$CONF_USER" 2>/dev/null; then
        sed -i "s|^[[:space:]]*$key[[:space:]]*=.*|$key=$val|" "$CONF_USER" 2>/dev/null
    else
        echo "$key=$val" >>"$CONF_USER"
    fi
}

pm_override_allowed() {
    # OVERRIDE_STOCK sozinho pode vir de configuracoes antigas. Exigir a chave
    # de confirmacao torna uma atualizacao segura sem reativar uma troca de HAL
    # que o utilizador nao confirmou nesta versao.
    [ "$(pm_conf_get OVERRIDE_STOCK 0)" = "1" ] && \
        [ "$(pm_conf_get ALLOW_STOCK_OVERRIDE 0)" = "1" ]
}

pm_override_manifest_on() {
    # O instalador remove o manifesto em modo seguro. Quando o utilizador faz
    # opt-in, restaura a copia da variante selecionada para o init poder subir
    # o HAL apenas no proximo boot — nunca durante uma composicao em curso.
    src="$MODDIR/.backup_vintf/manifest/android.hardware.power-service.pixel.xml"
    dst="$MODDIR/system/vendor/etc/vintf/manifest/android.hardware.power-service.pixel.xml"
    [ -f "$src" ] || return 1
    mkdir -p "${dst%/*}" 2>/dev/null || return 1
    cp "$src" "$dst" 2>/dev/null || return 1
    sed -i 's|<hal format="aidl">|<hal format="aidl" override="true">|' "$dst" 2>/dev/null
}

pm_override_manifest_off() {
    # O diretorio e exclusivo do modulo; removê-lo devolve o manifesto stock
    # no boot seguinte, sem tocar na particao /vendor real.
    rm -rf "$MODDIR/system/vendor/etc/vintf" 2>/dev/null
}

# ------------------------- deteccao do dispositivo -------------------------
pm_soc() {
    # devolve: qcom | mtk | unisoc | exynos | unknown
    v=$(echo "$(getprop ro.board.platform) $(getprop ro.hardware) $(getprop ro.hardware.chipset) $(getprop ro.soc.model)" | tr 'A-Z' 'a-z')
    case "$v" in
    *mtk* | *mediatek* | *mt6[5-9]* | *mt8*) echo mtk ;;
    *qcom* | *msm* | *sdm* | *sm[4-9][0-9]* | *bengal* | *trinket* | *atoll* | *lito* | *kona* | *lahaina* | *shima* | *taro* | *kalama* | *pineapple* | *cliffs* | *volcano*) echo qcom ;;
    *unisoc* | *ums* | *spreadtrum* | *sc98* | *ud710*) echo unisoc ;;
    *exynos*) echo exynos ;;
    *)
        # fallback: sinais indirectos quando o nome da plataforma nao ajuda
        if [ -f /vendor/bin/hw/vendor.qti.hardware.perf-hal-service ] ||
            [ "$(getprop ro.hardware.vulkan)" = "adreno" ]; then
            echo qcom
        elif [ -f /vendor/bin/hw/vendor.mediatek.hardware.mtkpower-service.mediatek ]; then
            echo mtk
        else
            echo unknown
        fi
        ;;
    esac
}

pm_device() {
    echo "$(getprop ro.product.manufacturer) $(getprop ro.product.model) ($(getprop ro.product.device))"
}

pm_android() {
    echo "Android $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
}

# --------------------- variante de binarios por Android ---------------------
pm_variant() {
    # api34 = Pixel 5 (Snapdragon 765G / ARMv8.0) - max compatibilidade Qualcomm
    # api35 = Android 15 (power AIDL V5) | api36 = Android 16+ (power AIDL V6)
    #
    # 1) escolha manual (FORCE_VARIANT=api34|api35|api36 em perfmgr.conf)
    forced=$(pm_conf_get FORCE_VARIANT "")
    case "$forced" in
    api34 | api35 | api36)
        echo "$forced"
        return 0
        ;;
    esac
    # 2) Verificacao de CPU: Se a CPU nao tiver LSE atomics (ex: Snapdragon 685 / Cortex-A73),
    # usamos obrigatoriamente a variante api34 (Pixel 5 Qualcomm) para evitar Illegal Instruction!
    if ! grep -qi "lse" /proc/cpuinfo 2>/dev/null; then
        echo "api34"
        return 0
    fi
    # 2) versao AIDL presente no lado cliente (system) e no vendor
    if [ -f "$VARIANT_FILE" ]; then
        cached=$(cat "$VARIANT_FILE" 2>/dev/null)
        case "$cached" in
        api35 | api36)
            echo "$cached"
            return 0
            ;;
        esac
    fi
    v=0
    for n in 7 6 5 4 3; do
        if [ -f "/system/lib64/android.hardware.power-V$n-ndk.so" ] ||
            [ -f "/vendor/lib64/android.hardware.power-V$n-ndk.so" ] ||
            [ -f "/system/system/lib64/android.hardware.power-V$n-ndk.so" ]; then
            v=$n
            break
        fi
    done
    if [ "$v" -ge 6 ]; then echo api36; return 0; fi
    if [ "$v" -eq 5 ]; then echo api35; return 0; fi
    # 3) fallback pelo SDK (system)
    sdk=$(getprop ro.build.version.sdk)
    if [ -n "$sdk" ] && [ "$sdk" -ge 36 ]; then echo api36; else echo api35; fi
}

pm_adpf_file() {
    v=$(pm_variant)
    if [ -f "$MODDIR/common/adpf-config-$v.json" ]; then
        echo "$MODDIR/common/adpf-config-$v.json"
    else
        echo "$MODDIR/common/adpf-config-api36.json"
    fi
}

# --------------------- HAL android.hardware.power de fabrica ----------------
pm_stock_hal() {
    # caminho do HAL de fabrica, se existir (Qualcomm/CAF costuma ter um)
    for f in /vendor/bin/hw/android.hardware.power-service*; do
        case "$f" in
        *pixel-libperfmgr* | *\*) continue ;;
        esac
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

pm_stock_svc() {
    # nome do servico init que arranca o HAL de fabrica (ex.: vendor.power)
    for rc in /vendor/etc/init/*.rc /vendor/etc/init/hw/*.rc /vendor/etc/init/*/*.rc; do
        [ -f "$rc" ] || continue
        awk '$1 == "service" {
                cmd = $3
                if (cmd ~ /android\.hardware\.power-service/ && cmd !~ /pixel-libperfmgr/) { print $2; exit }
             }' "$rc" 2>/dev/null
    done | head -n 1
}

pm_stop_stock_hal() {
    # usado em modo OVERRIDE: liberta o nome android.hardware.power.IPower/default
    s=$(pm_stock_svc)
    [ -n "$s" ] && {
        setprop ctl.stop "$s" 2>/dev/null
        pm_log HAL "servico de fabrica '$s' parado"
    }
    h=$(pm_stock_hal)
    [ -n "$h" ] && pkill -f "$(basename "$h")" 2>/dev/null
    sleep 1
    return 0
}

# ------------------------------- SELinux -----------------------------------
pm_chcon() {
    # uso: pm_chcon <ficheiro> <contexto>
    [ -e "$1" ] || return 1
    chcon "$2" "$1" 2>/dev/null && return 0
    chcon -h "$2" "$1" 2>/dev/null && return 0
    return 1
}

pm_label_files() {
    chcon u:object_r:perfmgr_hal_exec:s0 "$HAL_BIN" 2>/dev/null
    chcon u:object_r:perfmgr_hal_exec:s0 "${HAL_BIN}.bin" 2>/dev/null
    chcon u:object_r:vendor_file:s0 "$SENDHINT" 2>/dev/null
    chcon u:object_r:vendor_file:s0 "${SENDHINT}.bin" 2>/dev/null
    for lib in /vendor/lib64/libperfmgr*.so /vendor/lib64/*power*.so /vendor/lib64/libprotobuf*.so; do
        [ -f "$lib" ] && pm_chcon "$lib" "$CTX_LIB"
    done
    [ -f "$VENDOR_HINT" ] && pm_chcon "$VENDOR_HINT" "$CTX_ETC"
    pm_chcon /vendor/etc/perfmgr "$CTX_ETC" 2>/dev/null
    chmod 0755 "$HAL_BIN" "$SENDHINT" "${HAL_BIN}.bin" "${SENDHINT}.bin" 2>/dev/null
    chmod 0644 /vendor/lib64/libperfmgr*.so /vendor/lib64/*power*.so /vendor/lib64/libprotobuf*.so 2>/dev/null
    chmod 0644 "$VENDOR_HINT" 2>/dev/null
}

# ---------------------------- estado do servico ----------------------------
pm_svc_state() {
    getprop "init.svc.$SVC" 2>/dev/null
}

pm_hal_registered() {
    # 0 = servico AIDL registado no servicemanager
    out=$(service check android.hardware.power.IPower/default 2>/dev/null)
    case "$out" in *found*) return 0 ;; *) return 1 ;; esac
}

pm_status_line() {
    st=$(pm_svc_state)
    [ -n "$st" ] || st="nao-gerido-pelo-init"
    if pm_hal_registered; then reg="registado"; else reg="NAO registado"; fi
    echo "  init.svc.$SVC = $st"
    echo "  android.hardware.power.IPower/default = $reg"
    echo "  vendor.powerhal.init = $(getprop vendor.powerhal.init)"
    echo "  ENABLE_HAL = $(pm_conf_get ENABLE_HAL 1) | ENABLE_HINTS = $(pm_conf_get ENABLE_HINTS 0)"
}

# -------------------------- arranque / paragem -----------------------------
pm_wait_for_binary() {
    i=0
    while [ ! -x "$HAL_BIN" ] && [ $i -lt 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -x "$HAL_BIN" ]
}

pm_start_hal() {
    if pm_override_allowed; then
        pm_stop_stock_hal
    fi
    pm_log HAL "arranque do HAL"
    if command -v runcon >/dev/null 2>&1; then
        runcon u:r:perfmgr_hal:s0 "$HAL_BIN" >/dev/null 2>&1 &
    else
        "$HAL_BIN" >/dev/null 2>&1 &
    fi
}

pm_stop_hal() {
    setprop ctl.stop "$SVC" 2>/dev/null
    pkill -f android.hardware.power-service.pixel-libperfmgr 2>/dev/null
    setprop vendor.powerhal.init ""
    pm_log HAL "servico parado"
}

# --------------------------- ficheiro de hints -----------------------------
pm_sync_user_hint() {
    # Se o utilizador editou /data/adb/libperfmgr/powerhint.json, publica-o em
    # /data/vendor/etc e aponta o libperfmgr para la (vendor.powerhal.config.debug).
    mkdir -p "$DEBUG_HINT_DIR" 2>/dev/null
    if [ -f "$USER_HINT" ] && [ -d "$DEBUG_HINT_DIR" ]; then
        if ! cmp -s "$USER_HINT" "$DEBUG_HINT" 2>/dev/null; then
            cp "$USER_HINT" "$DEBUG_HINT" 2>/dev/null && chmod 0644 "$DEBUG_HINT"
            pm_chcon "$DEBUG_HINT" u:object_r:vendor_configs_file:s0 2>/dev/null
        fi
        if [ -f "$DEBUG_HINT" ]; then
            setprop vendor.powerhal.config.debug true
            pm_log HINTS "a usar configuracao do utilizador: $DEBUG_HINT"
        fi
    else
        setprop vendor.powerhal.config.debug false
    fi
}

pm_enable_hints() {
    # 1 = liga a escrita nos nos sysfs (HintManager); 0 = apenas ADPF/sessoes
    if [ "$1" = "1" ]; then
        pm_sync_user_hint
        setprop vendor.powerhal.init 1
        pm_log HINTS "ativas (vendor.powerhal.init=1)"
    else
        setprop vendor.powerhal.init ""
        pm_log HINTS "desativas (sem escrita em sysfs)"
    fi
}
