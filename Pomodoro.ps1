#requires -Version 5.1
<#
  Pomodoro sobreposto e discreto, com controle pela bandeja do Windows.

  Janelinha:  clique duplo = iniciar/pausar | arrastar = mover | botão direito = menu
  Bandeja:    clique = iniciar/pausar       | botão direito = menu completo
  Config salva em %APPDATA%\PomodoroOverlay\config.json
#>

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PomoNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int value);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
"@

# Janela invisível que recebe o atalho global de teclado
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class PomoHotkey : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    public event EventHandler Pressed;
    public PomoHotkey() { var cp = new CreateParams(); cp.Parent = new IntPtr(-3); CreateHandle(cp); }
    public bool Register(uint mod, uint vk) { return RegisterHotKey(Handle, 1, mod | 0x4000, vk); }
    public void Release() { UnregisterHotKey(Handle, 1); DestroyHandle(); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}
"@

# Uma instância só
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\PomodoroOverlay', [ref]$createdNew)
if (-not $createdNew) { return }

[void][PomoNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- Configuração ----------
$cfgDir  = Join-Path $env:APPDATA 'PomodoroOverlay'
$cfgFile = Join-Path $cfgDir 'config.json'
$cfg = [ordered]@{ FocusMin = 25; ShortMin = 5; LongMin = 15; AutoStart = $true; X = $null; Y = $null; Visible = $true; Docked = $true }
if (Test-Path $cfgFile) {
    try {
        $saved = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) { if ($null -ne $saved.$k) { $cfg[$k] = $saved.$k } }
    } catch {}
}

function Save-Config {
    $cfg.X = $S.FloatPos.X; $cfg.Y = $S.FloatPos.Y
    $cfg.Visible = $miShow.Checked; $cfg.Docked = $miDock.Checked
    try {
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        $cfg | ConvertTo-Json | Set-Content $cfgFile -Encoding UTF8
    } catch {}
}

# ---------- Estado ----------
$PhaseKey = @{ 'Foco' = 'FocusMin'; 'Pausa' = 'ShortMin'; 'Pausa longa' = 'LongMin' }
$Colors = @{
    'Foco'        = [Drawing.Color]::FromArgb(229, 72, 77)
    'Pausa'       = [Drawing.Color]::FromArgb(48, 164, 108)
    'Pausa longa' = [Drawing.Color]::FromArgb(62, 99, 221)
}
$IdleOpacity = 0.7

$S = @{
    Phase = 'Foco'; Running = $false; EndAt = [datetime]::MinValue
    Remaining = [timespan]::FromMinutes($cfg.FocusMin); Done = 0
    IconHandle = [IntPtr]::Zero; IconKey = ''
    Hover = $false; FlashUntil = [datetime]::MinValue
    Drag = $null; DragOrigin = $null; FloatPos = $null
    DockedNow = $false; Shown = $false; Tick = 0
    TextOn = [Drawing.Color]::FromArgb(240, 240, 240); TextOff = [Drawing.Color]::FromArgb(140, 140, 148)
}

function Get-PhaseLength([string]$p) { [timespan]::FromMinutes([double]$cfg[$PhaseKey[$p]]) }

function Get-Remaining {
    if ($S.Running) {
        $r = $S.EndAt - [datetime]::Now
        if ($r -lt [timespan]::Zero) { [timespan]::Zero } else { $r }
    } else { $S.Remaining }
}

function Format-Time([timespan]$t) {
    $sec = [int][math]::Ceiling($t.TotalSeconds)
    '{0:00}:{1:00}' -f [int][math]::Floor($sec / 60), ($sec % 60)
}

function Switch-Timer {
    if ($S.Running) {
        $S.Remaining = Get-Remaining
        $S.Running = $false
    } else {
        if ($S.Remaining -le [timespan]::Zero) { $S.Remaining = Get-PhaseLength $S.Phase }
        $S.EndAt = [datetime]::Now + $S.Remaining
        $S.Running = $true
    }
    Update-View
}

function Reset-Phase {
    $S.Running = $false
    $S.Remaining = Get-PhaseLength $S.Phase
    Update-View
}

