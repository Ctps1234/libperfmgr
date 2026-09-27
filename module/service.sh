#!/system/bin/sh
# libperfmgr-hyperos - executado em late_start (depois do boot e da montagem)
MODDIR=${0%/*}
. "$MODDIR/common/libperfmgr-common.sh"

pm_log BOOT "service.sh: $(pm_device)"

if [ "$(pm_conf_get ENABLE_HAL 1)" != "1" ]; then
    pm_log HAL "desativado por configuracao (ENABLE_HAL=0)"
    exit 0
fi

# IMPORTANTE: Esperar o Android terminar 100% a inicializacao e desbloquear a tela
# (sys.boot_completed=1) ANTES de tocar em qualquer servico de HAL!
# Isto garante ZERO risco de travar na logo da Xiaomi.
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
sleep 5
pm_log BOOT "sistema totalmente inicializado (sys.boot_completed=1)"

# o binario vive em /vendor/bin/hw (sobreposto pelo modulo): esperar por ele
if ! pm_wait_for_binary; then
    pm_log ERRO "$HAL_BIN nao encontrado apos 30s - o modulo nao foi montado?"
    exit 1
fi

# garantir etiquetas corretas (pode ter sido montado depois do post-mount)
pm_label_files

# So uma confirmacao explicita nesta versao permite parar o HAL de fabrica.
if pm_override_allowed; then
    pm_stop_stock_hal
fi

# ja esta a correr?
if pm_hal_registered && ! pm_override_allowed; then
    pm_log HAL "servico ja registado, nada a fazer"
else
    # Iniciamos diretamente via pm_start_hal para garantir que o ambiente
    # LD_LIBRARY_PATH=/system/lib64 seja repassado ao binario
    pm_start_hal
fi

# verificacao
sleep 4
if pm_hal_registered; then
    pm_log HAL "OK - android.hardware.power.IPower/default registado"
    # As propriedades de ADPF do SurfaceFlinger (debug.sf.enable_adpf_cpu_hint)
    # exigem que o SurfaceFlinger seja reiniciado ou inicializado com elas. Mudar isso
    # com o SurfaceFlinger no meio da renderizacao da logo causa crash loop do display.
    # O libperfmgr ja atende as requisicoes de frame pacing pelo Binder nativamente.
    pm_log HAL "HAL pronto e atendendo requisicoes"
else
    pm_log ERRO "servico NAO registado. init.svc.$SVC='$(pm_svc_state)'"
    pm_log ERRO "ultimas linhas do logcat do HAL:"
    logcat -d -s powerhal-libperfmgr:* libperfmgr:* *:E 2>/dev/null | tail -n 15 >>"$LOGFILE" 2>/dev/null
fi

# hints (escrita em sysfs) sao ligadas no boot-completed, quando o sistema
# ja esta estavel - assim um arranque problematico nao deixa o nos mal
# Se ENABLE_HINTS estiver ativo, liga a chave do HintManager na hora
if [ "$(pm_conf_get ENABLE_HINTS 0)" = "1" ]; then
    pm_enable_hints 1
fi

pm_log BOOT "service.sh concluido: $(pm_status_line)"
