#!/system/bin/sh
# ---------------------------------------------------------------------------
# libperfmgr-hyperos - script de instalacao (KernelSU / KernelSU Next /
# Magisk / APatch). Corre no ash do BusyBox, com o zip ja extraido.
# ---------------------------------------------------------------------------

MODDIR=$MODPATH
. "$MODPATH/common/libperfmgr-common.sh"

command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$*"; }
command -v abort >/dev/null 2>&1 || abort() {
    echo "ERRO: $*"
    exit 1
}

ui_print " "
ui_print "  libperfmgr para HyperOS"
ui_print " "

# ------------------------------ 1. verificacoes ----------------------------
ABI=$(getprop ro.product.cpu.abi)
ABILIST=$(getprop ro.product.cpu.abilist)
SDK=$(getprop ro.build.version.sdk)

case "$ABILIST$ABI" in
*arm64-v8a*) ;;
*)
    abort "arquitetura nao suportada ($ABI). Este modulo apenas inclui binarios arm64."
    ;;
esac

if [ -z "$SDK" ] || [ "$SDK" -lt 33 ]; then
    ui_print "! Android $(getprop ro.build.version.release) detetado (SDK $SDK)"
    ui_print "! Este modulo foi pensado para Android 13+ (HyperOS 1/2/3/4)."
else
    ui_print "- $(pm_android)"
fi

ROOT="desconhecido"
[ "$KSU" = "true" ] && ROOT="KernelSU"
[ -n "$MAGISK_VER_CODE" ] && ROOT="Magisk $MAGISK_VER"
[ -n "$APATCH" ] && ROOT="APatch"
ui_print "- Root: $ROOT"
ui_print "- Dispositivo: $(pm_device)"
ui_print "- SoC: $(pm_soc)"