function Start-NextPhase([bool]$fromTimer) {
    if ($S.Phase -eq 'Foco') {
        if ($fromTimer) { $S.Done++ }
        $next = if ($fromTimer -and $S.Done % 4 -eq 0) { 'Pausa longa' } else { 'Pausa' }
    } else {
        $next = 'Foco'
    }
    $S.Phase = $next
    $S.Remaining = Get-PhaseLength $next
    $run = if ($fromTimer) { [bool]$cfg.AutoStart } else { $S.Running }
    $S.Running = $run
    if ($run) { $S.EndAt = [datetime]::Now + $S.Remaining }

    if ($fromTimer) {
        $min = [int]$S.Remaining.TotalMinutes
        $msg = if ($next -eq 'Foco') { "Pausa encerrada. Hora de focar por $min min." }
               else { "Foco concluído ($($S.Done) hoje). $next de $min min." }
        if (-not $run) { $msg += ' Clique no ícone para iniciar.' }
        [System.Media.SystemSounds]::Exclamation.Play()
        $tray.ShowBalloonTip(6000, 'Pomodoro', $msg, [Windows.Forms.ToolTipIcon]::None)
        $S.FlashUntil = [datetime]::Now.AddSeconds(6)
    }
    Update-View
}

function Set-TrayIcon([Drawing.Color]$col, [double]$frac, [bool]$running) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $c = if ($running) { $col } else { [Drawing.Color]::FromArgb(140, $col) }
    $pen = New-Object Drawing.Pen($c, 3)
    $brush = New-Object Drawing.SolidBrush($c)
    $g.DrawEllipse($pen, 2, 2, 27, 27)
    if ($frac -gt 0) { $g.FillPie($brush, 7, 7, 17, 17, -90, [single](360 * $frac)) }
    $g.Dispose(); $pen.Dispose(); $brush.Dispose()
    $h = $bmp.GetHicon(); $bmp.Dispose()
    $old = $S.IconHandle
    $tray.Icon = [Drawing.Icon]::FromHandle($h)
    $S.IconHandle = $h
    if ($old -ne [IntPtr]::Zero) { [void][PomoNative]::DestroyIcon($old) }
}

function Update-View {
    $rem = Get-Remaining
    $txt = Format-Time $rem
    $col = $Colors[$S.Phase]

    $lbl.Text = $txt
    $lbl.ForeColor = if ($S.Running) { $S.TextOn } else { $S.TextOff }
    $bar.BackColor = $col

    $miToggle.Text = if ($S.Running) { 'Pausar' } else { 'Iniciar' }
    $miStatus.Text = "$($S.Phase) · $txt · $($S.Done) pomodoro(s) hoje"
    $paused = if ($S.Running) { '' } else { ' (pausado)' }
    $tray.Text = "Pomodoro · $($S.Phase) $txt$paused"

    $total = (Get-PhaseLength $S.Phase).TotalSeconds
    $frac = if ($total -gt 0) { [math]::Min(1, $rem.TotalSeconds / $total) } else { 0 }
    $step = [int][math]::Ceiling($frac * 48)
    $key = "$($S.Phase)|$($S.Running)|$step"
    if ($key -ne $S.IconKey) { Set-TrayIcon $col ($step / 48) $S.Running; $S.IconKey = $key }

    $op = if ($S.DockedNow -or $S.Hover -or [datetime]::Now -lt $S.FlashUntil) { 1.0 } else { $IdleOpacity }
    if ($form.Opacity -ne $op) { $form.Opacity = $op; Set-ToolWindowStyle }
}

