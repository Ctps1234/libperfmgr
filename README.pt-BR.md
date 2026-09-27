# libperfmgr para HyperOS & AOSP

[![Build](https://github.com/Ctps1234/libperfmgr/actions/workflows/build.yml/badge.svg)](https://github.com/Ctps1234/libperfmgr/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/Ctps1234/libperfmgr?color=blue)](https://github.com/Ctps1234/libperfmgr/releases)
[![License](https://img.shields.io/badge/license-Apache%202.0-green.svg)](NOTICE.md)

*Read this in [English](README.md).*

---

Módulo systemless para **KernelSU**, **KernelSU Next**, **Magisk** e **APatch** que porta a stack oficial do **libperfmgr** (Google Pixel) para o **HyperOS** e ROMs customizadas **AOSP**.

Ele fornece a infraestrutura completa de gerenciamento de energia e fluidez do Android:
- **`libperfmgr.so`** — Gerenciador de performance C++ moderno da Google.
- **`android.hardware.power-service.pixel-libperfmgr`** — Serviço Power HAL AIDL nativo com suporte a **ADPF** (*Android Dynamic Performance Framework* / sessões de frame pacing).
- **`sendhint`** — Utilitário de linha de comando para disparar boosts e modos de energia manualmente.
- **Gerador dinâmico de `powerhint.json`** — Gera curvas de frequência de CPU/GPU e perfis uclamp calibrados especificamente para o kernel do seu aparelho no momento da instalação.

---

## 🚀 Principais Recursos

1. **ADPF Nativo (Frame Pacing no SurfaceFlinger)**:
   - Aceleração direta via uclamp para as threads gráficas de renderização (TIDs), mantendo 60 / 90 / 120 FPS cravados sem oscilação.
2. **Calibração Real por Dispositivo**:
   - Analisa os clusters em `/sys/devices/system/cpu/cpufreq/` e nós de GPU Adreno/Mali na instalação.
   - Gera apenas caminhos graváveis válidos, sem caminhos estáticos ou genéricos.
3. **Perfil Otimizado (Fluidez + Economia)**:
   - Boost de abertura de CPU (`LAUNCH`) de **1200ms** e micro-pulso de toque (`INTERACTION`) de **250ms**.
   - Para a composição do **Blur do HyperOS**, a GPU recebe somente um patamar intermediário: **450ms** ao abrir, **120ms** no toque e **48ms** em `DISPLAY_UPDATE_IMMINENT`. Não há frequência máxima forçada nem piso permanente de GPU.
   - Amigável ao Deep Sleep (`Race-to-Sleep`): dreno noturno em standby reduzido para a faixa de **~0.3% - 0.5% por hora**.
4. **Suporte Multi-Arquitetura Universal**:
   - **`api34` (Pixel 5 Snapdragon)**: 100% compatível com ARMv8.0 (Snapdragon 680, 685, 765G, Cortex-A73/A53). Zero erro de `Illegal instruction`.
   - **`api35` (Pixel Tensor Android 15)**: Power AIDL V5 para aparelhos modernos.
   - **`api36` (Pixel Tensor Android 16+)**: Power AIDL V6 para ROMs de ponta.
5. **Compatibilidade Total com ROMs Port**:
   - Wrappers automáticos de execução (`LD_LIBRARY_PATH=/system/lib64:/vendor/lib64`) resolvendo símbolos ausentes em sistemas híbridos (ex: System A17 + Vendor A15).
6. **Proteção Anti-Bootloop**:
   - O serviço aguarda o término do boot (`sys.boot_completed=1`) antes de assumir o HAL no runtime, garantindo que a tela inicial suba limpa, sem travamentos na logo da Xiaomi.

---

## 📦 Compatibilidade

- **Gerenciadores Root Suportados**: KernelSU, KernelSU Next, Magisk (v24+), APatch.
  *(Nota para KernelSU: recomenda-se o metamódulo `meta-overlayfs` para a montagem de `/vendor`).*
- **ROMs Suportadas**:
  - HyperOS 1.0, 2.0, 3.0, 4.0 (inclusive Ports).
  - ROMs AOSP (LineageOS, PixelOS, Evolution X, crDroid, Paranoid Android, etc.).
- **Arquiteturas Suportadas**: `arm64-v8a` (ARMv8.0-A até ARMv9-A).

---

## 📥 Instalação

1. Baixe o ZIP mais recente **`libperfmgr-hyperos-v*.zip`** nos [Artefatos do GitHub Actions](../../actions) ou nas [Releases](../../releases).
2. Abra o seu gerenciador Root (KernelSU / Magisk / APatch) ➡️ **Módulos** ➡️ **Instalar a partir do armazenamento**.
3. Selecione o ZIP e conclua a instalação.
4. Reinicie o celular.

O módulo já inicia **Ativo e Seguro** automaticamente após a tela inicial carregar!

---

## 🛠️ Gerenciamento por Terminal (`action.sh`)

Você pode controlar e conferir o estado do módulo a qualquer momento via Termux / Shell Root:

```sh
su
# Ver status detalhado, HAL em execução e serviços binder registrados:
/data/adb/modules/libperfmgr-hyperos/action.sh status

# Ligar / Desligar o serviço Power HAL:
/data/adb/modules/libperfmgr-hyperos/action.sh hal on|off

# Ligar / Desligar as escritas em nós de hardware (sysfs hints):
/data/adb/modules/libperfmgr-hyperos/action.sh hints on|off

# Ver registros e histórico de inicialização:
/data/adb/modules/libperfmgr-hyperos/action.sh log
```

### Testes Manuais de Boost (`sendhint`):

```sh
su
# Testar boost de abertura de aplicativos (1200ms):
/vendor/bin/sendhint -b LAUNCH -d 1200

# Testar boost de toque na tela (250ms):
/vendor/bin/sendhint -b INTERACTION -d 250
```

---

## ⚙️ Arquivos de Configuração

- **Configuração Persistente**: `/data/adb/libperfmgr/perfmgr.conf` (sobrevive a atualizações do módulo):
  ```ini
  ENABLE_HAL=1
  ENABLE_HINTS=1
  START_METHOD=auto
  OVERRIDE_STOCK=1
  FORCE_VARIANT=auto
  ```
- **Powerhint Personalizável**: `/data/adb/libperfmgr/powerhint.json` (tabela de frequências e boosts editável pelo usuário).

### Perfil equilibrado para Blur

Na regeneração, o módulo escolhe dois degraus válidos da GPU: o primeiro acima do idle para abertura e o seguinte para a primeira frame de toque/Blur. O pulso de `DISPLAY_UPDATE_IMMINENT` dura apenas **48 ms**, portanto não transforma uma animação longa em frequência máxima sustentada. Isso melhora a entrada e as transições desfocadas sem sacrificar o consumo em repouso.

Após atualizar o módulo, uma configuração persistente existente é preservada. Para aplicar o perfil novo ao seu arquivo atual, execute como root e reinicie o HAL (ou o aparelho):

```sh
/data/adb/modules/libperfmgr-hyperos/action.sh regen
/data/adb/modules/libperfmgr-hyperos/action.sh hal off
/data/adb/modules/libperfmgr-hyperos/action.sh hal on
```

---

## 📄 Licença e Atribuição

- Os binários pré-compilados do Pixel são originários de imagens de fábrica oficiais da Google sob termos proprietários. Consulte [NOTICE.md](NOTICE.md).
- Scripts, wrappers e ferramentas do módulo estão licenciados sob a Licença Apache 2.0.