# metamodulo (necessario no KernelSU para montar a pasta system/)
NEED_META=0
if [ "$KSU" = "true" ]; then
    FOUND_META=0
    for m in /data/adb/modules/*/; do
        id=$(sed -n 's/^id=//p' "$m/module.prop" 2>/dev/null)
        case "$id" in
        *meta-overlayfs* | *meta-magic* | *magic_mount* | *hybrid_mount* | *mountify* | *overlayfs*)
            FOUND_META=1
            ui_print "- Metamodulo detetado: $id"
            ;;
        esac
    done
    if [ $FOUND_META -eq 0 ]; then
        NEED_META=1
        ui_print " "
        ui_print "!! AVISO: nenhum metamodulo de montagem detetado no KernelSU."
        ui_print "!! Sem meta-overlayfs a pasta system/ do modulo NAO e montada"
        ui_print "!! e os ficheiros nao aparecerao em /vendor."
        ui_print "!! Instale o meta-overlayfs e reinstale este modulo."
    fi
fi

# ------------------- 2. escolher a variante de binarios --------------------
VARIANT=$(pm_variant)

if [ ! -d "$MODPATH/prebuilt/$VARIANT" ]; then
    abort "variante $VARIANT em falta no zip (o build correu mal?)"
fi

case "$(pm_conf_get FORCE_VARIANT auto)" in
auto) ;;
*) ui_print "- Variante forcada por configuracao: $(pm_conf_get FORCE_VARIANT auto)" ;;
esac
desc="desconhecida"
[ "$VARIANT" = "api34" ] && desc="Pixel 5 Snapdragon (ARMv8.0 compativel)"
[ "$VARIANT" = "api35" ] && desc="Pixel Tensor A15 (power AIDL V5)"
[ "$VARIANT" = "api36" ] && desc="Pixel Tensor A16+ (power AIDL V6)"
ui_print "- Variante de binarios selecionada: $VARIANT ($desc)"

# Apaga todas as outras variantes que nao foram escolhidas
for v in api34 api35 api36; do
    if [ "$v" != "$VARIANT" ]; then
        rm -rf "$MODPATH/prebuilt/$v"
    fi
done
mkdir -p "$MODPATH/system/vendor"
cp -a "$MODPATH/prebuilt/$VARIANT/." "$MODPATH/system/vendor/" 2>/dev/null
# Guardamos o manifesto original para o caso de override posterior
mkdir -p "$MODPATH/.backup_vintf" 2>/dev/null
cp -a "$MODPATH/prebuilt/$VARIANT/etc/vintf/." "$MODPATH/.backup_vintf/" 2>/dev/null
rm -rf "$MODPATH/prebuilt"
echo "$VARIANT" >"$MODPATH/.variant" 2>/dev/null

# bibliotecas AIDL: so instalar se a ROM ja nao as tiver
trim_dep() {
    if [ -f "/system/lib64/$1" ] || [ -f "/vendor/lib64/$1" ] || [ -f "/system/system/lib64/$1" ]; then
        rm -f "$MODPATH/system/vendor/lib64/$1" 2>/dev/null
        ui_print "- Dependencia ja presente na ROM: $1 (nao e instalada)"
    fi
}
trim_dep android.hardware.power-V4-ndk.so
trim_dep android.hardware.power-V5-ndk.so
trim_dep android.hardware.power-V6-ndk.so
trim_dep android.hardware.thermal-V1-ndk.so
trim_dep android.hardware.common.fmq-V1-ndk.so
trim_dep android.frameworks.stats-V2-ndk.so
trim_dep libprotobuf-cpp-full-21.7.so
trim_dep libprotobuf-cpp-lite-21.7.so

# ------------------- 3. HAL de fabrica (conflito!) -------------------------
# Agora que o boot seguro foi comprovado e a espera de sys.boot_completed
# esta ativa no service.sh, mantemos a configuracao do usuario se ja existir!

STOCK=$(pm_stock_hal)
if [ -n "$STOCK" ]; then
    STOCK_SVC=$(pm_stock_svc)
    ui_print " "
    ui_print "- HAL android.hardware.power de fabrica detetado:"
    ui_print "    $(basename "$STOCK")  (servico init: ${STOCK_SVC:-desconhecido})"
    if pm_override_allowed; then
        # NUNCA usamos whiteout mknod no binario de fabrica porque o init
        # da crash no boot se o binario de um service de classe hal nao puder ser executado.
        # Em vez disso, deixamos o binario existir e paramos o servico via ctl.stop no runtime.
        chmod 0644 "$MODPATH/system/vendor/etc/vintf/manifest/android.hardware.power-service.pixel.xml" 2>/dev/null
        sed -i 's|<hal format="aidl">|<hal format="aidl" override="true">|' \
            "$MODPATH/system/vendor/etc/vintf/manifest/android.hardware.power-service.pixel.xml" 2>/dev/null
        ui_print "- OVERRIDE confirmado: o HAL de fabrica sera substituido pelo perfmgr no proximo boot"
    else
        pm_conf_set ENABLE_HAL 0
        # Em modo seguro, nao publicamos o manifesto VINTF em /vendor/etc/vintf
        # para evitar conflito com o manifesto do HAL de fabrica no arranque
        rm -rf "$MODPATH/system/vendor/etc/vintf" 2>/dev/null
        ui_print "- Modo seguro ativo: ENABLE_HAL=0 por padrao"
        ui_print "- Manifesto VINTF omitido (evita conflito com o HAL de fabrica)"
        ui_print "- Para ativar apos o boot funcionar: action.sh override on"
    fi
else
    ui_print "- Nenhum HAL android.hardware.power de fabrica: o perfmgr sera o unico"
fi

# ------------------------- 4. ficheiro de hints ----------------------------
mkdir -p "$PERSIST" 2>/dev/null
mkdir -p "$MODPATH/system/vendor/etc/perfmgr" 2>/dev/null

sh "$MODPATH/common/gen-powerhint.sh" "$MODPATH/system/vendor/etc/powerhint.json" "$(pm_adpf_file)"

if [ ! -f "$USER_HINT" ]; then
    cp "$MODPATH/system/vendor/etc/powerhint.json" "$USER_HINT" 2>/dev/null
    chmod 0644 "$USER_HINT" 2>/dev/null
fi

NOS=$(grep -c '"Path"' "$MODPATH/system/vendor/etc/powerhint.json" 2>/dev/null)
ui_print "- powerhint.json gerado para este dispositivo: ${NOS:-0} nos"

# --------------------------- 5. permissoes ---------------------------------
# Wrappers com LD_LIBRARY_PATH=/system/lib64 para suporte perfeito a ports
mv "$MODPATH/system/vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr"    "$MODPATH/system/vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr.bin" 2>/dev/null
cp "$MODPATH/power_service_wrapper.sh"    "$MODPATH/system/vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr" 2>/dev/null
chmod 0755 "$MODPATH/system/vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr"            "$MODPATH/system/vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr.bin" 2>/dev/null

mv "$MODPATH/system/vendor/bin/sendhint" "$MODPATH/system/vendor/bin/sendhint.bin" 2>/dev/null
cp "$MODPATH/sendhint_wrapper.sh" "$MODPATH/system/vendor/bin/sendhint" 2>/dev/null
chmod 0755 "$MODPATH/system/vendor/bin/sendhint" "$MODPATH/system/vendor/bin/sendhint.bin" 2>/dev/null
chmod 0644 "$MODPATH"/system/vendor/lib64/*.so 2>/dev/null
chmod 0644 "$MODPATH"/system/vendor/etc/powerhint.json 2>/dev/null
chmod 0644 "$MODPATH"/system/vendor/etc/perfmgr/*.json 2>/dev/null
chmod 0644 "$MODPATH"/system/vendor/etc/vintf/manifest/*.xml 2>/dev/null
chmod 0644 "$MODPATH"/common/*.json 2>/dev/null
chmod 0755 "$MODPATH"/common/*.sh "$MODPATH"/action.sh "$MODPATH"/service.sh 2>/dev/null

# ---------------------------- 6. configuracao ------------------------------
mkdir -p "$PERSIST" 2>/dev/null
if [ ! -f "$PERSIST/perfmgr.conf" ]; then
    cp "$MODPATH/perfmgr.conf" "$PERSIST/perfmgr.conf" 2>/dev/null
    # Nao substituir o Power HAL de um HyperOS em runtime/primeiro boot. A
    # troca e opt-in; evita tela branca se o vendor depender do HAL original.
    pm_conf_set ENABLE_HINTS 0
    pm_conf_set OVERRIDE_STOCK 0
    pm_conf_set ALLOW_STOCK_OVERRIDE 0
    if [ -n "$STOCK" ]; then
        pm_conf_set ENABLE_HAL 0
        ui_print "- Configuracao segura: HAL de fabrica preservado | hints=0 | override=0"
        ui_print "- Para tentar substituir conscientemente: action.sh override on e reinicie"
    else
        pm_conf_set ENABLE_HAL 1
        ui_print "- Sem HAL de fabrica: perfmgr ativo | hints=0"
    fi
else
    ui_print "- Configuracao do usuario preservada (/data/adb/libperfmgr/perfmgr.conf)"
fi

# ------------------------------ 7. resumo ----------------------------------
ui_print " "
ui_print "- Instalado:"
ui_print "    /vendor/lib64/libperfmgr.so (+ libs auxiliares)"
ui_print "    /vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr"
ui_print "    /vendor/bin/sendhint"
ui_print "    /vendor/etc/powerhint.json (gerado para este dispositivo)"
ui_print " "
ui_print "- HAL perfmgr: $(pm_conf_get ENABLE_HAL 1) | hints em sysfs: $(pm_conf_get ENABLE_HINTS 0)"
ui_print "- Substituir HAL de fabrica: $(pm_conf_get OVERRIDE_STOCK 0)"
ui_print "- Registo: $LOGFILE"
ui_print " "

pm_log INSTALL "instalado em $(pm_device) | $(pm_android) | soc=$(pm_soc) | root=$ROOT | variante=$VARIANT | nos=${NOS:-0} | stock_hal=${STOCK:-nenhum}"
pm_log_rotate