# ---------- Modo "na barra de tarefas" ----------
function Get-TaskbarInfo {
    $tb = [PomoNative]::FindWindow('Shell_TrayWnd', $null)
    if ($tb -eq [IntPtr]::Zero) { return $null }
    $r = New-Object PomoNative+RECT
    [void][PomoNative]::GetWindowRect($tb, [ref]$r)
    if (($r.Right - $r.Left) -lt ($r.Bottom - $r.Top)) { return $null }   # barra vertical: não suportado
    $notifyLeft = $r.Right - (Px 320)
    $tn = [PomoNative]::FindWindowEx($tb, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    if ($tn -ne [IntPtr]::Zero) {
        $n = New-Object PomoNative+RECT
        [void][PomoNative]::GetWindowRect($tn, [ref]$n)
        $notifyLeft = $n.Left
    }
    @{ Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom; NotifyLeft = $notifyLeft }
}

function Get-ScreenColor([int]$x, [int]$y) {
    $bmp = New-Object Drawing.Bitmap 1, 1
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object Drawing.Size 1, 1))
    $g.Dispose(); $c = $bmp.GetPixel(0, 0); $bmp.Dispose()
    [Drawing.Color]::FromArgb(255, $c.R, $c.G, $c.B)
}

# Encaixa o contador à esquerda dos ícones do relógio, com a cor da barra
function Update-Dock {
    $tbi = Get-TaskbarInfo
    if ($null -eq $tbi) { return }
    $tbH = $tbi.Bottom - $tbi.Top
    $h = $tbH - (Px 8)
    $sample = if (([int]$cfg.FocusMin, [int]$cfg.ShortMin, [int]$cfg.LongMin | Measure-Object -Maximum).Maximum -ge 100) { '000:00' } else { '00:00' }
    $w = [Windows.Forms.TextRenderer]::MeasureText($sample, $FontDocked).Width + $form.Padding.Horizontal + (Px 4)
    $size = New-Object Drawing.Size($w, $h)
    if ($form.ClientSize -ne $size) { $form.ClientSize = $size }
    $loc = New-Object Drawing.Point(($tbi.NotifyLeft - $w - (Px 2)), ($tbi.Top + [int](($tbH - $h) / 2)))
    if ($form.Location -ne $loc) { $form.Location = $loc }

    $bg = Get-ScreenColor ($tbi.NotifyLeft - 1) ($tbi.Top + (Px 2))
    if ($form.BackColor.ToArgb() -ne $bg.ToArgb()) {
        $form.BackColor = $bg
        $light = ($bg.R * 0.299 + $bg.G * 0.587 + $bg.B * 0.114) -gt 140
        $S.TextOn  = if ($light) { [Drawing.Color]::FromArgb(25, 25, 25) }    else { [Drawing.Color]::FromArgb(245, 245, 245) }
        $S.TextOff = if ($light) { [Drawing.Color]::FromArgb(110, 110, 110) } else { [Drawing.Color]::FromArgb(150, 150, 155) }
    }
}

function Set-Layout {
    $S.DockedNow = $miDock.Checked -and ($null -ne (Get-TaskbarInfo))
    $form.SuspendLayout()
    if ($S.DockedNow) {
        $form.Padding = New-Object Windows.Forms.Padding((Px 12), 0, (Px 12), (Px 3))
        $bar.Dock = 'Bottom'; $bar.Height = Px 3
        $lbl.Font = $FontDocked
        $form.BackColor = [Drawing.Color]::Empty   # força recálculo da cor
        Update-Dock
    } else {
        $form.Padding = New-Object Windows.Forms.Padding(0)
        $bar.Dock = 'Left'; $bar.Width = Px 5
        $lbl.Font = $FontFloat
        $form.ClientSize = New-Object Drawing.Size((Px 92), (Px 32))
        $form.BackColor = [Drawing.Color]::FromArgb(28, 28, 32)
        $S.TextOn = [Drawing.Color]::FromArgb(240, 240, 240); $S.TextOff = [Drawing.Color]::FromArgb(140, 140, 148)
        $form.Location = $S.FloatPos
    }
    $form.ResumeLayout()
    # Na barra: sem a borda clara que o Windows 11 desenha; solta: borda padrão
    $border = if ($S.DockedNow) { -2 } else { -1 }
    [void][PomoNative]::DwmSetWindowAttribute($form.Handle, 34, [ref]$border, 4)
    Update-View
}

