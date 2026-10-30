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
    // "Cafeína": manter o PC ativo
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
    // Avisa o Explorer que as configurações da barra mudaram (o mesmo que o app Configurações faz)
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, UIntPtr w, string l, uint flags, uint timeout, out UIntPtr result);
    public static void NotifyTraySettings() { UIntPtr r; SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero, "TraySettings", 2, 2000, out r); }
    public static uint IdleMs() {
        var lii = new LASTINPUTINFO(); lii.cbSize = (uint)Marshal.SizeOf(lii);
        return GetLastInputInfo(ref lii) ? (uint)Environment.TickCount - lii.dwTime : 0;
    }
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

# Sons gerados em memória (WAV PCM 16 bits mono): nada de arquivo extra
Add-Type -TypeDefinition @"
using System;
using System.IO;
public static class PomoSound {
    const int Rate = 22050;
    // Notas em trios: frequência (Hz, 0 = silêncio), duração (ms), volume (0 a 1)
    public static byte[] Wav(params double[] notes) {
        var pcm = new MemoryStream();
        var w = new BinaryWriter(pcm);
        for (int i = 0; i + 2 < notes.Length; i += 3) {
            double f = notes[i], g = notes[i + 2];
            int n = (int)(Rate * notes[i + 1] / 1000);
            double k = 4.6 / n;                  // decai até ~1% no fim da nota
            int attack = Rate * 2 / 1000;        // 2 ms de ataque evita estalo
            for (int s = 0; s < n; s++) {
                double env = Math.Exp(-k * s) * Math.Min(1.0, (double)s / attack);
                double v = f > 0 ? g * env * Math.Sin(2 * Math.PI * f * s / Rate) : 0;
                w.Write((short)(v * short.MaxValue));
            }
        }
        w.Flush();
        var data = pcm.ToArray();
        var wav = new MemoryStream();
        var h = new BinaryWriter(wav);
        h.Write(new[] { 'R', 'I', 'F', 'F' }); h.Write(36 + data.Length);
        h.Write(new[] { 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' }); h.Write(16);
        h.Write((short)1); h.Write((short)1); h.Write(Rate); h.Write(Rate * 2);
        h.Write((short)2); h.Write((short)16);
        h.Write(new[] { 'd', 'a', 't', 'a' }); h.Write(data.Length); h.Write(data);
        h.Flush();
        return wav.ToArray();
    }
}
"@

# Sons de fundo gerados por síntese (sem gravação nem música de terceiros), salvos como WAV em loop
Add-Type -TypeDefinition @"
using System;
using System.IO;
public static class PomoAmbient {
    const int Rate = 22050;

    public static void Generate(string kind, string path) {
        var r = new Random(42);
        float[] x;
        switch (kind) {
            case "Marrom":    x = Loop(Brown(r, Rate * 62), Rate * 2); break;
            case "Chuva":     x = Loop(Rain(r, Rate * 124), Rate * 4); break;
            case "Mar":       x = Loop(Sea(r, Rate * 76), Rate * 6); break;
            case "Minecraft": x = Loop(Savanna(r), Rate * 4); break;
            default: throw new ArgumentException(kind);
        }
        Save(x, path);
    }

    // ---------- ruídos ----------
    static float[] White(Random r, int n) { var x = new float[n]; for (int i = 0; i < n; i++) x[i] = (float)(r.NextDouble() * 2 - 1); return x; }

    static float[] Brown(Random r, int n) {
        var x = new float[n]; double b = 0;
        for (int i = 0; i < n; i++) { b = (b + 0.02 * (r.NextDouble() * 2 - 1)) / 1.02; x[i] = (float)b; }
        return x;
    }

    static float[] Pink(Random r, int n) {   // filtro de Paul Kellet
        var x = new float[n]; double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
        for (int i = 0; i < n; i++) {
            double w = r.NextDouble() * 2 - 1;
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759;
            b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856;
            b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980;
            x[i] = (float)((b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11); b6 = w * 0.115926;
        }
        return x;
    }

    static void HighPass(float[] x, double hz) {
        double a = Math.Exp(-2 * Math.PI * hz / Rate), y = 0, prev = 0;
        for (int i = 0; i < x.Length; i++) { y = a * (y + x[i] - prev); prev = x[i]; x[i] = (float)y; }
    }

    static void LowPass(float[] x, double hz) {
        double a = 1 - Math.Exp(-2 * Math.PI * hz / Rate), y = 0;
        for (int i = 0; i < x.Length; i++) { y += a * (x[i] - y); x[i] = (float)y; }
    }

    // Chuva de noite com trovões: 3 camadas de água + trovoadas distantes
    static float[] Rain(Random r, int n) {
        // 1) chiado de fundo, baixo e abafado (a "massa" da chuva ao longe)
        var bed = Pink(r, n); HighPass(bed, 300); LowPass(bed, 4000);
        for (int i = 0; i < n; i++) bed[i] *= (float)(1 + 0.12 * Math.Sin(2 * Math.PI * i / (Rate * 19.0)));

        // 2) chuvisco denso: centenas de estalinhos de ruído por segundo (gotas em folhas, telhado, chão)
        var patter = new float[n];
        double t = 0;
        while (true) {
            t += -Math.Log(1 - r.NextDouble()) * Rate / 450.0;
            int p = (int)t; if (p >= n) break;
            int len = (int)(Rate * (0.0015 + r.NextDouble() * 0.004));
            double amp = 0.15 + Math.Pow(r.NextDouble(), 4) * 0.85;
            for (int s = 0; s < len && p + s < n; s++)
                patter[p + s] += (float)(amp * Math.Exp(-5.0 * s / len) * (r.NextDouble() * 2 - 1));
        }
        HighPass(patter, 900); LowPass(patter, 7500);

        // 3) gotas em poças: "ploc" curto com o tom subindo, como bolha na água
        var plops = new float[n];
        t = 0;
        while (true) {
            t += -Math.Log(1 - r.NextDouble()) * Rate / 9.0;
            int p = (int)t; if (p >= n) break;
            double f0 = 900 + r.NextDouble() * 2100, amp = 0.3 + Math.Pow(r.NextDouble(), 3) * 0.7, ph = 0;
            int len = (int)(Rate * (0.012 + r.NextDouble() * 0.025));
            for (int s = 0; s < len && p + s < n; s++) {
                double q = (double)s / len, f = f0 * (1 + 0.6 * q);
                ph += 2 * Math.PI * f / Rate;
                plops[p + s] += (float)(amp * Math.Exp(-4.5 * q) * Math.Min(1, s / (Rate * 0.001)) * Math.Sin(ph));
            }
        }

        // 4) trovões distantes a cada 25-50 s: ronco grave que rola por 6-12 s
        var thunder = new float[n];
        int fade = Rate * 4;
        double tt = Rate * (6 + r.NextDouble() * 10);
        while (tt < n - fade - Rate * 14) {
            Thunder(r, thunder, (int)tt);
            tt += Rate * (25 + r.NextDouble() * 25);
        }

        Normalize(bed, 0.030); Normalize(patter, 0.045); Normalize(plops, 0.012);
        var x = new float[n];
        for (int i = 0; i < n; i++) x[i] = bed[i] + patter[i] + plops[i] + thunder[i];
        return x;
    }

    static void Thunder(Random r, float[] x, int start) {
        double dur = 6 + r.NextDouble() * 6; int n = (int)(Rate * dur);
        if (start + n > x.Length) n = x.Length - start;
        var rumble = Brown(r, n); LowPass(rumble, 180); LowPass(rumble, 180);
        var grit = Brown(r, n); LowPass(grit, 700); HighPass(grit, 120);
        Normalize(rumble, 1.0); Normalize(grit, 1.0);
        // várias "ondas" de estrondo nos primeiros segundos, cada uma decaindo
        int bursts = 3 + r.Next(3);
        var off = new double[bursts]; var amp = new double[bursts]; var dec = new double[bursts];
        for (int b = 0; b < bursts; b++) {
            off[b] = b == 0 ? 0 : r.NextDouble() * dur * 0.45;
            amp[b] = b == 0 ? 1 : 0.4 + r.NextDouble() * 0.6;
            dec[b] = 0.8 + r.NextDouble() * 1.6;
        }
        double level = 0.13 + r.NextDouble() * 0.09;   // trovão longe, não assusta
        for (int s = 0; s < n; s++) {
            double sec = (double)s / Rate, env = 0;
            for (int b = 0; b < bursts; b++) {
                double d = sec - off[b];
                if (d > 0) env += amp[b] * Math.Min(1, d / 0.35) * Math.Exp(-d / dec[b]);
            }
            env *= Math.Min(1, (dur - sec) / 1.5);   // some devagar no fim
            x[start + s] += (float)(level * env * (rumble[s] * 0.85 + grit[s] * 0.25));
        }
    }

    // Mar: ondas de 7 a 12 s que sobem devagar, quebram e recuam
    static float[] Sea(Random r, int n) {
        var low = Brown(r, n); var hiss = Pink(r, n); LowPass(hiss, 2500);
        var env = new double[n];
        int t = 0;
        while (t < n) {
            int len = (int)(Rate * (7 + r.NextDouble() * 5)); double peak = 0.7 + r.NextDouble() * 0.3;
            for (int s = 0; s < len && t + s < n; s++) {
                double p = (double)s / len;
                env[t + s] = peak * (p < 0.55 ? Math.Pow(Math.Sin(Math.PI / 2 * p / 0.55), 2) : Math.Exp(-(p - 0.55) * 5.5));
            }
            t += len;
        }
        double e = 0; var x = new float[n];
        for (int i = 0; i < n; i++) {
            e += (env[i] - e) * 0.0004;                                   // suaviza as emendas entre ondas
            x[i] = (float)(low[i] * 3.0 * (0.25 + 0.75 * e) + hiss[i] * 0.55 * e * e);
        }
        return x;
    }

    // ---------- piano calmo, notas esparsas sobre acordes (atmosfera de jogo) ----------
    static double Hz(int midi) { return 440.0 * Math.Pow(2, (midi - 69) / 12.0); }

    // Nota de piano: 6 harmônicos que decaem, calculados por rotação (sem seno/exp por amostra)
    static void Note(float[] x, int start, int midi, double amp, double dur) {
        const int H = 6;
        double f = Hz(midi); int n = (int)(dur * Rate), attack = Rate * 5 / 1000;
        var c = new double[H]; var sn = new double[H]; var re = new double[H]; var im = new double[H];
        var g = new double[H]; var d = new double[H];
        for (int h = 0; h < H; h++) {
            int k = h + 1;
            double w = 2 * Math.PI * f * k * (1 + 0.0003 * k * k) / Rate;
            c[h] = Math.Cos(w); sn[h] = Math.Sin(w); re[h] = 1; im[h] = 0;
            g[h] = Math.Pow(0.5, h); d[h] = Math.Exp(-(1.2 + 0.9 * k) / Rate);
        }
        for (int s = 0; s < n && start + s < x.Length; s++) {
            double v = 0;
            for (int h = 0; h < H; h++) {
                v += g[h] * im[h];
                double nr = re[h] * c[h] - im[h] * sn[h];
                im[h] = re[h] * sn[h] + im[h] * c[h]; re[h] = nr; g[h] *= d[h];
            }
            x[start + s] += (float)(amp * Math.Min(1.0, (double)s / attack) * v);
        }
    }

    // ---------- Minecraft, savana: vento com rajadas, pássaros esparsos e o piano que vem e vai ----------
    static float[] Savanna(Random r) {
        var piano = Piano(r);                      // ~100 s de piano...
        int n = piano.Length * 2;                  // ...seguidos de ~100 s só de natureza, como no jogo
        var wind = Wind(r, n); var birds = Birds(r, n);
        Normalize(wind, 0.035); Normalize(piano, 0.09);   // vento só de fundo
        var x = new float[n];
        for (int i = 0; i < n; i++) x[i] = wind[i] + birds[i] + (i < piano.Length ? piano[i] : 0);
        return x;
    }

    static void Normalize(float[] x, double rms) {
        double sum = 0; int cnt = 0;
        for (int i = 0; i < x.Length; i += 7) { sum += x[i] * x[i]; cnt++; }
        double k = rms / Math.Sqrt(sum / cnt + 1e-12);
        for (int i = 0; i < x.Length; i++) x[i] = (float)(x[i] * k);
    }

    // Vento: ruído num filtro passa-banda cuja frequência e volume sobem e descem com as rajadas
    static float[] Wind(Random r, int n) {
        var x = new float[n]; var rumble = Brown(r, n);
        double gust = 0.5, target = 0.5, low = 0, band = 0;
        int next = 0;
        for (int i = 0; i < n; i++) {
            if (i >= next) { target = 0.15 + r.NextDouble() * 0.85; next = i + (int)(Rate * (2.5 + r.NextDouble() * 4)); }
            gust += (target - gust) * (1.0 / (Rate * 1.6));
            double fc = 220 + 650 * gust, f1 = 2 * Math.Sin(Math.PI * fc / Rate);
            double input = r.NextDouble() * 2 - 1;
            double high = input - low - 1.1 * band;
            band += f1 * high; low += f1 * band;
            x[i] = (float)(band * (0.25 + 0.75 * gust) + rumble[i] * 0.6);
        }
        return x;
    }

    // Pássaros: grupos de 2 a 5 trinados curtos, de tempos em tempos
    static float[] Birds(Random r, int n) {
        var x = new float[n];
        int t = (int)(Rate * (2 + r.NextDouble() * 4));
        while (t < n) {
            int chirps = 2 + r.Next(4);
            double baseF = 2600 + r.NextDouble() * 1900, sweep = (r.NextDouble() < 0.5 ? 1 : -1) * (500 + r.NextDouble() * 900);
            double amp = 0.025 + r.NextDouble() * 0.035;
            int pos = t;
            for (int c = 0; c < chirps && pos < n; c++) {
                int len = (int)(Rate * (0.05 + r.NextDouble() * 0.07)); double ph = 0;
                for (int s = 0; s < len && pos + s < n; s++) {
                    double p = (double)s / len, f = baseF + sweep * p;
                    ph += 2 * Math.PI * f / Rate;
                    double env = Math.Sin(Math.PI * p); x[pos + s] += (float)(amp * env * env * Math.Sin(ph));
                }
                pos += len + (int)(Rate * (0.04 + r.NextDouble() * 0.09));
            }
            t = pos + (int)(Rate * (3 + r.NextDouble() * 10));
        }
        return x;
    }

    static float[] Piano(Random r) {
        int[][] chords = {
            new[] { 48, 60, 64, 67, 71, 72, 76 },   // Cmaj7
            new[] { 45, 57, 60, 64, 67, 69, 72 },   // Am7
            new[] { 41, 57, 60, 65, 69, 72, 76 },   // Fmaj7
            new[] { 43, 59, 62, 67, 71, 74, 79 },   // G6
            new[] { 40, 59, 64, 67, 71, 76 },       // Em7
            new[] { 41, 60, 65, 69, 72, 77 }        // F
        };
        int[] order = { 0, 1, 2, 3, 0, 4, 5, 3, 1, 2, 0, 3 };
        double chordLen = 8.0; int total = (int)(Rate * (order.Length * chordLen + 4));
        var dry = new float[total];
        for (int c = 0; c < order.Length; c++) {
            var ch = chords[order[c]]; double t0 = c * chordLen;
            Note(dry, (int)(t0 * Rate), ch[0], 0.30, 6);
            double t = t0 + 0.5 + r.NextDouble();
            while (t < t0 + chordLen - 0.8) {
                double roll = r.NextDouble();
                if (roll < 0.62) Note(dry, (int)(t * Rate), ch[1 + r.Next(ch.Length - 1)], 0.20 + r.NextDouble() * 0.12, 4);
                else if (roll < 0.85) {
                    int a = 1 + r.Next(ch.Length - 2);
                    Note(dry, (int)(t * Rate), ch[a], 0.17, 4); Note(dry, (int)((t + 0.03) * Rate), ch[a + 1], 0.15, 4);
                }
                t += 1.2 + r.NextDouble() * 1.9;
            }
        }
        return Reverb(dry);
    }

    static float[] Reverb(float[] x) {   // Schroeder: 4 combs + 2 allpass
        int[] cd = { 1116, 1188, 1277, 1356 }; var wet = new float[x.Length];
        foreach (int d in cd) {
            var buf = new float[d]; int p = 0; float lp = 0;
            for (int i = 0; i < x.Length; i++) {
                float o = buf[p]; lp = o * 0.6f + lp * 0.4f;
                buf[p] = x[i] + lp * 0.82f; p = (p + 1) % d; wet[i] += o * 0.25f;
            }
        }
        foreach (int d in new[] { 556, 225 }) {
            var buf = new float[d]; int p = 0;
            for (int i = 0; i < x.Length; i++) {
                float b = buf[p], o = -wet[i] + b; buf[p] = wet[i] + b * 0.5f; p = (p + 1) % d; wet[i] = o;
            }
        }
        var y = new float[x.Length];
        for (int i = 0; i < x.Length; i++) y[i] = x[i] * 0.75f + wet[i] * 0.45f;
        return y;
    }

    // ---------- loop sem emenda e gravação ----------
    static float[] Loop(float[] x, int fade) {
        int n = x.Length - fade; var y = new float[n];
        Array.Copy(x, y, n);
        for (int i = 0; i < fade; i++) {
            double t = (double)i / fade;
            y[i] = (float)(x[i] * Math.Sqrt(t) + x[n + i] * Math.Sqrt(1 - t));
        }
        return y;
    }

    static void Save(float[] x, string path) {
        float peak = 1e-6f; foreach (var v in x) peak = Math.Max(peak, Math.Abs(v));
        float g = 0.85f / peak; int bytes = x.Length * 2;
        using (var fs = File.Create(path))
        using (var h = new BinaryWriter(fs)) {
            h.Write(new[] { 'R', 'I', 'F', 'F' }); h.Write(36 + bytes);
            h.Write(new[] { 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' }); h.Write(16);
            h.Write((short)1); h.Write((short)1); h.Write(Rate); h.Write(Rate * 2);
            h.Write((short)2); h.Write((short)16);
            h.Write(new[] { 'd', 'a', 't', 'a' }); h.Write(bytes);
            foreach (var v in x) h.Write((short)(Math.Max(-1f, Math.Min(1f, v * g)) * 32767));
        }
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
$cfg = [ordered]@{ FocusMin = 25; ShortMin = 5; LongMin = 15; X = $null; Y = $null; Visible = $true; Docked = $true; Alarm = $true; TickTock = $true
                  Ambient = $null; Volume = 35; KeepAwake = $false
                  FocusQuiet = $true; QuietApplied = $false; OrigBadges = 1; OrigFlashing = 1; DndByUs = $false }
if (Test-Path $cfgFile) {
    try {
        $saved = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) { if ($null -ne $saved.$k) { $cfg[$k] = $saved.$k } }
    } catch {}
}
# Versões antigas só tinham liga/desliga do tic-tac
if (-not $cfg.Ambient) { $cfg.Ambient = if ($cfg.TickTock -eq $false) { 'Nenhum' } else { 'TicTac' } }
$cfg.Remove('TickTock')

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
    LastSec = -1; MuteUntil = [datetime]::MinValue
    AmbSrc = ''; AmbPlaying = $false; PreviewUntil = [datetime]::MinValue
    TextOn = [Drawing.Color]::FromArgb(240, 240, 240); TextOff = [Drawing.Color]::FromArgb(140, 140, 148)
}

function New-Sound([double[]]$notes) {
    $ms = New-Object IO.MemoryStream(, [PomoSound]::Wav($notes))
    $p = New-Object System.Media.SoundPlayer($ms)
    $p.Load(); $p
}
$SndTick  = New-Sound @(2600, 30, 0.3)
$SndTock  = New-Sound @(1900, 30, 0.3)
$SndAlarm = New-Sound @(880, 160, 0.6, 0, 50, 0, 1175, 160, 0.6, 0, 50, 0, 1568, 320, 0.6, 0, 300, 0,
                        880, 160, 0.6, 0, 50, 0, 1175, 160, 0.6, 0, 50, 0, 1568, 320, 0.6)
$AlarmLength = [timespan]::FromMilliseconds(2100)

# Tic-tac a cada segundo do contador; fica mudo enquanto o alarme toca (o SoundPlayer corta o som anterior)
function Invoke-TickTock {
    if (-not $S.Running) { $S.LastSec = -1; return }
    $sec = [int][math]::Ceiling((Get-Remaining).TotalSeconds)
    if ($sec -eq $S.LastSec) { return }
    $S.LastSec = $sec
    if ($cfg.Ambient -eq 'TicTac' -and $S.Phase -eq 'Foco' -and $sec -gt 0 -and [datetime]::Now -ge $S.MuteUntil) {
        if ($sec % 2 -eq 0) { $SndTick.Play() } else { $SndTock.Play() }
    }
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
    $S.PreviewUntil = [datetime]::MinValue
    Update-Ambient
    Update-View
}

# ---------- Som de fundo (toca só com o timer rodando) ----------
$Ambients = [ordered]@{
    'Nenhum' = 'Nenhum'; 'TicTac' = 'Tic-tac'
    'Minecraft' = 'Minecraft (savana: vento, pássaros e piano)'; 'Chuva' = 'Chuva'; 'Marrom' = 'Ruído marrom'; 'Mar' = 'Mar'
    'ClaudeFM' = 'Claude FM (lo-fi)'
}

# ---------- Claude FM: a rádio lo-fi da Anthropic (live do YouTube, a mesma do /radio do Claude Code) ----------
# Toca dentro do Pomodoro com o player oficial do YouTube, numa janela WebView2 (motor do Edge,
# já instalado no Windows) posicionada fora da tela. As DLLs do WebView2 ficam em lib\.
# clau.de/radio sempre redireciona para a live atual (o link da live muda quando ela reinicia).
$ClaudeFmUrl = 'https://clau.de/radio'
$LibDir = Join-Path $PSScriptRoot 'lib'
$FM = @{ Stage = 0; Form = $null; WV = $null; Task = $null; Env = $null; Sent = ''; Failed = $false }
# Stage: 0 = parado, 1 = criando ambiente, 2 = criando o navegador, 3 = pronto para comandos

$ClaudeFmPage = @'
<!doctype html><html><body style="margin:0;background:#000"><div id="p"></div>
<script>
var player, ready = false, want = { play: false, vol: 35 }, wasPaused = false;
var tag = document.createElement('script'); tag.src = 'https://www.youtube.com/iframe_api'; document.head.appendChild(tag);
function onYouTubeIframeAPIReady() {
  player = new YT.Player('p', { width: 320, height: 180, videoId: '__VID__',
    playerVars: { autoplay: 0, controls: 0, playsinline: 1 },
    events: { onReady: function () { ready = true; apply(); },
              onError: function (e) { chrome.webview.postMessage('error:' + e.data); } } });
}
function apply() {
  if (!ready) return;
  player.setVolume(want.vol);
  var st = player.getPlayerState();
  if (want.play) {
    if (st !== 1 && st !== 3) {
      if (wasPaused) { player.seekTo(player.getDuration(), true); wasPaused = false; }   // volta ao "ao vivo"
      player.playVideo();
    }
  } else if (st === 1 || st === 3) { player.pauseVideo(); wasPaused = true; }
}
function setWant(play, vol) { want.play = play; want.vol = vol; apply(); return 'ok'; }
setInterval(apply, 2000);   // insiste até tocar (o player às vezes ignora o primeiro play)
</script></body></html>
'@

function Get-ClaudeFmVideoId {
    $req = [Net.HttpWebRequest]::Create($ClaudeFmUrl); $req.AllowAutoRedirect = $false; $req.Timeout = 10000
    $resp = $req.GetResponse()
    try { $loc = $resp.Headers['Location'] } finally { $resp.Close() }
    if ($loc -match '[?&]v=([\w-]{11})') { return $Matches[1] }
    throw "link inesperado: $loc"
}

function Stop-ClaudeFM([string]$why) {
    if ($FM.Form) { try { $FM.Form.Dispose() } catch {} }
    $FM.Stage = 0; $FM.Form = $null; $FM.WV = $null; $FM.Task = $null; $FM.Sent = ''
    if ($why) {
        $FM.Failed = $true
        $tray.ShowBalloonTip(8000, 'Pomodoro', "Não consegui tocar o Claude FM: $why. Escolha o Claude FM de novo para tentar outra vez.", [Windows.Forms.ToolTipIcon]::Warning)
    }
}

function Start-ClaudeFM {
    try {
        Add-Type -Path (Join-Path $LibDir 'Microsoft.Web.WebView2.Core.dll')
        Add-Type -Path (Join-Path $LibDir 'Microsoft.Web.WebView2.WinForms.dll')
    } catch { Stop-ClaudeFM 'faltam os arquivos do WebView2 na pasta lib'; return }
    try { $vid = Get-ClaudeFmVideoId } catch { Stop-ClaudeFM 'sem acesso ao link da rádio (internet ou rede bloqueando)'; return }

    $site = Join-Path $cfgDir 'claudefm'
    New-Item -ItemType Directory -Force $site | Out-Null
    $ClaudeFmPage.Replace('__VID__', $vid) | Set-Content (Join-Path $site 'index.html') -Encoding UTF8

    # Janela fora da tela (precisa existir para o player tocar), fora do Alt+Tab
    $f = New-Object Windows.Forms.Form
    $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'
    $f.Location = New-Object Drawing.Point(-32000, -32000); $f.Size = New-Object Drawing.Size(320, 180)
    $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $wv.Dock = 'Fill'; $f.Controls.Add($wv)
    $f.Show()
    $ex = [PomoNative]::GetWindowLong($f.Handle, -20)
    [void][PomoNative]::SetWindowLong($f.Handle, -20, (($ex -bor 0x80) -band (-bnot 0x40000)))
    $FM.Form = $f; $FM.WV = $wv

    # O construtor das opções só tem parâmetros opcionais, que o PowerShell 5.1 não preenche sozinho
    $ctor = [Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions].GetConstructors() |
            Sort-Object { $_.GetParameters().Count } | Select-Object -First 1
    $opts = $ctor.Invoke(@($ctor.GetParameters() | ForEach-Object { $_.DefaultValue }))
    $opts.AdditionalBrowserArguments = '--autoplay-policy=no-user-gesture-required'
    $FM.Task = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, (Join-Path $cfgDir 'webview2'), $opts)
    $FM.Stage = 1
}

# Avança a criação sem travar a tela (chamado a cada tick)
function Step-ClaudeFM {
    if ($FM.Stage -in 1, 2 -and $FM.Task.IsCompleted) {
        if ($FM.Task.IsFaulted) { Stop-ClaudeFM 'o WebView2 não abriu'; return }
        if ($FM.Stage -eq 1) {
            $FM.Task = $FM.WV.EnsureCoreWebView2Async($FM.Task.Result)
            $FM.Stage = 2
        } else {
            $core = $FM.WV.CoreWebView2
            $core.SetVirtualHostNameToFolderMapping('pomodoro.local', (Join-Path $cfgDir 'claudefm'),
                [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
            $core.add_WebMessageReceived({
                param($sender, $e)
                $msg = $e.TryGetWebMessageAsString()
                if ($msg -like 'error:*') { Stop-ClaudeFM "o YouTube recusou a live (código $($msg.Substring(6)))" }
            })
            $core.Navigate('https://pomodoro.local/index.html')
            $FM.Stage = 3; $FM.Sent = ''
        }
    }
}

function Set-ClaudeFM([bool]$play) {
    if ($play -and $FM.Stage -eq 0 -and -not $FM.Failed) { Start-ClaudeFM }
    Step-ClaudeFM
    if ($FM.Stage -ne 3) { return }
    $key = "$play|$([int]$cfg.Volume)"
    if ($key -ne $FM.Sent) {
        [void]$FM.WV.CoreWebView2.ExecuteScriptAsync("setWant($($play.ToString().ToLower()), $([int]$cfg.Volume))")
        $FM.Sent = $key
    }
}
$GeneratedSounds = @('Minecraft', 'Chuva', 'Marrom', 'Mar')
$SoundDir = Join-Path $cfgDir 'sons'
$SoundVersion = 'v4'   # mudar quando a síntese mudar, para regerar os arquivos
if (-not $Ambients.Contains([string]$cfg.Ambient)) { $cfg.Ambient = 'TicTac' }   # ex.: rádios, que saíram

$wmp = $null
try {
    $wmp = New-Object -ComObject WMPlayer.OCX
    $wmp.settings.autoStart = $false
    $wmp.settings.volume = [int]$cfg.Volume
} catch {}

# Caminho do WAV gerado (cria na primeira vez)
function Get-AmbientSource([string]$id) {
    if ($GeneratedSounds -contains $id) {
        $p = Join-Path $SoundDir "$id-$SoundVersion.wav"
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Force $SoundDir | Out-Null
            [Windows.Forms.Cursor]::Current = [Windows.Forms.Cursors]::WaitCursor
            [PomoAmbient]::Generate($id, $p)
            [Windows.Forms.Cursor]::Current = [Windows.Forms.Cursors]::Default
        }
        return $p
    }
    return $null
}

function Update-Ambient {
    $id = [string]$cfg.Ambient
    $now = [datetime]::Now
    # Só no foco: nas pausas fica tudo em silêncio (a amostra ao escolher um som toca sempre)
    $active = (($S.Running -and $S.Phase -eq 'Foco') -or $now -lt $S.PreviewUntil) -and $now -ge $S.MuteUntil
    Set-ClaudeFM ($active -and $id -eq 'ClaudeFM')

    if ($null -eq $wmp) { return }
    $want = $active -and ($GeneratedSounds -contains $id)

    if (-not $want) {
        if ($S.AmbPlaying) { $wmp.controls.pause(); $S.AmbPlaying = $false }
        return
    }
    $src = Get-AmbientSource $id
    if ($S.AmbSrc -ne $src) {
        $wmp.controls.stop()
        $wmp.URL = $src
        $wmp.settings.setMode('loop', $true)
        $S.AmbSrc = $src
    }
    if (-not $S.AmbPlaying) { $wmp.controls.play(); $S.AmbPlaying = $true }
}

function Set-Ambient([string]$id) {
    $cfg.Ambient = $id
    if ($null -ne $wmp) { $wmp.controls.stop() }
    $S.AmbPlaying = $false; $S.AmbSrc = ''
    if ($GeneratedSounds -contains $id) { [void](Get-AmbientSource $id) }
    # Pausado: toca uma amostra curta para a pessoa ouvir o que escolheu
    # (o Claude FM leva uns 5-8 s para conectar, então a amostra dele é maior)
    $FM.Failed = $false
    if (-not $S.Running) { $S.PreviewUntil = [datetime]::Now.AddSeconds($(if ($id -eq 'ClaudeFM') { 15 } else { 5 })) }
    Sync-AmbientChecks; Save-Config; Update-Ambient
}

function Sync-AmbientChecks {
    foreach ($o in $miAmb.DropDownItems) {
        if ($o.Tag -is [string] -and $Ambients.Contains($o.Tag)) { $o.Checked = ($o.Tag -eq $cfg.Ambient) }
    }
    foreach ($o in $miVol.DropDownItems) { $o.Checked = ([int]$o.Tag -eq [int]$cfg.Volume) }
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
    # Fim de fase pelo timer sempre pausa: a próxima só começa quando iniciada manualmente
    $run = if ($fromTimer) { $false } else { $S.Running }
    $S.Running = $run
    if ($run) { $S.EndAt = [datetime]::Now + $S.Remaining }
    # Desliga o "Não incomodar" ANTES do aviso de fim de fase, senão o próprio aviso fica escondido
    Update-FocusQuiet

    if ($fromTimer) {
        $min = [int]$S.Remaining.TotalMinutes
        $msg = if ($next -eq 'Foco') { "Pausa encerrada. Hora de focar por $min min." }
               else { "Foco concluído ($($S.Done) hoje). $next de $min min." }
        if (-not $run) { $msg += ' Clique no ícone para iniciar.' }
        if ($cfg.Alarm) {
            $SndAlarm.Play()
            $S.MuteUntil = [datetime]::Now + $AlarmLength
        } else {
            [System.Media.SystemSounds]::Exclamation.Play()
        }
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
    $awake = if ($cfg.KeepAwake) { ' · Cafeína' } else { '' }
    $tray.Text = "Pomodoro · $($S.Phase) $txt$paused$awake"

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

# Cor da barra pelo tema do Windows (claro/escuro/cor de destaque). Não lê pixels da tela:
# com transparência ligada a barra mostra o que está atrás, e a cor mudava com o conteúdo.
function Get-TaskbarColor {
    $pers = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    if ($pers -and $pers.ColorPrevalence -eq 1) {
        $pal = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -ErrorAction SilentlyContinue).AccentPalette
        if ($pal -and $pal.Length -ge 24) { return [Drawing.Color]::FromArgb($pal[20], $pal[21], $pal[22]) }   # tom escuro do destaque
    }
    if ($pers -and $pers.SystemUsesLightTheme -eq 1) { return [Drawing.Color]::FromArgb(243, 243, 243) }
    return [Drawing.Color]::FromArgb(31, 31, 31)
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

    $bg = Get-TaskbarColor
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

# Abre o submenu para o lado que cabe na MESMA tela (senão vai para o outro monitor)
function Add-SmartDropDown($item) {
    $item.add_DropDownOpening({
        param($sender, $e)
        $owner = $sender.Owner.Bounds
        $wa = [Windows.Forms.Screen]::FromRectangle($owner).WorkingArea
        $need = $sender.DropDown.PreferredSize.Width
        $sender.DropDownDirection = if ($owner.Right + $need -gt $wa.Right) { 'Left' } else { 'Right' }
    })
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
    Add-SmartDropDown $parent
    Sync-DurationChecks $parent $key
    [void]$menu.Items.Add($parent)
}
Add-DurationMenu 'Duração do foco'        'FocusMin' @(15, 20, 25, 30, 45, 50)
Add-DurationMenu 'Duração da pausa'       'ShortMin' @(3, 5, 10)
Add-DurationMenu 'Duração da pausa longa' 'LongMin'  @(15, 20, 30)

$miAlarm = $menu.Items.Add('Alarme sonoro ao fim da fase')
$miAlarm.CheckOnClick = $true; $miAlarm.Checked = [bool]$cfg.Alarm
$miAlarm.add_Click({ $cfg.Alarm = $miAlarm.Checked; Save-Config })

$miAmb = New-Object Windows.Forms.ToolStripMenuItem('Som de fundo')
foreach ($k in $Ambients.Keys) {
    if ($k -in 'Minecraft', 'ClaudeFM') { [void]$miAmb.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator)) }
    $it = New-Object Windows.Forms.ToolStripMenuItem($Ambients[$k])
    $it.Tag = $k
    $it.add_Click({ param($sender, $e) Set-Ambient $sender.Tag })
    [void]$miAmb.DropDownItems.Add($it)
}
[void]$miAmb.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
$miVol = New-Object Windows.Forms.ToolStripMenuItem('Volume')
foreach ($v in @(@('Baixo', 15), @('Médio', 35), @('Alto', 60), @('Máximo', 100))) {
    $it = New-Object Windows.Forms.ToolStripMenuItem($v[0])
    $it.Tag = $v[1]
    $it.add_Click({
        param($sender, $e)
        $cfg.Volume = [int]$sender.Tag
        if ($null -ne $wmp) { $wmp.settings.volume = $cfg.Volume }
        if (-not $S.Running) { $S.PreviewUntil = [datetime]::Now.AddSeconds(4); Update-Ambient }
        Sync-AmbientChecks; Save-Config
    })
    [void]$miVol.DropDownItems.Add($it)
}
Add-SmartDropDown $miVol
[void]$miAmb.DropDownItems.Add($miVol)
if ($null -eq $wmp) {   # sem Windows Media Player: os sons gerados não tocam
    foreach ($o in $miAmb.DropDownItems) { if ($o.Tag -is [string] -and $o.Tag -in $GeneratedSounds) { $o.Enabled = $false } }
    $miVol.Enabled = $false
}
Add-SmartDropDown $miAmb
[void]$menu.Items.Add($miAmb)
Sync-AmbientChecks

$miShow = $menu.Items.Add('Mostrar contador na tela')
$miShow.CheckOnClick = $true; $miShow.Checked = [bool]$cfg.Visible
$miShow.add_Click({ Update-Visibility; Save-Config })

$miDock = $menu.Items.Add('Fixar na barra de tarefas')
$miDock.CheckOnClick = $true; $miDock.Checked = [bool]$cfg.Docked
$miDock.add_Click({ Set-Layout; Save-Config })
Add-Sep

# ---------- Cafeína: manter o PC ativo (como o app Caffeine) ----------
# 1) Pede ao Windows para não dormir nem apagar a tela.
# 2) Com 1 min sem uso, "aperta" F15 (tecla que não faz nada) para não bloquear a tela
#    nem ficar "Ausente" no Teams. Enquanto a pessoa usa o PC, nenhuma tecla é enviada.
$ES_CONTINUOUS = [uint32]'0x80000000'; $ES_SYSTEM = [uint32]1; $ES_DISPLAY = [uint32]2
$S.LastNudge = [datetime]::MinValue

function Set-KeepAwake([bool]$on) {
    $cfg.KeepAwake = $on
    $flags = if ($on) { $ES_CONTINUOUS -bor $ES_SYSTEM -bor $ES_DISPLAY } else { $ES_CONTINUOUS }
    [void][PomoNative]::SetThreadExecutionState($flags)
    $miCaffeine.Checked = $on
    Update-View
}

function Invoke-KeepAwakeNudge {
    if (-not $cfg.KeepAwake) { return }
    if ([PomoNative]::IdleMs() -ge 59000 -and ([datetime]::Now - $S.LastNudge).TotalSeconds -ge 59) {
        [PomoNative]::keybd_event(0x7E, 0, 0, [UIntPtr]::Zero)   # F15 desce
        [PomoNative]::keybd_event(0x7E, 0, 2, [UIntPtr]::Zero)   # F15 sobe
        $S.LastNudge = [datetime]::Now
    }
}

$miCaffeine = $menu.Items.Add('Cafeína')
$miCaffeine.add_Click({ Set-KeepAwake (-not $cfg.KeepAwake); Save-Config })

# ---------- Sem distrações no foco ----------
# Durante o foco (timer rodando), esconde os contadores dos apps na barra (ex.: mensagens não lidas
# do Teams/Outlook) e o piscar de ícones pedindo atenção, como as opções da sessão de foco do Windows.
# Nas pausas, com o timer parado ou ao sair, volta como estava. Os valores originais ficam salvos na
# config para serem restaurados mesmo se o Pomodoro for fechado à força.
$TaskbarKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$S.QuietOn = $false

# "Não incomodar" do Windows. Não há API pública liberada (a de sessão de foco é restrita pela
# Microsoft), então o Pomodoro usa o próprio botão da central de notificações: abre o painel (Win+N),
# acha o botão pelo ID "DoNotDisturbButton" via UI Automation, liga/desliga e fecha (Esc).
# O painel pisca na tela por ~1 s. Retorna o estado anterior ('On'/'Off') ou $null se não achou.
function Set-WindowsDnd([bool]$on) {
    try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes } catch { return $null }
    $A = [Windows.Automation.AutomationElement]
    $press = { param([byte[]]$keys)
        foreach ($k in $keys) { [PomoNative]::keybd_event($k, 0, 0, [UIntPtr]::Zero) }
        [array]::Reverse($keys); foreach ($k in $keys) { [PomoNative]::keybd_event($k, 0, 2, [UIntPtr]::Zero) } }
    # Espera soltar Ctrl/Alt/Shift (ex.: logo depois do Ctrl+Alt+P), senão o Win+N vira outro atalho
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ([Windows.Forms.Control]::ModifierKeys -ne 'None' -and $sw.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 50 }
    & $press @(0x5B, 0x4E)   # Win+N
    $btn = $null; $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $btn -and $sw.ElapsedMilliseconds -lt 4000) {
        Start-Sleep -Milliseconds 150
        try {
            $f = $A::FocusedElement
            if ($f -and (Get-Process -Id $f.Current.ProcessId).Name -eq 'ShellExperienceHost') {
                $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
                $top = $f; $p = $walker.GetParent($top)
                while ($p -and -not $p.Equals($A::RootElement)) { $top = $p; $p = $walker.GetParent($top) }
                $btn = $top.FindFirst([Windows.Automation.TreeScope]::Descendants,
                    (New-Object Windows.Automation.PropertyCondition($A::AutomationIdProperty, 'DoNotDisturbButton')))
            }
        } catch {}
    }
    $before = $null
    if ($btn) {
        try {
            $tp = $btn.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
            $before = [string]$tp.Current.ToggleState
            if (($before -eq 'On') -ne $on) { $tp.Toggle(); Start-Sleep -Milliseconds 250 }
        } catch {}
    }
    & $press @(0x1B)         # Esc fecha o painel
    return $before
}

function Set-FocusQuiet([bool]$on) {
    # Não perturbe: liga no foco; no fim só desliga se foi o Pomodoro que ligou
    if ($on -and -not $cfg.DndByUs) {
        $before = Set-WindowsDnd $true
        if ($before -eq 'Off') { $cfg.DndByUs = $true; Save-Config }
    } elseif (-not $on -and $cfg.DndByUs) {
        [void](Set-WindowsDnd $false)
        $cfg.DndByUs = $false; Save-Config
    }
    try {
        if ($on) {
            if (-not $cfg.QuietApplied) {
                $cur = Get-ItemProperty $TaskbarKey
                $cfg.OrigBadges   = if ($null -ne $cur.TaskbarBadges)   { [int]$cur.TaskbarBadges }   else { 1 }
                $cfg.OrigFlashing = if ($null -ne $cur.TaskbarFlashing) { [int]$cur.TaskbarFlashing } else { 1 }
                $cfg.QuietApplied = $true
                Save-Config
            }
            Set-ItemProperty $TaskbarKey -Name TaskbarBadges -Value 0 -Type DWord
            Set-ItemProperty $TaskbarKey -Name TaskbarFlashing -Value 0 -Type DWord
        } elseif ($cfg.QuietApplied) {
            Set-ItemProperty $TaskbarKey -Name TaskbarBadges -Value ([int]$cfg.OrigBadges) -Type DWord
            Set-ItemProperty $TaskbarKey -Name TaskbarFlashing -Value ([int]$cfg.OrigFlashing) -Type DWord
            $cfg.QuietApplied = $false
            Save-Config
        }
        [PomoNative]::NotifyTraySettings()
    } catch {}
    $S.QuietOn = $on
}

function Update-FocusQuiet {
    $want = [bool]$cfg.FocusQuiet -and $S.Running -and $S.Phase -eq 'Foco'
    if ($want -ne $S.QuietOn) { Set-FocusQuiet $want }
}

$miQuiet = $menu.Items.Add('Sem distrações no foco')
$miQuiet.CheckOnClick = $true; $miQuiet.Checked = [bool]$cfg.FocusQuiet
$miQuiet.ToolTipText = 'Durante o foco: liga o Não incomodar do Windows e esconde contadores e o piscar dos apps na barra'
$miQuiet.add_Click({ $cfg.FocusQuiet = $miQuiet.Checked; Save-Config; Update-FocusQuiet })
Add-Sep
$miExit = $menu.Items.Add('Sair')
$miExit.add_Click({
    Save-Config
    $timer.Stop(); $tickTimer.Stop()
    if ($null -ne $wmp) { $wmp.controls.stop() }
    Stop-ClaudeFM
    Set-FocusQuiet $false   # devolve contadores e piscar da barra
    [void][PomoNative]::SetThreadExecutionState($ES_CONTINUOUS)   # devolve o controle do sono ao Windows
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
    Update-Ambient
    Update-FocusQuiet
    Invoke-KeepAwakeNudge
    Update-View
})

# Timer leve e mais fino só para o tic-tac sair no ritmo certo (o principal roda a cada 500 ms)
$tickTimer = New-Object Windows.Forms.Timer
$tickTimer.Interval = 50
$tickTimer.add_Tick({ Invoke-TickTock })

Set-KeepAwake ([bool]$cfg.KeepAwake)
if ($cfg.QuietApplied -or $cfg.DndByUs) { Set-FocusQuiet $false }   # o Pomodoro foi fechado à força no meio de um foco
$form.Show(); $S.Shown = $true
Update-Visibility
$timer.Start()
$tickTimer.Start()

$ctx = New-Object Windows.Forms.ApplicationContext
[Windows.Forms.Application]::Run($ctx)

if ($S.IconHandle -ne [IntPtr]::Zero) { [void][PomoNative]::DestroyIcon($S.IconHandle) }
$mutex.ReleaseMutex()
