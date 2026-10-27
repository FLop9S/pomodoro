# Pomodoro

Timer Pomodoro discreto para Windows, que fica encaixado na barra de tarefas (ao lado dos ícones do relógio) ou flutuando sobre as outras janelas. Feito em PowerShell + WinForms, sem nada para instalar.

## Como usar

| Ação | Como |
|---|---|
| Iniciar / pausar | `Ctrl+Alt+P` de qualquer lugar, clique duplo no contador ou clique no ícone da bandeja |
| Menu completo | Botão direito no contador ou no ícone da bandeja |
| Mover (modo solto) | Arrastar o contador |

A linha colorida indica a fase: vermelho = foco, verde = pausa, azul = pausa longa (a cada 4 focos). Números em cinza = pausado. Ao fim de cada fase aparece uma notificação do Windows com som.

Pelo menu dá para:

- pular de fase ou reiniciar a fase atual;
- mudar as durações de foco, pausa e pausa longa (opções prontas ou **Personalizado...**, de 1 a 240 min);
- ligar/desligar o início automático da próxima fase;
- fixar na barra de tarefas ou deixar solto e arrastável;
- esconder o contador da tela.

Outros comportamentos:

- não aparece no Alt+Tab;
- some quando há algo em tela cheia (vídeo, apresentação);
- se `Ctrl+Alt+P` já estiver em uso por outro programa, o atalho vira `Ctrl+Alt+Shift+P`.

## Instalação

1. Baixe esta pasta.
2. Dê dois cliques em `Iniciar Pomodoro.vbs` (abre sem janela de console).
3. Para abrir junto com o Windows: `Win+R` → `shell:startup` → crie ali um atalho para `Iniciar Pomodoro.vbs`.

As configurações (durações, posição, modo) ficam em `%APPDATA%\PomodoroOverlay\config.json`.

## Requisitos

- Windows 10 ou 11 com Windows PowerShell 5.1 (já vem no sistema).
- O modo "na barra de tarefas" funciona com a barra embaixo ou em cima da tela.