# Some quando há algo em tela cheia (vídeo, apresentação)
function Test-FullscreenForeground {
    $fg = [PomoNative]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero -or $fg -eq $form.Handle) { return $false }
    $sb = New-Object System.Text.StringBuilder 256
    [void][PomoNative]::GetClassName($fg, $sb, 256)
    if (@('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd') -contains $sb.ToString()) { return $false }
    $r = New-Object PomoNative+RECT
    [void][PomoNative]::GetWindowRect($fg, [ref]$r)
    $b = [Windows.Forms.Screen]::FromHandle($fg).Bounds
    return ($r.Left -le $b.Left -and $r.Top -le $b.Top -and $r.Right -ge $b.Right -and $r.Bottom -ge $b.Bottom)
}

function Update-Visibility {
    $want = $miShow.Checked -and -not (Test-FullscreenForeground)
    if ($want -ne $S.Shown) {
        [void][PomoNative]::ShowWindow($form.Handle, $(if ($want) { 4 } else { 0 }))   # 4 = mostrar sem roubar o foco
        $S.Shown = $want
    }
    # A barra de tarefas também é "sempre visível"; reafirma que o contador fica por cima dela
    Set-ToolWindowStyle
    if ($S.Shown -and -not $menu.Visible) {
        [void][PomoNative]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)
    }
}

# ---------- Menu (compartilhado entre bandeja e janelinha) ----------
$menu = New-Object Windows.Forms.ContextMenuStrip
function Add-Sep { [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) }

$miStatus = $menu.Items.Add('...'); $miStatus.Enabled = $false
Add-Sep
$miToggle = $menu.Items.Add('Iniciar')
$miToggle.Font = New-Object Drawing.Font($miToggle.Font, [Drawing.FontStyle]::Bold)
$miToggle.add_Click({ Switch-Timer })
$miSkip = $menu.Items.Add('Pular para a próxima fase'); $miSkip.add_Click({ Start-NextPhase $false })
$miReset = $menu.Items.Add('Reiniciar fase atual');     $miReset.add_Click({ Reset-Phase })
Add-Sep

Add-Type -AssemblyName Microsoft.VisualBasic

function Set-Duration([string]$key, [int]$min) {
    # Se a fase atual ainda não começou, já aplica a nova duração nela
    $isCurrent = ($PhaseKey[$S.Phase] -eq $key)
    $wasFull = $isCurrent -and -not $S.Running -and ($S.Remaining -eq (Get-PhaseLength $S.Phase))
    $cfg[$key] = $min
    if ($wasFull) { $S.Remaining = Get-PhaseLength $S.Phase }
    Save-Config; $S.IconKey = ''; Update-View
}

# Marca a opção que bate com a config; se nenhuma bater, marca "Personalizado"
function Sync-DurationChecks($parent, [string]$key) {
    $cur = [int]$cfg[$key]
    $custom = $null; $found = $false
    foreach ($o in $parent.DropDownItems) {
        if ($null -eq $o.Tag) { continue }   # separador
        if ($o.Tag.Custom) { $custom = $o; continue }
        $o.Checked = ($o.Tag.Min -eq $cur)
        if ($o.Checked) { $found = $true }
    }
    $custom.Checked = -not $found
    $custom.Text = if ($found) { 'Personalizado...' } else { "Personalizado ($cur min)..." }
}

