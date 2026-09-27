#!/system/bin/sh
# ---------------------------------------------------------------------------
# libperfmgr-hyperos - botao Action
#
#   action.sh              mostra o estado e liga/desliga o HAL
#   action.sh status       estado detalhado
#   action.sh hal on|off       liga/desliga o servico power HAL
#   action.sh hints on|off     liga/desliga a escrita nos nos sysfs
#   action.sh override on|off  substitui (ou nao) o HAL android.hardware.power de fabrica
#   action.sh regen        volta a gerar o powerhint.json para este dispositivo
#   action.sh log          mostra as ultimas linhas do registo
# ---------------------------------------------------------------------------
MODDIR=${0%/*}
. "$MODDIR/common/libperfmgr-common.sh"

usage() {
    echo "libperfmgr-hyperos"
    echo "  action.sh [status|hal on|off|hints on|off|override on|off|regen|log]"
}

do_status() {
    echo "libperfmgr-hyperos - estado"
    echo "  dispositivo: $(pm_device)"
    echo "  android:     $(pm_android)"
    echo "  soc:         $(pm_soc)"
    echo "  variante:    $(pm_variant)"
    stock=$(pm_stock_hal)
    echo "  HAL de fabrica: ${stock:-nenhum} (servico: $(pm_stock_svc))"
    if pm_override_allowed; then over="confirmado"; else over="desligado/nao confirmado"; fi
    echo "  override:    $over"
    pm_status_line
    echo "  libperfmgr.so em /vendor: $([ -f /vendor/lib64/libperfmgr.so ] && echo sim || echo NAO)"
    echo "  registo: $LOGFILE"
}

hal_on() {
    stock=$(pm_stock_hal)
    # Nunca parar/iniciar o HAL stock a quente: dois Power HALs ou a troca no
    # meio de uma composicao podem derrubar o SurfaceFlinger (tela branca).
    # Em aparelhos com HAL proprio, a substituicao e um opt-in e so ocorre no
    # boot, pelo service.sh, depois de o sistema estar estavel.
    if [ -n "$stock" ]; then
        echo "  BLOQUEADO: HAL de fabrica detetado ($(basename "$stock"))."
        if pm_override_allowed; then
            echo "  A substituicao esta configurada, mas nao e iniciada manualmente."
            echo "  Reinicie o telefone para testar; para cancelar: action.sh override off"
        else
            echo "  Mantenha o HAL de fabrica. So use 'action.sh override on' se aceitar o risco e reinicie."
        fi
        return 1
    fi
    pm_conf_set ENABLE_HAL 1
    pm_wait_for_binary || {
        echo "  ERRO: binario do HAL nao encontrado (modulo nao montado?)"
        return 1
    }
    pm_label_files
    pm_start_hal
    sleep 3
    pm_hal_registered && echo "  HAL perfmgr ativo e registado com sucesso" || echo "  AVISO: HAL nao registado (ver registo)"
}

hal_off() {
    pm_conf_set ENABLE_HAL 0
    pm_stop_hal
    echo "  HAL desativado"
}

override_on() {
    stock=$(pm_stock_hal)
    if [ -z "$stock" ]; then
        echo "  Nao ha HAL android.hardware.power de fabrica: nada a substituir"
        pm_conf_set OVERRIDE_STOCK 0
        pm_conf_set ALLOW_STOCK_OVERRIDE 0
        pm_conf_set ENABLE_HAL 1
        return 0
    fi
    pm_conf_set OVERRIDE_STOCK 1
    pm_conf_set ALLOW_STOCK_OVERRIDE 1
    pm_conf_set ENABLE_HAL 1
    # NUNCA trocar o Power HAL em runtime: isto pode deixar o SurfaceFlinger
    # sem provider e causar tela branca. O service.sh faz a troca somente no
    # proximo boot, apos sys.boot_completed.
    base=$(basename "$stock")
    echo "  OVERRIDE agendado: '$base' sera parado apenas no proximo arranque."
    echo "  ATENCAO: reinicie para testar. Nao use 'action.sh hal on' em runtime."
    echo "  Se quiser cancelar antes de reiniciar: action.sh override off"
}

override_off() {
    pm_conf_set OVERRIDE_STOCK 0
    pm_conf_set ALLOW_STOCK_OVERRIDE 0
    pm_conf_set ENABLE_HAL 0
    pm_stop_hal
    echo "  OVERRIDE desativado: o HAL de fabrica continua ativo"
}

hints_on() {
    if [ "$(pm_conf_get ENABLE_HAL 1)" != "1" ]; then
        echo "  ERRO: o HAL perfmgr esta desativado"
        return 1
    fi
    stock=$(pm_stock_hal)
    if [ -n "$stock" ] && ! pm_override_allowed; then
        echo "  ERRO: o HAL de fabrica esta ativo; nao aplique hints do perfmgr sobre ele"
        return 1
    fi
    pm_conf_set ENABLE_HINTS 1
    pm_enable_hints 1
    echo "  Hints ativas (o powerhint.json passa a ser aplicado)"
}

hints_off() {
    pm_conf_set ENABLE_HINTS 0
    pm_enable_hints 0
    echo "  Hints desativadas (apenas ADPF/hint sessions)"
}

regen() {
    sh "$MODDIR/common/gen-powerhint.sh" "$USER_HINT" "$MODDIR/common/adpf-config.json"
    if [ -f "$USER_HINT" ]; then
        cp "$USER_HINT" "$MODDIR/system/vendor/etc/powerhint.json" 2>/dev/null
        mkdir -p "$DEBUG_HINT_DIR" 2>/dev/null
        cp "$USER_HINT" "$DEBUG_HINT" 2>/dev/null
        chmod 0644 "$DEBUG_HINT" 2>/dev/null
        pm_chcon "$DEBUG_HINT" u:object_r:vendor_configs_file:s0 2>/dev/null
        setprop vendor.powerhal.config.debug true
        echo "  powerhint.json regenerado:"
        grep -c '"Name"' "$USER_HINT" | sed 's/^/    entradas: /'
        echo "  reinicie o telefone para o HAL recarregar a configuracao com seguranca"
    else
        echo "  ERRO: nao foi possivel gerar o powerhint.json"
    fi
}

show_log() {
    echo "--- $LOGFILE ---"
    tail -n 40 "$LOGFILE" 2>/dev/null || echo "(sem registo)"
}

case "${1:-toggle}" in
status) do_status ;;
hal)
    case "${2:-on}" in
    on | 1) hal_on ;;
    off | 0) hal_off ;;
    *) usage ;;
    esac
    ;;
hints)
    case "${2:-on}" in
    on | 1) hints_on ;;
    off | 0) hints_off ;;
    *) usage ;;
    esac
    ;;
override)
    case "${2:-on}" in
    on | 1) override_on ;;
    off | 0) override_off ;;
    *) usage ;;
    esac
    ;;
regen) regen ;;
log) show_log ;;
toggle)
    do_status
    if [ "$(pm_conf_get ENABLE_HAL 1)" = "1" ]; then
        echo "  -> a desligar o HAL"
        hal_off
    else
        echo "  -> a ligar o HAL"
        hal_on
    fi
    ;;
*) usage ;;
esac

exit 0
