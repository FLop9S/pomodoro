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

Toca só durante o foco, com o timer rodando: pausa junto com ele, fica mudo durante o alarme e, nas pausas (curta e longa), tudo fica em silêncio, inclusive o tic-tac. O alarme do fim da pausa continua tocando. Escolha em **Som de fundo** no menu; com o timer pausado, a escolha toca uma amostra de 5 segundos.

| Opção | O que é |
|---|---|
| Nenhum | Silêncio |
| Tic-tac | Um tique por segundo (padrão) |
| Minecraft (savana) | Clima de "study with me" no Minecraft: vento com rajadas, pássaros esparsos e um piano calmo que toca por um tempo e some, como no jogo. Tudo gerado pelo próprio app (composição original, não é a trilha do jogo) |
| Chuva | Chuva forte de noite com trovões distantes (um a cada 25 a 50 s): chiado de fundo, chuvisco denso e gotas caindo em poças |
| Ruído marrom, Mar | Sons gerados pelo próprio app, em loop sem emenda |
| Claude FM | A rádio lo-fi 24/7 da Anthropic (a mesma do `/radio` do Claude Code). Toca dentro do Pomodoro, com o player oficial do YouTube numa janela escondida; segue o timer e o volume como os outros sons. Leva uns 10 s para conectar e precisa de internet com acesso ao YouTube |

Os sons são criados na primeira vez que são escolhidos (menos de 1 segundo) e ficam em `%APPDATA%\PomodoroOverlay\sons`. O volume do som de fundo fica em **Som de fundo > Volume**. Só o Claude FM depende de internet.

Pelo menu dá para:

- pular de fase ou reiniciar a fase atual;
- mudar as durações de foco, pausa e pausa longa (opções prontas ou **Personalizado...**, de 1 a 240 min);
- ligar/desligar o alarme sonoro (desligado, volta o som padrão do Windows);
- escolher o som de fundo e o volume;
- ligar/desligar a **Cafeína**: o computador não dorme, a tela não apaga nem bloqueia e o Teams não fica "Ausente" (veja abaixo);
- fixar na barra de tarefas ou deixar solto e arrastável;
- esconder o contador da tela.

Outros comportamentos:

- não aparece no Alt+Tab;
- some quando há algo em tela cheia (vídeo, apresentação);
- se `Ctrl+Alt+P` já estiver em uso por outro programa, o atalho vira `Ctrl+Alt+Shift+P`.

### Cafeína

Faz o mesmo que o app Caffeine, sem precisar dele: pede ao Windows para não dormir nem apagar a tela e, depois de 1 minuto sem uso, "aperta" a tecla F15 (que não faz nada) uma vez por minuto. Enquanto você usa o PC, nenhuma tecla é enviada. Liga e desliga pelo menu; a escolha fica salva e, ligada, o ícone da bandeja mostra "Cafeína". Ao sair do Pomodoro, o Windows volta ao normal.

## Instalação

1. Baixe esta pasta.
2. Dê dois cliques em `Iniciar Pomodoro.vbs` (abre sem janela de console).
3. Para abrir junto com o Windows: `Win+R` → `shell:startup` → crie ali um atalho para `Iniciar Pomodoro.vbs`.

As configurações (durações, posição, modo) ficam em `%APPDATA%\PomodoroOverlay\config.json`.

## Requisitos

- Windows 10 ou 11 com Windows PowerShell 5.1 (já vem no sistema).
- O modo "na barra de tarefas" funciona com a barra embaixo ou em cima da tela.
- Sons de fundo (exceto tic-tac e Claude FM) usam o Windows Media Player, que vem com o Windows; sem ele, essas opções aparecem desativadas.
- O Claude FM usa o WebView2 (motor do Edge, já instalado no Windows 10/11 atualizado). A pasta `lib` traz as 3 DLLs oficiais da Microsoft que o PowerShell precisa para usá-lo (pacote NuGet `Microsoft.Web.WebView2` 1.0.4258.31, assinadas pela Microsoft); mantenha `lib` junto do `Pomodoro.ps1`.