function Add-DurationMenu([string]$title, [string]$key, [int[]]$options) {
    $parent = New-Object Windows.Forms.ToolStripMenuItem($title)
    foreach ($m in $options) {
        $it = New-Object Windows.Forms.ToolStripMenuItem("$m min")
        $it.Tag = @{ Key = $key; Min = $m; Parent = $parent; Custom = $false }
        $it.add_Click({
            param($sender, $e)
            Set-Duration $sender.Tag.Key $sender.Tag.Min
            Sync-DurationChecks $sender.Tag.Parent $sender.Tag.Key
        })
        [void]$parent.DropDownItems.Add($it)
    }
    [void]$parent.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
    $ci = New-Object Windows.Forms.ToolStripMenuItem('Personalizado...')
    $ci.Tag = @{ Key = $key; Parent = $parent; Custom = $true; Title = $title }
    $ci.add_Click({
        param($sender, $e)
        $k = $sender.Tag.Key
        $ans = [Microsoft.VisualBasic.Interaction]::InputBox("Quantos minutos? (1 a 240)", $sender.Tag.Title, [string]$cfg[$k])
        $n = 0
        if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 240) {
            Set-Duration $k $n
        } elseif ($ans.Trim() -ne '') {
            [void][Windows.Forms.MessageBox]::Show('Digite um número inteiro de 1 a 240.', 'Pomodoro')
        }
        Sync-DurationChecks $sender.Tag.Parent $k
    })
    [void]$parent.DropDownItems.Add($ci)
    # Abre o submenu para o lado que cabe na MESMA tela (senão vai para o outro monitor)
    $parent.add_DropDownOpening({
        param($sender, $e)
        $wa = [Windows.Forms.Screen]::FromRectangle($menu.Bounds).WorkingArea
        $need = $sender.DropDown.PreferredSize.Width
        $sender.DropDownDirection = if ($menu.Bounds.Right + $need -gt $wa.Right) { 'Left' } else { 'Right' }
    })
    Sync-DurationChecks $parent $key
    [void]$menu.Items.Add($parent)
}
Add-DurationMenu 'Duração do foco'        'FocusMin' @(15, 20, 25, 30, 45, 50)
Add-DurationMenu 'Duração da pausa'       'ShortMin' @(3, 5, 10)
Add-DurationMenu 'Duração da pausa longa' 'LongMin'  @(15, 20, 30)

$miAuto = $menu.Items.Add('Iniciar próxima fase automaticamente')
$miAuto.CheckOnClick = $true; $miAuto.Checked = [bool]$cfg.AutoStart
$miAuto.add_Click({ $cfg.AutoStart = $miAuto.Checked; Save-Config })

$miShow = $menu.Items.Add('Mostrar contador na tela')
$miShow.CheckOnClick = $true; $miShow.Checked = [bool]$cfg.Visible
$miShow.add_Click({ Update-Visibility; Save-Config })

$miDock = $menu.Items.Add('Fixar na barra de tarefas')
$miDock.CheckOnClick = $true; $miDock.Checked = [bool]$cfg.Docked
$miDock.add_Click({ Set-Layout; Save-Config })
Add-Sep
$miExit = $menu.Items.Add('Sair')
$miExit.add_Click({
    Save-Config
    $timer.Stop()
    $hotkey.Release()
    $tray.Visible = $false
    $tray.Dispose()
    [Windows.Forms.Application]::ExitThread()
})

# ---------- Janelinha sobreposta ----------
$gfx = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $gfx.DpiX / 96; $gfx.Dispose()
function Px([double]$v) { [int][math]::Round($v * $scale) }

$form = New-Object Windows.Forms.Form
$form.Text = 'Pomodoro'
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.AutoScaleMode = 'None'
$form.ClientSize = New-Object Drawing.Size((Px 92), (Px 32))
$form.BackColor = [Drawing.Color]::FromArgb(28, 28, 32)
$form.Opacity = $IdleOpacity
$form.add_HandleCreated({
    $v = 2  # cantos arredondados no Windows 11
    [void][PomoNative]::DwmSetWindowAttribute($form.Handle, 33, [ref]$v, 4)
    Set-ToolWindowStyle
})

# Janela de ferramenta: não aparece no Alt+Tab. O WinForms apaga esse estilo quando
# muda a transparência, então é reaplicado sempre que some.
function Set-ToolWindowStyle {
    $ex = [PomoNative]::GetWindowLong($form.Handle, -20)
    if (($ex -band 0x80) -eq 0) {
        [void][PomoNative]::SetWindowLong($form.Handle, -20, (($ex -bor 0x80) -band (-bnot 0x40000)))
    }
}

