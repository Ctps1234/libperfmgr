# Registo de alterações

## Em desenvolvimento

- **Segurança do Power HAL**: instalações novas preservam o HAL de fábrica e deixam HAL/hints/override desligados quando ele existe. O início manual passa a ser bloqueado para não trocar o HAL durante a composição e causar tela branca; `override on` restaura o manifesto e só aplica a troca no boot seguinte, que passa a iniciar automaticamente.
- Perfil de composição equilibrado para o **Blur do HyperOS**: pulsos GPU no primeiro frame de `INTERACTION` e `DISPLAY_UPDATE_IMMINENT`, usando degraus intermediários e janelas curtas (120 ms / 48 ms), sem fixar a GPU em frequência máxima.
- O gerador agora também produz JSON válido quando o arquivo de configuração ADPF não está disponível.
- Adicionado teste de fumaça do gerador com árvores cpufreq/devfreq sintéticas.

## v1.0 (primeira versão)

- **Duas variantes de binários**, escolhidas automaticamente pelo Android:
  `api35` (Android 15, power AIDL V5) e `api36` (Android 16+, power AIDL V6).
- **Detecção do HAL `android.hardware.power` de fábrica** (Qualcomm/CAF costuma ter um).
  Por predefinição não o substitui (modo seguro); `action.sh override on` activa a
  substituição: whiteout do binário de fábrica, manifesto VINTF com `override="true"`
  e paragem do respectivo serviço init antes de arrancar o perfmgr.
- Instala a stack perfmgr no HyperOS de forma *systemless*:
  - `libperfmgr.so`, `libdisppower-pixel.so`, `pixel-power-ext-V1-ndk.so`
  - HAL AIDL `android.hardware.power-service.pixel-libperfmgr` (V6)
  - utilitário `sendhint`
  - manifesto VINTF e `powerhint.json`
- Geração automática do `powerhint.json` a partir dos nós reais do dispositivo
  (clusters de CPU, GPU Adreno/Mali, `schedtune`), com fallback seguro quando o
  kernel não expõe nós utilizáveis.
- Dois modos: **ADPF/hint sessions** (predefinição, sem escrita em `sysfs`) e
  **hints em `sysfs`** (opt-in).
- Domínio SELinux próprio (`perfmgr_hal`), para não depender de `hal_power_default`
  (que o HyperOS não define).
- Arranque via `initrc` do KernelSU, com fallback para arranque direto (Magisk/APatch).
- **Suporte a ROMs port (system A17 + vendor A15)**: a variante passa a ser escolhida pela
  lib AIDL presente em `/system/lib64` (lado cliente) em vez do SDK, com `FORCE_VARIANT=auto|api35|api36`
  para impor à mão.
- Instala condicionalmente `android.hardware.common.fmq-V1-ndk.so` e
  `android.frameworks.stats-V2-ndk.so` (faltam em muitos vendors e faziam o serviço falhar
  com `CANNOT LINK EXECUTABLE`).
- Detecção de SoC alargada (Qualcomm `bengal`/`kona`/`kalama`…, MediaTek, Unisoc, Exynos).
- WebUI + botão Action para ligar/desligar HAL e hints, regerar hints e ver registos.
- Instala as bibliotecas AIDL de dependência apenas se a ROM não as tiver.
