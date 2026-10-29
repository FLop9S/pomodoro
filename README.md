# Pomodoro

Timer Pomodoro discreto para Windows, que fica encaixado na barra de tarefas (ao lado dos ícones do relógio) ou flutuando sobre as outras janelas. Feito em PowerShell + WinForms, sem nada para instalar.

## Como usar

| Ação | Como |
|---|---|
| Iniciar / pausar | `Ctrl+Alt+P` de qualquer lugar, clique duplo no contador ou clique no ícone da bandeja |
| Menu completo | Botão direito no contador ou no ícone da bandeja |
| Mover (modo solto) | Arrastar o contador |

A linha colorida indica a fase: vermelho = foco, verde = pausa, azul = pausa longa (a cada 4 focos). Números em cinza = pausado. Ao fim de cada fase toca um alarme (três notas, duas vezes) e aparece uma notificação do Windows; o timer fica pausado na próxima fase até ser iniciado de novo (atalho, clique duplo, ícone da bandeja ou clique na notificação).

### Som de fundo

Toca só enquanto o timer está rodando (pausa junto com ele e fica mudo durante o alarme). Escolha em **Som de fundo** no menu; com o timer pausado, a escolha toca uma amostra de 5 segundos.

| Opção | O que é |
|---|---|
| Nenhum | Silêncio |
| Tic-tac | Um tique por segundo (padrão) |
| Minecraft (savana) | Clima de "study with me" no Minecraft: vento com rajadas, pássaros esparsos e um piano calmo que toca por um tempo e some, como no jogo. Tudo gerado pelo próprio app (composição original, não é a trilha do jogo) |
| Chuva, Ruído marrom, Mar | Sons gerados pelo próprio app, em loop sem emenda |

Os sons são criados na primeira vez que são escolhidos (menos de 1 segundo) e ficam em `%APPDATA%\PomodoroOverlay\sons`. O volume do som de fundo fica em **Som de fundo > Volume**. Nada depende de internet.

Pelo menu dá para:

- pular de fase ou reiniciar a fase atual;
- mudar as durações de foco, pausa e pausa longa (opções prontas ou **Personalizado...**, de 1 a 240 min);
- ligar/desligar o alarme sonoro (desligado, volta o som padrão do Windows);
- escolher o som de fundo e o volume;
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
- Sons de fundo (exceto tic-tac) usam o Windows Media Player, que vem com o Windows; sem ele, essas opções aparecem desativadas.