$lbl = New-Object Windows.Forms.Label
$lbl.Dock = 'Fill'
$lbl.TextAlign = 'MiddleCenter'
$FontFloat  = New-Object Drawing.Font('Segoe UI Semibold', 13)
$FontDocked = New-Object Drawing.Font('Segoe UI Semibold', 11)
$lbl.Font = $FontFloat
$bar = New-Object Windows.Forms.Panel
$bar.Dock = 'Left'
$bar.Width = Px 5
$form.Controls.Add($lbl)
$form.Controls.Add($bar)

$tip = New-Object Windows.Forms.ToolTip
$tip.SetToolTip($lbl, 'Clique duplo: iniciar/pausar · Arraste para mover · Botão direito: menu')

$onDown  = { param($sender, $e) if ($e.Button -eq 'Left' -and -not $S.DockedNow) { $S.Drag = [Windows.Forms.Cursor]::Position; $S.DragOrigin = $form.Location } }
$onMove  = { param($sender, $e)
    if ($null -ne $S.Drag -and $e.Button -eq 'Left') {
        $p = [Windows.Forms.Cursor]::Position
        $form.Location = New-Object Drawing.Point(($S.DragOrigin.X + $p.X - $S.Drag.X), ($S.DragOrigin.Y + $p.Y - $S.Drag.Y))
    } }
$onUp    = { if ($null -ne $S.Drag) { $S.Drag = $null; $S.FloatPos = $form.Location; Save-Config } }
$onEnter = { $S.Hover = $true; $form.Opacity = 1.0 }
$onLeave = { $S.Hover = $false; Update-View }
foreach ($c in @($lbl, $bar)) {
    $c.add_MouseDown($onDown); $c.add_MouseMove($onMove); $c.add_MouseUp($onUp)
    $c.add_MouseEnter($onEnter); $c.add_MouseLeave($onLeave)
    $c.ContextMenuStrip = $menu
}
$lbl.add_DoubleClick({ Switch-Timer })

# Posição: a salva (se ainda estiver em alguma tela) ou canto inferior direito
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$x = $wa.Right - $form.Width - (Px 16)
$y = $wa.Bottom - $form.Height - (Px 16)
if ($null -ne $cfg.X -and $null -ne $cfg.Y) {
    $pt = New-Object Drawing.Point([int]$cfg.X, [int]$cfg.Y)
    if ([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($pt) }) { $x = [int]$cfg.X; $y = [int]$cfg.Y }
}
$S.FloatPos = New-Object Drawing.Point($x, $y)
$form.Location = $S.FloatPos

# ---------- Bandeja ----------
$tray = New-Object Windows.Forms.NotifyIcon
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($sender, $e) if ($e.Button -eq 'Left') { Switch-Timer } })
$tray.add_BalloonTipClicked({ if (-not $S.Running) { Switch-Timer } })

Set-Layout
$tray.Visible = $true

# Atalho global: Ctrl+Alt+P (ou Ctrl+Alt+Shift+P se outro programa já usa)
$hotkey = New-Object PomoHotkey
$hotkey.add_Pressed({ Switch-Timer })
$hkText = $null
if ($hotkey.Register(0x3, 0x50)) { $hkText = 'Ctrl+Alt+P' }
elseif ($hotkey.Register(0x7, 0x50)) { $hkText = 'Ctrl+Alt+Shift+P' }
if ($hkText) {
    $miToggle.ShortcutKeyDisplayString = $hkText
    $tip.SetToolTip($lbl, "Clique duplo ou $hkText`: iniciar/pausar · Botão direito: menu")
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
    $S.Tick++
    if ($S.Running -and (Get-Remaining) -le [timespan]::Zero) { Start-NextPhase $true }
    if ($S.DockedNow -and $S.Tick % 4 -eq 0) { Update-Dock }   # acompanha mudanças nos ícones/tema
    Update-Visibility
    Update-View
})

$form.Show(); $S.Shown = $true
Update-Visibility
$timer.Start()

$ctx = New-Object Windows.Forms.ApplicationContext
[Windows.Forms.Application]::Run($ctx)

if ($S.IconHandle -ne [IntPtr]::Zero) { [void][PomoNative]::DestroyIcon($S.IconHandle) }
$mutex.ReleaseMutex()
