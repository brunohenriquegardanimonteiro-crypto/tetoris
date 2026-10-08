#Requires -Version 5.1
<#
    ============================================================================
     ROCK HERO  -  a Guitar-Hero-style rhythm game written entirely in PowerShell
    ============================================================================

     Every note of music, every drum hit and every chart is generated at runtime
     by an embedded C# synthesiser (compiled on the fly with Add-Type).  There
     are no sample files, no downloads and no dependencies: one .ps1 file,
     PowerShell 5.1+, Windows.

     USAGE
       .\rockhero.ps1                      play
       .\rockhero.ps1 -SelfTest            full automated test-suite
       .\rockhero.ps1 -ListSongs           print the song list and exit
       .\rockhero.ps1 -AudioDiag           report the sound card, the mix and the
                                           song clock (writes a text file too)
       .\rockhero.ps1 -DumpWav song3.wav -DumpSong 3
       .\rockhero.ps1 -Benchmark           render timing for every song

     KEYS
       1 2 3 4 5  (or A S D F G)   strike the five fret lanes
       SPACE                         Overdrive when the ROCK meter is full
       ESC                           pause / back
       ENTER                         confirm

     ABOUT THE MUSIC
       The riffs are ORIGINAL compositions written in the style of each band:
       a playable tribute, not a recording and not a transcription of
       copyrighted material.  Bands are credited so you know what you hear.
    ============================================================================
#>

[CmdletBinding()]
param(
    [switch] $SelfTest,
    [switch] $ListSongs,
    [switch] $Benchmark,
    [switch] $AudioDiag,
    [switch] $NoAudio,
    [switch] $Ascii,
    [ValidateRange(0, 100)]   [int]    $Volume    = 78,
    [ValidateRange(0.5, 2.0)] [double] $SpeedScale = 1.0,
    [string] $DumpWav = '',
    [ValidateRange(1, 99)]    [int]    $DumpSong  = 1
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ============================================================================
#  GLOBALS
# ============================================================================
$script:LANES   = 5
$script:LW      = 6              # characters per fret lane
$script:HWLEFT  = 6              # left margin of the highway
$script:HWTOP   = 3              # first highway row
$script:MINW    = 72
$script:MINH    = 24
$script:IDEALW  = 104
$script:IDEALH  = 40

$script:W      = 104
$script:H      = 40
$script:HITROW = 34
$script:PANELX = 41
$script:PANELW = 30

$script:Ansi     = $false
$script:Ascii    = $Ascii.IsPresent
$script:NoAudio  = $NoAudio.IsPresent
$script:Vol      = $Volume
$script:SpScale  = $SpeedScale
# missed notes you are allowed before the song is lost; 0 = never fail
$script:FailMisses = 16
$script:E        = [string][char]0x1B

# judgement windows (seconds)
$script:WPerfect = 0.048
$script:WGreat   = 0.090
$script:WGood    = 0.140
$script:WMiss    = 0.170

$script:BaseTravel = 1.15        # seconds a note is on screen before the line
$script:FrameMs    = 20

$script:G        = $null
$script:C        = $null
$script:Base     = $null
$script:BaseW    = 0
$script:BaseH    = 0
$script:Sfx      = $null
$script:Music    = $null
$script:Blips    = @{}
$script:AudioDiagText = $null
$script:DataDir  = $null
$script:ScoreFile = $null
$script:High     = @{}
$script:Catalog  = $null
$script:ForceMain = $false
$script:Quitting = $false

# ============================================================================
#  EMBEDDED C# ENGINE
# ============================================================================
$script:EngineSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace RockHero
{
    // ---------------------------------------------------------------------
    // Event model: one note/instrument hit, positioned in absolute seconds
    // (already includes the count-in lead-in offset).
    // ---------------------------------------------------------------------
    public class Ev
    {
        public double T;      // start time (s)
        public double Dur;    // sustain length (s)
        public int Kind;      // 0 guitar, 1 bass, 2 kick, 3 snare, 4 hat, 5 crash, 6 lead
        public int Midi;
        public double Vol;
        public int Third;     // semitone offset of the chord third (3 or 4), 0 = none
    }

    public class AudioOut
    {
        public byte[] Pcm;
        public double Seconds;
        public int Rate;
        public int Peak;       // max |sample|
        public double Rms;
        public int Voices;
        public bool HasNaN;
    }

    // ---------------------------------------------------------------------
    // Synth: additive-wavetable rock band (guitar / bass / drums / lead)
    // rendered entirely in-process. No external files needed.
    // ---------------------------------------------------------------------
    public static class Synth
    {
        public const int SR = 32000;
        public const int G = 0, B = 1, K = 2, S = 3, H = 4, C = 5, L = 6;

        const int TS = 2048;              // wavetable size
        static readonly float[] Gt = new float[TS + 1];   // distorted guitar
        static readonly float[] Sq = new float[TS + 1];   // lead
        static readonly float[] Sn = new float[TS + 1];   // bass / kick
        static bool tabs;

        static void InitTabs()
        {
            if (tabs) return;
            for (int i = 0; i < TS; i++)
            {
                double p = (double)i / TS;
                double s = 0.0;
                for (int h = 1; h <= 8; h++)
                {
                    double a = 1.0 / h;
                    if ((h & 1) == 0) a *= 0.55;      // slight odd emphasis
                    a *= Math.Exp(-h * 0.14);
                    s += a * Math.Sin(2.0 * Math.PI * p * h);
                }
                s *= 1.9;
                s = s / (1.0 + Math.Abs(s));          // valve-ish drive
                Gt[i] = (float)s;

                double q = 0.0;
                for (int h = 1; h <= 11; h += 2) q += Math.Sin(2.0 * Math.PI * p * h) / (h * 1.7);
                Sq[i] = (float)(q * 0.7);

                Sn[i] = (float)Math.Sin(2.0 * Math.PI * p);
            }
            Gt[TS] = Gt[0]; Sq[TS] = Sq[0]; Sn[TS] = Sn[0];
            tabs = true;
        }

        static float Wv(float[] t, double p)
        {
            double x = p * TS;
            int i = (int)x;
            float f = (float)(x - i);
            return t[i] + (t[i + 1] - t[i]) * f;
        }

        static double Nz(ref uint s)
        {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5;
            return (s & 0xFFFFFF) * (1.0 / 8388608.0) - 1.0;
        }

        class V
        {
            public int Kind;
            public double T0, Dur, Life, A;
            public double P1, P2, P3, F1, F2, F3;
            public double S1, S2, S3;
            public double Env, Dec, Atk, AtkInc;
            public uint Rs;
        }

        static double Semi(double ratio) { return Math.Pow(2.0, ratio / 12.0); }

        static V Mk(Ev e)
        {
            V v = new V();
            v.Kind = e.Kind; v.T0 = e.T; v.Dur = e.Dur; v.A = e.Vol;
            uint r = (uint)(e.Midi * 2654435761u + e.Kind * 40503u + 7919u);
            v.Rs = (r == 0) ? 1u : r;
            v.Env = 0.0; v.S1 = v.S2 = v.S3 = 0.0;
            v.P1 = v.P2 = v.P3 = 0.0;

            double f = 440.0 * Math.Pow(2.0, (e.Midi - 69) / 12.0);
            switch (e.Kind)
            {
                case G:
                    v.F1 = f;
                    v.F2 = f * 1.4983 * 1.004;                    // fifth, slightly detuned
                    v.F3 = (e.Third > 0) ? f * Semi(e.Third) : f * 2.0;  // third or octave
                    v.Atk = 0.004; v.AtkInc = 1.0 / (0.004 * SR);
                    v.Dec = Math.Exp(-1.0 / (0.055 * SR));
                    v.Life = e.Dur + 0.34;
                    break;
                case B:
                    v.F1 = f; v.F2 = f * 1.4983; v.F3 = f;
                    v.Atk = 0.006; v.AtkInc = 1.0 / (0.006 * SR);
                    v.Dec = Math.Exp(-1.0 / (0.030 * SR));
                    v.Life = e.Dur + 0.10;
                    break;
                case K:
                    // Atk has to be > 0 or Env stays at zero for the whole note
                    v.Atk = 0.0008; v.AtkInc = 1.0 / (0.0008 * SR);
                    v.Dec = Math.Exp(-1.0 / (0.085 * SR));
                    v.Life = 0.44;
                    break;
                case S:
                    v.Atk = 0.0006; v.AtkInc = 1.0 / (0.0006 * SR);
                    v.Dec = Math.Exp(-1.0 / (0.052 * SR));
                    v.Life = 0.30;
                    break;
                case H:
                    v.Atk = 0.0004; v.AtkInc = 1.0 / (0.0004 * SR);
                    v.Dec = Math.Exp(-1.0 / (0.0130 * SR));
                    v.Life = 0.09;
                    break;
                case C:
                    v.Atk = 0.0010; v.AtkInc = 1.0 / (0.0010 * SR);
                    v.Dec = Math.Exp(-1.0 / (0.44 * SR));
                    v.Life = 1.9;
                    break;
                case L:
                    v.F1 = f; v.F2 = f; v.F3 = f;
                    v.Atk = 0.012; v.AtkInc = 1.0 / (0.012 * SR);
                    v.Dec = Math.Exp(-1.0 / (0.075 * SR));
                    v.Life = e.Dur + 0.22;
                    break;
                default:
                    v.Life = e.Dur;
                    break;
            }
            return v;
        }

        public static AudioOut Render(List<Ev> evs, double total)
        {
            InitTabs();
            if (total < 0.05) total = 0.05;
            if (total > 900.0) total = 900.0;
            int n = (int)(total * SR) + 2048;
            double[] mix = new double[n];

            int nv = (evs == null) ? 0 : evs.Count;
            V[] pool = new V[nv];
            for (int i = 0; i < nv; i++) pool[i] = Mk(evs[i]);
            Array.Sort(pool, delegate(V x, V y) { return x.T0.CompareTo(y.T0); });

            V[] act = new V[128];
            int ac = 0, next = 0;
            double[] dly = new double[SR];
            int dlyPos = 0;
            double inv = 1.0 / SR;

            for (int i = 0; i < n; i++)
            {
                double t = i * inv;
                while (next < nv && pool[next].T0 <= t)
                {
                    if (ac < act.Length) act[ac++] = pool[next];
                    next++;
                }

                double g = 0.0, b = 0.0, d = 0.0, l = 0.0;
                int w = 0;
                for (int k = 0; k < ac; k++)
                {
                    V v = act[k];
                    double lt = t - v.T0;
                    if (lt >= v.Life) continue;                 // finished, drop

                    if (lt < v.Atk) v.Env += v.AtkInc;
                    else v.Env *= v.Dec;

                    double s = 0.0;
                    switch (v.Kind)
                    {
                        case G:
                        {
                            v.P1 += v.F1 * inv; if (v.P1 >= 1) v.P1 -= 1;
                            v.P2 += v.F2 * inv; if (v.P2 >= 1) v.P2 -= 1;
                            v.P3 += v.F3 * inv; if (v.P3 >= 1) v.P3 -= 1;
                            double x = Wv(Gt, v.P1) * 0.44 + Wv(Gt, v.P2) * 0.34 + Wv(Gt, v.P3) * 0.22;
                            v.S1 += (x - v.S1) * 0.40;           // warm lowpass ~2.6 kHz
                            x = v.S1;
                            if (lt < 0.007) s += Nz(ref v.Rs) * 0.32 * (1.0 - lt / 0.007); // pick transient
                            s += x * v.Env;
                            g += s * v.A;
                            break;
                        }
                        case B:
                        {
                            v.P1 += v.F1 * inv; if (v.P1 >= 1) v.P1 -= 1;
                            double x = Wv(Sn, v.P1) * 0.80 + Wv(Sq, v.P1 * 0.5 + 0.25) * 0.20;
                            v.S2 += (x - v.S2) * 0.16;
                            b += v.S2 * v.Env * v.A;
                            break;
                        }
                        case K:
                        {
                            double e = v.Env;
                            double fq = 44.0 + 130.0 * e;          // pitch drop
                            v.P1 += fq * inv; if (v.P1 >= 1) v.P1 -= 1;
                            double x = Wv(Sn, v.P1) * (1.0 - 0.30 * e) + 0.22 * Nz(ref v.Rs) * e;
                            d += x * e * e * v.A;
                            break;
                        }
                        case S:
                        {
                            double e = v.Env;
                            double nz = Nz(ref v.Rs);
                            v.S3 += (nz - v.S3) * 0.70;
                            v.P1 += (185.0 + 70.0 * e) * inv; if (v.P1 >= 1) v.P1 -= 1;
                            d += ((nz - v.S3) * 0.95 + Wv(Sn, v.P1) * 0.38) * e * v.A;
                            break;
                        }
                        case H:
                        {
                            double e = v.Env;
                            double nz = Nz(ref v.Rs);
                            v.S3 += (nz - v.S3) * 0.88;
                            d += (nz - v.S3) * e * 0.60 * v.A;
                            break;
                        }
                        case C:
                        {
                            double e = v.Env;
                            double nz = Nz(ref v.Rs);
                            v.S3 += (nz - v.S3) * 0.55;
                            double s2 = (nz - v.S3) * e;
                            if (lt < 0.003) s2 += 0.30 * e * (1.0 - lt / 0.003);
                            d += s2 * v.A * 0.75;
                            break;
                        }
                        case L:
                        {
                            v.P1 += v.F1 * inv; if (v.P1 >= 1) v.P1 -= 1;
                            double vib = 1.0 + 0.006 * Math.Sin(2.0 * Math.PI * 5.2 * lt);
                            v.P1 += v.F1 * vib * inv; if (v.P1 >= 1) v.P1 -= 1;
                            double x = Wv(Sq, v.P1);
                            v.S1 += (x - v.S1) * 0.50;
                            l += v.S1 * v.Env * v.A;
                            break;
                        }
                    }
                    act[w++] = v;
                }
                ac = w;

                double dl = dly[dlyPos];
                l += dl * 0.34;                       // slapback on the lead
                dly[dlyPos] = l * 0.42 + dl * 0.25;
                dlyPos++; if (dlyPos >= SR) dlyPos = 0;

                mix[i] = g * 0.30 + b * 0.32 + d * 0.44 + l * 0.21;
            }

            // glue / limit / normalise
            double pk = 0.0;
            bool nan = false;
            for (int i = 0; i < n; i++)
            {
                double x = mix[i];
                if (double.IsNaN(x) || double.IsInfinity(x)) { x = 0.0; nan = true; }
                double a = x < 0 ? -x : x;
                if (a > pk) pk = a;
            }
            // Pass 1: saturate for grit + glue.
            double pre = (pk > 0.0001) ? (0.55 / pk) : 1.0;
            double[] cl = new double[n];
            double cpk = 0.0;
            for (int i = 0; i < n; i++)
            {
                double x = mix[i] * pre;
                double x2 = x * x;                       // Pade tanh (cheap soft clip)
                x = x * (27.0 + x2) / (27.0 + 9.0 * x2);
                cl[i] = x;
                double a = x < 0 ? -x : x;
                if (a > cpk) cpk = a;
            }
            // Pass 2: normalise the saturated signal to a healthy level.
            double norm = (cpk > 0.0001) ? (0.93 / cpk) : 1.0;
            byte[] pcm = new byte[n * 2];
            int ipk = 0;
            double sum = 0.0;
            for (int i = 0; i < n; i++)
            {
                int q = (int)(cl[i] * norm * 32000.0);
                if (q > 32767) q = 32767; else if (q < -32768) q = -32768;
                pcm[i * 2] = (byte)(q & 0xFF);
                pcm[i * 2 + 1] = (byte)((q >> 8) & 0xFF);
                int aq = q < 0 ? -q : q;
                if (aq > ipk) ipk = aq;
                sum += (double)q * q;
            }
            if (nan) for (int i = 0; i < n; i++)
            {
                double x = mix[i];
                if (double.IsNaN(x) || double.IsInfinity(x)) { mix[i] = 0; }
            }

            AudioOut ao = new AudioOut();
            ao.Pcm = pcm;
            ao.Seconds = (double)n / SR;
            ao.Rate = SR;
            ao.Peak = ipk;
            ao.Rms = Math.Sqrt(sum / Math.Max(1, n)) / 32768.0;
            ao.Voices = nv;
            ao.HasNaN = nan;
            return ao;
        }

        public static byte[] WrapWav(AudioOut a)
        {
            int dataLen = a.Pcm.Length;
            byte[] h = new byte[44];
            int byteRate = a.Rate * 2;
            int blockAlign = 2;
            WriteAscii(h, 0, "RIFF");
            WriteI32(h, 4, 36 + dataLen);
            WriteAscii(h, 8, "WAVE");
            WriteAscii(h, 12, "fmt ");
            WriteI32(h, 16, 16);
            WriteI16(h, 20, 1);
            WriteI16(h, 22, 1);
            WriteI32(h, 24, a.Rate);
            WriteI32(h, 28, byteRate);
            WriteI16(h, 32, blockAlign);
            WriteI16(h, 34, 16);
            WriteAscii(h, 36, "data");
            WriteI32(h, 40, dataLen);
            byte[] outp = new byte[44 + dataLen];
            Buffer.BlockCopy(h, 0, outp, 0, 44);
            Buffer.BlockCopy(a.Pcm, 0, outp, 44, dataLen);
            return outp;
        }

        static void WriteAscii(byte[] b, int o, string s)
        {
            for (int i = 0; i < s.Length; i++) b[o + i] = (byte)s[i];
        }
        static void WriteI32(byte[] b, int o, int v)
        {
            b[o] = (byte)(v & 0xFF); b[o + 1] = (byte)((v >> 8) & 0xFF);
            b[o + 2] = (byte)((v >> 16) & 0xFF); b[o + 3] = (byte)((v >> 24) & 0xFF);
        }
        static void WriteI16(byte[] b, int o, int v)
        {
            b[o] = (byte)(v & 0xFF); b[o + 1] = (byte)((v >> 8) & 0xFF);
        }

        // Short UI blip: kind 0 = move, 1 = confirm, 2 = back, 3 = hit
        public static AudioOut Blip(int kind)
        {
            List<Ev> l = new List<Ev>();
            if (kind == 0)
            {
                l.Add(new Ev { T = 0.00, Dur = 0.05, Kind = L, Midi = 76, Vol = 0.30 });
            }
            else if (kind == 1)
            {
                l.Add(new Ev { T = 0.00, Dur = 0.07, Kind = L, Midi = 72, Vol = 0.32 });
                l.Add(new Ev { T = 0.07, Dur = 0.12, Kind = L, Midi = 79, Vol = 0.32 });
            }
            else if (kind == 2)
            {
                l.Add(new Ev { T = 0.00, Dur = 0.06, Kind = L, Midi = 64, Vol = 0.28 });
                l.Add(new Ev { T = 0.06, Dur = 0.10, Kind = L, Midi = 57, Vol = 0.28 });
            }
            else
            {
                l.Add(new Ev { T = 0.00, Dur = 0.03, Kind = G, Midi = 64, Vol = 0.30, Third = 4 });
                l.Add(new Ev { T = 0.00, Dur = 0.05, Kind = K, Midi = 36, Vol = 0.30 });
            }
            return Render(l, 0.30);
        }
    }

    // ---------------------------------------------------------------------
    // winmm playback with accurate device position reporting.
    // Falls back to a stopwatch clock, then to silence.
    // ---------------------------------------------------------------------
    public class Player : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct WAVEFORMAT
        {
            public short wFormatTag;
            public short nChannels;
            public int nSamplesPerSec;
            public int nAvgBytesPerSec;
            public short nBlockAlign;
            public short wBitsPerSample;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct WAVEHDR
        {
            public IntPtr lpData;
            public int dwBufferLength;
            public int dwBytesRecorded;
            public IntPtr dwUser;
            public IntPtr lpNext;
            public IntPtr reserved;
            public int dwFlags;
            public int dwLoops;
        }

        [DllImport("winmm.dll", CharSet = CharSet.Auto, SetLastError = false)]
        public static extern int waveOutOpen(out IntPtr h, int dev, WAVEFORMAT fmt, int cb, IntPtr inst, int flags);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutGetPosition(IntPtr h, out int pos, out int fdw);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutReset(IntPtr h);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutClose(IntPtr h);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutPause(IntPtr h);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutResume(IntPtr h);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutSetVolume(IntPtr h, int vol);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int waveOutGetNumDevs();
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        static extern int mciSendString(string cmd, System.Text.StringBuilder buf, int bufLen, IntPtr cb);

        IntPtr _h = IntPtr.Zero;
        IntPtr _hdr = IntPtr.Zero;
        GCHandle _pin;
        WAVEFORMAT _fmt;
        // Fallback backend: some machines hand waveOut a stub device that accepts
        // buffers and never moves.  MCI still reaches the real endpoint there, so
        // the song is played through it and the wall clock keeps the notes in sync.
        string _alias;
        string _wavPath;
        // Music and Sfx are two Player instances in one process: each needs its
        // own MCI alias and temp file, otherwise a blip closes the song device.
        static int s_uid;
        int _uid;
        int _byteRate = 0;
        int _dataLen = 0;
        double _last = 0.0;
        bool _paused = false;
        bool _disposed = false;
        System.Diagnostics.Stopwatch _sw = new System.Diagnostics.Stopwatch();
        double _swOffset = 0.0;
        string _mode = "none";
        string _err = "";
        bool _isFile = false;        // true while a file from disk is playing
        double _fileSec = 0.0;       // its length, asked from MCI
        int _vol = 100;
        bool _trustDev = false;      // true only while the device position really advances
        bool _devSeen = false;
        double _devPos = 0.0;
        double _devAt = 0.0;

        public Player()
        {
            SweepStaleWavs();
        }

        // A session killed with the console window closed cannot clean up after
        // itself, so a later run removes the temp files of processes that are gone.
        static void SweepStaleWavs()
        {
            try
            {
                int me = System.Diagnostics.Process.GetCurrentProcess().Id;
                string[] files = System.IO.Directory.GetFiles(System.IO.Path.GetTempPath(), "rockhero-*.wav");
                for (int i = 0; i < files.Length; i++)
                {
                    string n = System.IO.Path.GetFileNameWithoutExtension(files[i]);
                    int dash = n.IndexOf('-');
                    if (dash < 0) continue;
                    int sp = n.IndexOf('-', dash + 1);
                    int owner = 0;
                    string pidText = (sp < 0) ? n.Substring(dash + 1) : n.Substring(dash + 1, sp - dash - 1);
                    if (!int.TryParse(pidText, out owner)) continue;
                    if (owner <= 0 || owner == me) continue;
                    bool alive = true;
                    try { System.Diagnostics.Process.GetProcessById(owner); }
                    catch { alive = false; }
                    if (alive) continue;
                    try { System.IO.File.Delete(files[i]); } catch { }
                }
            }
            catch { }
        }

        void StartClock()
        {
            _sw.Reset();
            _sw.Start();
            _swOffset = 0.0;
            _devSeen = false;
        }

        // Give up on hardware but keep the song running on the wall clock, so the
        // game never stalls when a driver refuses to report a moving position.
        void GoSilent(int byteRate, int dataLen)
        {
            Cleanup();
            _byteRate = byteRate;
            _dataLen = dataLen;
            _trustDev = false;
            if (StartSoundPlayer()) { _mode = "sound+clock"; return; }
            _mode = "silent";
            StartClock();
        }

        // Wrap the current mix in a RIFF header held in memory (no temp files).
        byte[] WrapPcm(byte[] pcm, int rate)
        {
            byte[] h = new byte[44];
            int byteRate = rate * 2;
            string[] tag = new string[] { "RIFF", "WAVE", "fmt ", "data" };
            int[] at = new int[] { 0, 8, 12, 36 };
            for (int k = 0; k < 4; k++)
            {
                byte[] b = System.Text.Encoding.ASCII.GetBytes(tag[k]);
                Buffer.BlockCopy(b, 0, h, at[k], b.Length);
            }
            WriteI32(h, 4, 36 + pcm.Length);
            WriteI32(h, 16, 16);
            WriteI16(h, 20, 1);          // PCM
            WriteI16(h, 22, 1);          // mono
            WriteI32(h, 24, rate);
            WriteI32(h, 28, byteRate);
            WriteI16(h, 32, 2);          // block align
            WriteI16(h, 34, 16);         // bits per sample
            WriteI32(h, 40, pcm.Length);
            byte[] outp = new byte[44 + pcm.Length];
            Buffer.BlockCopy(h, 0, outp, 0, 44);
            Buffer.BlockCopy(pcm, 0, outp, 44, pcm.Length);
            return outp;
        }

        static void WriteI32(byte[] b, int o, int v)
        {
            b[o] = (byte)v; b[o + 1] = (byte)(v >> 8); b[o + 2] = (byte)(v >> 16); b[o + 3] = (byte)(v >> 24);
        }
        static void WriteI16(byte[] b, int o, int v)
        {
            b[o] = (byte)v; b[o + 1] = (byte)(v >> 8);
        }

        // Needs _pcm/_rate kept around from Play() to rebuild the stream.
        byte[] _pcmKeep;
        int _rateKeep;

        bool StartSoundPlayer()
        {
            try
            {
                if (_pcmKeep == null || _pcmKeep.Length < 4 || _rateKeep <= 0) return false;
                CloseMci();
                if (_uid == 0) _uid = System.Threading.Interlocked.Increment(ref s_uid);
                int pid = System.Diagnostics.Process.GetCurrentProcess().Id;
                _wavPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "rockhero-" + pid + "-" + _uid + ".wav");
                System.IO.File.WriteAllBytes(_wavPath, WrapPcm(_pcmKeep, _rateKeep));
                _alias = "rhhero" + pid + "_" + _uid;
                int r = mciSendString("open \"" + _wavPath + "\" type waveaudio alias " + _alias, null, 0, IntPtr.Zero);
                if (r != 0) { _err = "mci open rc=" + r; CloseMci(); return false; }
                mciSendString("setaudio " + _alias + " volume to " + (_vol * 10), null, 0, IntPtr.Zero);
                r = mciSendString("play " + _alias, null, 0, IntPtr.Zero);
                if (r != 0) { _err = "mci play rc=" + r; CloseMci(); return false; }
                _trustDev = false;
                _last = 0.0;
                _paused = false;
                StartClock();
                return true;
            }
            catch (Exception ex) { _err = "mci failed: " + ex.Message; CloseMci(); return false; }
        }

        void CloseMci()
        {
            if (_alias != null)
            {
                try { mciSendString("stop " + _alias, null, 0, IntPtr.Zero); } catch { }
                try { mciSendString("close " + _alias, null, 0, IntPtr.Zero); } catch { }
                _alias = null;
            }
            if (_wavPath != null)
            {
                string f = _wavPath; _wavPath = null;
                // MCI releases the file handle a moment after "close", so one
                // delete attempt can fail and would leak the temp file.
                for (int k = 0; k < 6; k++)
                {
                    try { if (!System.IO.File.Exists(f)) break; } catch { break; }
                    try { System.IO.File.Delete(f); } catch { }
                    System.Threading.Thread.Sleep(60);
                }
            }
        }

        public string Mode { get { return _mode; } }
        public string LastError { get { return _err; } }
        public bool Hardware { get { return _h != IntPtr.Zero; } }
        public double Duration { get { if (_isFile) return _fileSec; return _dataLen > 0 ? (double)_dataLen / _byteRate : 0.0; } }

        public int Volume
        {
            get { return _vol; }
            set
            {
                int q = value; if (q < 0) q = 0; if (q > 100) q = 100;
                _vol = q;
                if (_h != IntPtr.Zero)
                {
                    int w = (q << 16) | q;
                    waveOutSetVolume(_h, w);
                }
            }
        }

        public void Play(byte[] pcm, int rate)
        {
            Stop();
            _err = "";
            _trustDev = false;
            if (pcm == null || pcm.Length < 4 || rate <= 0)
            {
                _byteRate = (rate > 0) ? rate * 2 : 0;
                _dataLen = (pcm == null) ? 0 : pcm.Length;
                _mode = "silent";
                StartClock();
                if (_err.Length == 0) _err = "empty buffer";
                return;
            }

            _pcmKeep = pcm; _rateKeep = rate;

            _fmt = new WAVEFORMAT();
            _fmt.wFormatTag = 1;
            _fmt.nChannels = 1;
            _fmt.nSamplesPerSec = rate;
            _fmt.nAvgBytesPerSec = rate * 2;
            _fmt.nBlockAlign = 2;
            _fmt.wBitsPerSample = 16;
            _byteRate = rate * 2;
            _dataLen = pcm.Length;
            _last = 0.0;
            _paused = false;

            _pin = GCHandle.Alloc(pcm, GCHandleType.Pinned);
            int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
            _hdr = Marshal.AllocHGlobal(hdrSize);
            for (int i = 0; i < hdrSize; i++) Marshal.WriteByte(_hdr, i, 0);

            int rc = -1;
            int devs = 0;
            try { devs = waveOutGetNumDevs(); } catch { devs = 0; }
            int list = (devs > 0) ? Math.Min(devs, 8) : 0;
            int[] order = new int[list + 1];
            for (int i = 0; i < list; i++) order[i] = i;
            order[list] = -1;
            int tried = list + 1;

            for (int i = 0; i < tried; i++)
            {
                try { rc = waveOutOpen(out _h, order[i], _fmt, 0, IntPtr.Zero, 0); }
                catch (Exception ex) { _err = ex.Message; rc = -1; }
                if (rc == 0 && _h != IntPtr.Zero) break;
                _h = IntPtr.Zero;
                rc = -1;
            }

            if (_h == IntPtr.Zero)
            {
                if (_err.Length == 0) _err = "waveOutOpen failed (rc=" + rc.ToString() + ")";
                GoSilent(_byteRate, _dataLen);
                return;
            }

            WAVEHDR wh = new WAVEHDR();
            wh.lpData = _pin.AddrOfPinnedObject();
            wh.dwBufferLength = pcm.Length;
            wh.dwBytesRecorded = 0;
            wh.dwUser = IntPtr.Zero;
            wh.lpNext = IntPtr.Zero;
            wh.reserved = IntPtr.Zero;
            wh.dwFlags = 0;
            wh.dwLoops = 0;
            Marshal.StructureToPtr(wh, _hdr, false);

            int pr = waveOutPrepareHeader(_h, _hdr, hdrSize);
            if (pr != 0)
            {
                _err = "waveOutPrepareHeader rc=" + pr;
                GoSilent(_byteRate, _dataLen);
                return;
            }
            int wr = waveOutWrite(_h, _hdr, hdrSize);
            if (wr != 0)
            {
                _err = "waveOutWrite rc=" + wr;
                GoSilent(_byteRate, _dataLen);
                return;
            }

            Volume = _vol;
            StartClock();
            _mode = "waveOut";
            _trustDev = true;

            // Verify the driver actually reports a moving position.
            bool ok = false;
            int p1 = 0, f1 = 0, p2 = 0, f2 = 0;
            System.Threading.Thread.Sleep(90);
            try
            {
                if (waveOutGetPosition(_h, out p1, out f1) == 0)
                {
                    System.Threading.Thread.Sleep(90);
                    if (waveOutGetPosition(_h, out p2, out f2) == 0 && p2 > p1) ok = true;
                }
            }
            catch { ok = false; }
            if (!ok)
            {
                // Sound may or may not come out, but the position cannot be trusted:
                // run the game off the wall clock instead of freezing on the device.
                _trustDev = false;
                double devAt = (double)p1 / _byteRate;
                Cleanup();                       // let go of the stub device
                _byteRate = rate * 2;
                _dataLen = pcm.Length;
                if (StartSoundPlayer()) { _mode = "sound+clock"; return; }
                _mode = "waveOut+clock";
                _swOffset = _last = devAt;
                _devSeen = false;
            }
        }

        public double Position
        {
            get
            {
                if (_paused) return _last;

                double clk = _sw.IsRunning ? (_sw.Elapsed.TotalSeconds - _swOffset) : 0.0;
                if (clk < 0.0) clk = 0.0;

                // A file from disk: MCI knows exactly where the recording is, so
                // the notes follow the audio instead of the stopwatch.
                if (_isFile)
                {
                    double mf = MciSeconds("position");
                    if (mf >= 0.0 && mf <= clk + 0.35 && mf + 0.35 > _last) _last = mf;
                    else if (clk > _last + 0.90) _last = _last + 0.90;
                    else if (clk > _last) _last = clk;
                    if (_last < 0.0) _last = 0.0;
                    return _last;
                }

                // An empty or rejected buffer used to report a permanent 0.0, which
                // froze the note timeline: nothing scrolled and nothing was heard.
                // The wall clock keeps the song moving even when the audio failed.
                if (_byteRate <= 0 || _dataLen <= 0) return clk;

                double v = -1.0;
                if (_h != IntPtr.Zero && _trustDev)
                {
                    try
                    {
                        int p = 0, f = 0;
                        if (waveOutGetPosition(_h, out p, out f) == 0 && p >= 0)
                        {
                            double t = (double)p / _byteRate;
                            if (!_devSeen)
                            {
                                _devSeen = true; _devPos = t; _devAt = clk;
                            }
                            else if (t <= _devPos + 0.0005 && (clk - _devAt) > 0.35)
                            {
                                // the driver stopped advancing: never trust it again
                                _trustDev = false;
                                _mode = "waveOut+clock";
                            }
                            else if (t > _devPos)
                            {
                                _devPos = t; _devAt = clk;
                            }
                            if (_trustDev && t >= 0 && t <= _last + 0.60) v = t;
                        }
                        else _trustDev = false;
                    }
                    catch { _trustDev = false; }
                }
                if (v < 0)
                {
                    v = clk;
                    if (v > _last + 0.60) v = _last + 0.60;
                }
                if (v < _last) v = _last;
                _last = v;
                return v;
            }
        }

        public void Pause()
        {
            if (_paused) return;
            _last = Position;
            _paused = true;
            if (_alias != null) { try { mciSendString("pause " + _alias, null, 0, IntPtr.Zero); } catch { } }
            if (_h != IntPtr.Zero) { try { waveOutPause(_h); } catch { } }
        }

        public void Resume()
        {
            if (!_paused) return;
            _paused = false;
            if (_alias != null) { try { mciSendString("resume " + _alias, null, 0, IntPtr.Zero); } catch { } }
            if (_h != IntPtr.Zero) { try { waveOutResume(_h); } catch { } }
            _swOffset = _sw.Elapsed.TotalSeconds - _last;
            _devSeen = false;
        }

        public void SeekTo(double sec)
        {
            if (sec < 0) sec = 0;
            _last = sec;
            _swOffset = _sw.Elapsed.TotalSeconds - sec;
            _devSeen = false;
        }

        private void Cleanup()
        {
            CloseMci();
            if (_h != IntPtr.Zero)
            {
                try { waveOutReset(_h); } catch { }
                if (_hdr != IntPtr.Zero)
                {
                    try { waveOutUnprepareHeader(_h, _hdr, Marshal.SizeOf(typeof(WAVEHDR))); } catch { }
                }
                try { waveOutClose(_h); } catch { }
                _h = IntPtr.Zero;
            }
            if (_hdr != IntPtr.Zero) { Marshal.FreeHGlobal(_hdr); _hdr = IntPtr.Zero; }
            if (_pin.IsAllocated) _pin.Free();
            _dataLen = 0;
        }

        public void Stop()
        {
            Cleanup();
            _last = 0.0;
            _paused = false;
            _trustDev = false;
            _devSeen = false;
            _isFile = false;
            _fileSec = 0.0;
            if (_sw != null) { _sw.Reset(); }
            _mode = "none";
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            Stop();
        }

        // -------------------------------------------------------------------
        // Probes every waveOut device: opening successfully is not enough, some
        // drivers accept the data and never move the position because Windows
        // has no active output endpoint.  Returns a short human readable line.
        // -------------------------------------------------------------------
        public static string Diagnose()
        {
            int devs = 0;
            try { devs = waveOutGetNumDevs(); } catch { devs = 0; }
            if (devs <= 0) return "no audio device in Windows";

            WAVEFORMAT fmt = new WAVEFORMAT();
            fmt.wFormatTag = 1;
            fmt.nChannels = 1;
            fmt.nSamplesPerSec = 8000;
            fmt.nAvgBytesPerSec = 16000;
            fmt.nBlockAlign = 2;
            fmt.wBitsPerSample = 16;

            int bufLen = 8000;                 // 1 s of silence
            byte[] buf = new byte[bufLen];
            int hs = Marshal.SizeOf(typeof(WAVEHDR));
            int list = Math.Min(devs, 8);
            int opened = 0, moved = 0;

            for (int d = -1; d < list; d++)
            {
                IntPtr h = IntPtr.Zero;
                try { if (waveOutOpen(out h, d, fmt, 0, IntPtr.Zero, 0) != 0 || h == IntPtr.Zero) continue; }
                catch { continue; }
                opened++;

                GCHandle pin = GCHandle.Alloc(buf, GCHandleType.Pinned);
                IntPtr hdr = Marshal.AllocHGlobal(hs);
                for (int i = 0; i < hs; i++) Marshal.WriteByte(hdr, i, 0);
                WAVEHDR wh = new WAVEHDR();
                wh.lpData = pin.AddrOfPinnedObject();
                wh.dwBufferLength = bufLen;
                wh.dwFlags = 0;
                wh.dwLoops = 0;
                Marshal.StructureToPtr(wh, hdr, false);

                bool good = false;
                if (waveOutPrepareHeader(h, hdr, hs) == 0 && waveOutWrite(h, hdr, hs) == 0)
                {
                    int p1 = 0, f1 = 0, p2 = 0, f2 = 0;
                    try
                    {
                        System.Threading.Thread.Sleep(120);
                        if (waveOutGetPosition(h, out p1, out f1) == 0)
                        {
                            System.Threading.Thread.Sleep(160);
                            if (waveOutGetPosition(h, out p2, out f2) == 0 && p2 > p1) good = true;
                        }
                    }
                    catch { }
                    try { waveOutReset(h); } catch { }
                    try { waveOutUnprepareHeader(h, hdr, hs); } catch { }
                }
                if (good) moved++;
                pin.Free();
                Marshal.FreeHGlobal(hdr);
                try { waveOutClose(h); } catch { }
            }

            if (moved > 0) return "playing on " + moved + " of " + opened + " device(s)";
            if (opened == 0) return "every waveOut device refused to open";
            return "no active Windows output (" + opened + " opened, silent)";
        }

        // -------------------------------------------------------------------
        // Plays a file that already exists on disk (the player's own music)
        // instead of a buffer.  MCI decodes mp3/wma as well, and it reports a
        // real position, so the notes follow the recording instead of guessing.
        // -------------------------------------------------------------------
        public bool PlayFile(string path)
        {
            Stop();
            _err = "";
            if (string.IsNullOrEmpty(path) || !System.IO.File.Exists(path)) { _err = "file not found"; _mode = "none"; return false; }
            try
            {
                CloseMci();
                if (_uid == 0) _uid = System.Threading.Interlocked.Increment(ref s_uid);
                _alias = "rhfile" + System.Diagnostics.Process.GetCurrentProcess().Id + "_" + _uid;
                string ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
                string type = "";
                if (ext == ".wav" || ext == ".wave") type = " type waveaudio";
                else if (ext == ".mp3") type = " type mpegvideo";
                int r = mciSendString("open \"" + path + "\"" + type + " alias " + _alias, null, 0, IntPtr.Zero);
                if (r != 0)
                {
                    // some builds refuse the type hint but open the file anyway
                    _alias = "rhfile" + System.Diagnostics.Process.GetCurrentProcess().Id + "b" + _uid;
                    r = mciSendString("open \"" + path + "\" alias " + _alias, null, 0, IntPtr.Zero);
                }
                if (r != 0) { _err = "mci open rc=" + r; CloseMci(); _mode = "none"; return false; }
                mciSendString("setaudio " + _alias + " volume to " + (_vol * 10), null, 0, IntPtr.Zero);

                _wavPath = null;                    // never delete the player's file
                _fileSec = MciSeconds("length");
                if (_fileSec < 0.0) _fileSec = 0.0;   // unknown length is not an error
                r = mciSendString("play " + _alias, null, 0, IntPtr.Zero);
                if (r != 0) { _err = "mci play rc=" + r; CloseMci(); _mode = "none"; return false; }
                _isFile = true;
                _byteRate = 0;                      // file mode: position comes from MCI
                _dataLen = 0;
                _last = 0.0;
                _paused = false;
                StartClock();
                _mode = "file";
                return true;
            }
            catch (Exception ex) { _err = "mci failed: " + ex.Message; CloseMci(); _mode = "none"; return false; }
        }

        // -1 means "MCI could not answer", which is not the same as time zero: the
        // -1 means "MCI could not answer", which is not the same as time zero:
        // the clock falls back to the stopwatch instead of standing still.
        double MciSeconds(string what)
        {
            try
            {
                if (_alias == null) return -1.0;
                System.Text.StringBuilder sb = new System.Text.StringBuilder(64);
                if (mciSendString("status " + _alias + " " + what, sb, sb.Capacity, IntPtr.Zero) != 0) return -1.0;
                double v = 0.0;
                if (!double.TryParse(sb.ToString(), System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out v)) return -1.0;
                return v / 1000.0;
            }
            catch { return -1.0; }
        }
    }

    // =======================================================================
    //  DECODING AND ONSET ANALYSIS OF THE PLAYER'S OWN AUDIO FILES
    // =======================================================================
    public class MediaInfo
    {
        public bool Ok;
        public string Error;
        public string Kind;          // wav / mp3 / ...
        public double Seconds;
        public int Rate;
        public int Channels;
        public int Bits;
    }

    public class Onset
    {
        public double T;             // seconds from the start of the file
        public double Strength;      // 0..1, how hard the attack is
        public double Centroid;      // Hz, brightness: high notes sound higher
        public double Sustain;       // seconds of sound that follow
    }

    public static class Decode
    {
        // RIFF/WAVE reader for uncompressed PCM (8/16/24/32 bit, mono or more).
        // Everything the analysis needs comes out of one pass over the data.
        public static MediaInfo Info(string path)
        {
            MediaInfo mi = new MediaInfo();
            mi.Ok = false;
            try
            {
                string ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
                mi.Kind = (ext.Length > 1) ? ext.Substring(1) : "wav";
                // only the header is needed: a 50 MB song must not be read into
                // memory just to learn how long it is
                byte[] b = new byte[131072];
                int got;
                using (System.IO.FileStream fs = System.IO.File.OpenRead(path))
                {
                    got = fs.Read(b, 0, b.Length);
                    if (fs.Length < 128) b = new byte[(int)fs.Length];
                    if (got > b.Length) got = b.Length;
                }
                if (got < 44) { mi.Error = "file is too small to be audio"; return mi; }
                if (b[0] != 'R' || b[1] != 'I' || b[2] != 'F' || b[3] != 'F' ||
                    b[8] != 'W' || b[9] != 'A' || b[10] != 'V' || b[11] != 'E')
                { mi.Error = "not a RIFF/WAVE file"; return mi; }

                long fileLen = new System.IO.FileInfo(path).Length;
                int pos = 12, rate = 0, ch = 0, bits = 0;
                int dataOff = -1;
                long dataEnd = 0;
                while (pos + 8 <= got)
                {
                    string id = "" + (char)b[pos] + (char)b[pos + 1] + (char)b[pos + 2] + (char)b[pos + 3];
                    int sz = RdI32(b, pos + 4);
                    if (sz < 0) break;
                    if (id == "fmt " && pos + 8 + 16 <= got)
                    {
                        int tag = RdI16(b, pos + 8);
                        ch = RdI16(b, pos + 10);
                        rate = RdI32(b, pos + 12);
                        bits = RdI16(b, pos + 22);
                        if (tag != 1 && tag != 0xFFFE) { mi.Error = "only PCM wav files can be charted"; return mi; }
                    }
                    else if (id == "data")
                    {
                        dataOff = pos + 8;
                        dataEnd = (long)pos + 8 + (long)sz;
                        if (dataEnd > fileLen) dataEnd = fileLen;
                        break;
                    }
                    pos += 8 + sz + (sz & 1);
                }
                if (dataOff < 0 || rate <= 0 || ch <= 0 || bits <= 0) { mi.Error = "wav header is broken"; return mi; }
                mi.Rate = rate; mi.Channels = ch; mi.Bits = bits;
                mi.Seconds = (double)(dataEnd - dataOff) / ((double)rate * ch * (bits / 8));
                mi.Ok = (mi.Seconds > 0.05);
                if (!mi.Ok) mi.Error = "wav contains no samples";
                return mi;
            }
            catch (Exception ex) { mi.Error = ex.Message; return mi; }
        }

        // Mono downmix in [-1,1]; mono/stereo/quad handled, anything else too.
        static double[] Mono(string path)
        {
            byte[] b = System.IO.File.ReadAllBytes(path);
            int pos = 12, rate = 0, ch = 0, bits = 0;
            int dataOff = -1, dataLen = 0;
            while (pos + 8 <= b.Length)
            {
                string id = "" + (char)b[pos] + (char)b[pos + 1] + (char)b[pos + 2] + (char)b[pos + 3];
                int sz = RdI32(b, pos + 4);
                if (sz < 0) break;
                if (id == "fmt " && pos + 8 + 16 <= b.Length)
                {
                    int tag = RdI16(b, pos + 8);
                    ch = RdI16(b, pos + 10);
                    rate = RdI32(b, pos + 12);
                    bits = RdI16(b, pos + 22);
                    if (tag != 1 && tag != 0xFFFE) return null;
                }
                else if (id == "data")
                {
                    dataOff = pos + 8; dataLen = sz;
                    int cap = b.Length - dataOff;
                    if (dataLen > cap || dataLen <= 0) dataLen = cap;
                    break;
                }
                pos += 8 + sz + (sz & 1);
            }
            if (dataOff < 0 || rate <= 0 || ch <= 0 || bits <= 0) return null;
            if (ch > 8) ch = 8;
            int frame = ch * (bits / 8);
            if (frame <= 0) return null;
            int frames = dataLen / frame;
            if (frames <= 0) return null;
            // cap the analysis at ten minutes: a long recording would otherwise
            // turn into a double array of hundreds of megabytes
            int capFrames = rate * 600;
            if (frames > capFrames) frames = capFrames;
            double[] outp = new double[frames];
            for (int i = 0; i < frames; i++)
            {
                double sum = 0.0;
                int o = dataOff + i * frame;
                for (int c = 0; c < ch; c++)
                {
                    int p = o + c * (bits / 8);
                    double v = 0.0;
                    if (bits == 8) v = ((double)(b[p] - 128)) / 128.0;
                    else if (bits == 16) v = RdI16(b, p) / 32768.0;
                    else if (bits == 24)
                    {
                        int raw = b[p] | (b[p + 1] << 8) | (b[p + 2] << 16);
                        if ((raw & 0x800000) != 0) raw -= 0x1000000;
                        v = raw / 8388608.0;
                    }
                    else if (bits == 32)
                    {
                        int raw = RdI32(b, p);
                        if ((raw & unchecked((int)0x80000000)) != 0) v = raw / 2147483648.0;
                        else v = raw / 2147483648.0;
                    }
                    else { return null; }
                    sum += v;
                }
                outp[i] = sum / ch;
            }
            return outp;
        }

        static int RdI16(byte[] b, int o)
        {
            int v = b[o] | (b[o + 1] << 8);
            if ((v & 0x8000) != 0) v -= 0x10000;
            return v;
        }
        static int RdI32(byte[] b, int o)
        {
            int v = b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
            return v;
        }

        // Spectral-flux onset detection over a small log-spaced Goertzel filter
        // bank, plus a brightness measure (centroid) and the length of the
        // sustain that follows each attack.  Cheap enough for a full song and
        // good enough to place notes on what a listener hears.
        public static Onset[] Analyze(string path, double hopMs, double minGapMs, double thresh)
        {
            List<Onset> res = new List<Onset>();
            try
            {
                double[] x = Mono(path);
                if (x == null || x.Length < 2048) return res.ToArray();
                MediaInfo mi = Info(path);
                int rate = mi.Rate;
                if (rate < 4000) rate = 4000;
                int hop = (int)(rate * hopMs / 1000.0);
                if (hop < 32) hop = 32;
                int win = (int)(rate * 0.032);
                if (win < 512) win = 512;
                int nFrames = (x.Length - win) / hop;
                if (nFrames < 4) return res.ToArray();

                // 24 bands from 70 Hz to 8 kHz, geometric spacing
                const int NB = 24;
                double[] bandHz = new double[NB];
                double fLo = 70.0, fHi = Math.Min(8000.0, rate * 0.45);
                for (int k = 0; k < NB; k++) bandHz[k] = fLo * Math.Pow(fHi / fLo, (double)k / (NB - 1));

                double[] prev = new double[NB];
                double[] cur = new double[NB];
                double[] flux = new double[nFrames];
                double[] bright = new double[nFrames];
                double[] rms = new double[nFrames];
                double[] win_ = new double[win];
                for (int i = 0; i < win; i++) win_[i] = 0.5 - 0.5 * Math.Cos(2.0 * Math.PI * i / (win - 1));

                double maxRms = 0.0;
                const double EPS = 1e-7;
                for (int f = 0; f < nFrames; f++)
                {
                    int o = f * hop;
                    double e = 0.0;
                    for (int i = 0; i < win; i++) { double s = x[o + i] * win_[i]; e += s * s; }
                    rms[f] = Math.Sqrt(e / win);
                    if (rms[f] > maxRms) maxRms = rms[f];

                    double fl = 0.0, num = 0.0, den = 0.0;
                    for (int k = 0; k < NB; k++)
                    {
                        double mag = Goertzel(x, o, win, bandHz[k], rate);
                        cur[k] = mag;
                        // log domain: a quiet band still counts when it jumps,
                        // which is what a plucked string is
                        double d = Math.Log(mag + EPS) - Math.Log(prev[k] + EPS);
                        if (d > 0) fl += d;
                        double c2 = mag * mag;
                        num += c2 * bandHz[k];
                        den += c2;
                        prev[k] = mag;
                    }
                    flux[f] = fl;
                    bright[f] = (den > 1e-12) ? num / den : 0.0;
                }
                if (maxRms < 1e-4) return res.ToArray();

                // adaptive threshold: mean + k * deviation over a moving window
                double floorRms = maxRms * 0.02;
                int lastOnset = -100000;
                int minGap = (int)Math.Max(1.0, minGapMs / hopMs);
                // Quietest level seen just before the current frame: a real
                // attack jumps well above it, while the wobble inside a
                // ringing crash does not and must not become a note.
                int quietSpan = (int)(rate * 0.25 / hop);
                if (quietSpan < 4) quietSpan = 4;
                double quiet = rms[0];
                int quietAt = 0;
                List<double> hist = new List<double>();
                for (int f = 2; f < nFrames - 1; f++)
                {
                    if (rms[f] < floorRms) continue;
                    if (f - quietAt >= quietSpan || rms[f] < quiet) { quiet = rms[f]; quietAt = f; }
                    if (hist.Count > 47) hist.RemoveAt(0);
                    hist.Add(flux[f]);
                    if (hist.Count < 8) continue;
                    double mean = 0.0;
                    for (int k = 0; k < hist.Count; k++) mean += hist[k];
                    mean /= hist.Count;
                    double vr = 0.0;
                    for (int k = 0; k < hist.Count; k++) { double d2 = hist[k] - mean; vr += d2 * d2; }
                    double dev = Math.Sqrt(vr / hist.Count);
                    double limit = mean + (dev * thresh) + (maxRms * 0.010);
                    double v = flux[f];
                    bool peak = (v > limit) && (v >= flux[f - 1]) && (v > flux[f + 1]);
                    if (!peak) continue;
                    if (rms[f] < quiet * 1.55) continue;      // not a fresh attack
                    if ((f - lastOnset) < minGap) continue;
                    lastOnset = f;

                    // how long the sound keeps going after the attack
                    double rel = rms[f] * 0.42;
                    int g = f;
                    int limit2 = Math.Min(nFrames - 1, f + (int)(rate * 1.6 / hop));
                    while ((g + 1) < limit2 && rms[g + 1] > rel) g++;
                    double sustain = (g - f) * hopMs / 1000.0;

                    // The analysis window is longer than an attack, so the loudest frame lands
                    // after the transient. Walk back to where the level first
                    // crosses half the peak: that is the moment it was hit.
                    int at = f;
                    double pk = rms[f];
                    int walkFloor = (f - 12 < 0) ? 0 : f - 12;
                    for (int k2 = f; k2 > walkFloor; k2--)
                    {
                        if (rms[k2] < pk * 0.5) break;
                        at = k2;
                    }

                    Onset os = new Onset();
                    os.T = at * hopMs / 1000.0;
                    os.Strength = Math.Min(1.0, v / (limit * 2.0 + 1e-9));
                    os.Centroid = bright[at];
                    os.Sustain = sustain;
                    res.Add(os);
                }
            }
            catch { }
            return res.ToArray();
        }

        static double Goertzel(double[] x, int off, int len, double freq, int rate)
        {
            double w = 2.0 * Math.PI * freq / rate;
            double cw = Math.Cos(w);
            double coeff = 2.0 * cw;
            double s0 = 0.0, s1 = 0.0, s2 = 0.0;
            for (int i = 0; i < len; i++)
            {
                s0 = x[off + i] + coeff * s1 - s2;
                s2 = s1; s1 = s0;
            }
            double p = s1 * s1 + s2 * s2 - coeff * s1 * s2;
            return Math.Sqrt(p < 0 ? 0 : p) / len;
        }

        // Ask MCI to decode anything it understands into a plain wav, so mp3 and
        // friends can be charted too.  Returns an empty string on success.
        public static string ToWav(string path, string wavOut)
        {
            try
            {
                if (string.IsNullOrEmpty(path) || !System.IO.File.Exists(path)) return "file not found";
                string ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
                if (ext == ".wav" || ext == ".wave") return "";
                if (System.IO.File.Exists(wavOut)) System.IO.File.Delete(wavOut);
                int uid = System.Diagnostics.Process.GetCurrentProcess().Id;
                string alias = "rhconv" + uid + "_" + System.Threading.Interlocked.Increment(ref convUid);
                string type = (ext == ".mp3") ? " type mpegvideo" : "";
                int r = Send("open \"" + path + "\"" + type + " alias " + alias);
                if (r != 0)
                {
                    alias = "rhconv" + uid + "b_" + System.Threading.Interlocked.Increment(ref convUid);
                    r = Send("open \"" + path + "\" alias " + alias);
                }
                if (r != 0) { Close(alias); return "Windows cannot decode " + ext + " (needs an mp3/aac codec)"; }
                int rs = Send("save " + alias + " \"" + wavOut + "\"");
                Close(alias);
                if (rs != 0 || !System.IO.File.Exists(wavOut)) return "MCI could not convert " + ext;
                return "";
            }
            catch (Exception ex) { return ex.Message; }
        }

        static int convUid;
        static int Send(string cmd)
        {
            return mciSendStringEx(cmd, null, 0, IntPtr.Zero);
        }
        static void Close(string alias)
        {
            try { mciSendStringEx("stop " + alias, null, 0, IntPtr.Zero); } catch { }
            try { mciSendStringEx("close " + alias, null, 0, IntPtr.Zero); } catch { }
        }
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        static extern int mciSendStringEx(string cmd, System.Text.StringBuilder buf, int bufLen, IntPtr cb);
    }

    // ---------------------------------------------------------------------
    // Console capability probing
    // ---------------------------------------------------------------------
    public static class Term
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int n);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetConsoleMode(IntPtr h, out int m);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetConsoleMode(IntPtr h, int m);

        public static bool TryEnableAnsi()
        {
            try
            {
                IntPtr h = GetStdHandle(-11);
                if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
                int m;
                if (!GetConsoleMode(h, out m)) return false;
                if ((m & 0x0004) != 0) return true;
                return SetConsoleMode(h, m | 0x0004);
            }
            catch { return false; }
        }

        public static bool IsRedirected()
        {
            try
            {
                IntPtr h = GetStdHandle(-10);
                if (h == IntPtr.Zero || h == new IntPtr(-1)) return true;
                int m;
                if (!GetConsoleMode(h, out m)) return true;
                return false;
            }
            catch { return true; }
        }
    }
}
'@

function Initialize-Engine {
    if ('RockHero.Synth' -as [type]) { return $true }

    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:EngineSource))).Replace('-', '')
    $script:EngineHash = $hash

    $asmPath = Join-Path $script:DataDir 'RockHeroEngine.dll'
    $stamp = Join-Path $script:DataDir 'RockHeroEngine.stamp'

    # A dll left behind by an older build would quietly keep running the old
    # engine, so the cached copy is only reused when the source hash matches.
    $cached = $false
    if ((Test-Path -LiteralPath $asmPath) -and (Test-Path -LiteralPath $stamp)) {
        $old = ''
        try { $old = [IO.File]::ReadAllText($stamp).Trim() } catch { }
        if ($old -eq $hash) { $cached = $true }
    }

    if ($cached) {
        try {
            Add-Type -Path $asmPath -ErrorAction Stop
            if ('RockHero.Synth' -as [type]) { return $true }
        } catch { }
    }

    # compile to a fresh file first: that way the cache can be refreshed in the
    # same run and the next launch starts instantly
    $built = $null
    try {
        $built = Join-Path ([IO.Path]::GetTempPath()) ('RockHeroEngine-' + $hash.Substring(0, 8) + '.dll')
        if (Test-Path -LiteralPath $built) { Remove-Item -LiteralPath $built -Force -ErrorAction SilentlyContinue }
        Add-Type -TypeDefinition $script:EngineSource -Language CSharp -OutputAssembly $built -ErrorAction Stop
        Add-Type -Path $built -ErrorAction Stop
        if ('RockHero.Synth' -as [type]) {
            try {
                Copy-Item -LiteralPath $built -Destination $asmPath -Force -ErrorAction Stop
                Set-Content -LiteralPath $stamp -Value $hash -Encoding ASCII -ErrorAction Stop
            } catch { }
            return $true
        }
    } catch { }

    Add-Type -TypeDefinition $script:EngineSource -Language CSharp -ErrorAction Stop
    return [bool]('RockHero.Synth' -as [type])
}

function Get-DataDir {
    $d = $null
    if ($env:LOCALAPPDATA) { $d = Join-Path $env:LOCALAPPDATA 'RockHeroPS' }
    if (-not $d) { $d = Join-Path ([IO.Path]::GetTempPath()) 'RockHeroPS' }
    try {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
        }
    } catch { }
    $script:DataDir   = $d
    $script:ScoreFile = Join-Path $d 'highscores.xml'
    $script:SetFile   = Join-Path $d 'settings.txt'
    return $d
}

# ============================================================================
#  SETTINGS  (plain key=value so the file can still be hand-edited)
# ============================================================================
$script:FailLadder = @(3, 5, 8, 10, 16, 25, 50, 0)   # 0 = never

function Get-FailLabel {
    param([int]$N)
    if ($N -le 0) { return 'never (no limit)' }
    if ($N -eq 1) { return '1 miss and you are out' }
    return ('{0} misses and you are out' -f $N)
}

function Load-Settings {
    if (-not $script:SetFile) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:SetFile)) { return }
        foreach ($ln in [IO.File]::ReadAllLines($script:SetFile)) {
            if ($ln -match '^\s*#') { continue }
            if ($ln -notmatch '=') { continue }
            $k = ($ln -split '=', 2)[0].Trim().ToLowerInvariant()
            $v = ($ln -split '=', 2)[1].Trim()
            switch ($k) {
                'failmisses' {
                    $n = 0
                    if ([int]::TryParse($v, [ref]$n) -and ($n -ge 0)) { $script:FailMisses = $n }
                }
                'volume' {
                    $n = 0
                    if ([int]::TryParse($v, [ref]$n) -and ($n -ge 0 -and $n -le 100)) { $script:Vol = $n }
                }
            }
        }
    } catch { }
}

function Save-Settings {
    if (-not $script:SetFile) { return $false }
    try {
        $body = @(
            '# RockHeroPS settings - delete this file to go back to the defaults',
            ('failmisses = ' + $script:FailMisses),
            ('volume = ' + $script:Vol)
        ) -join "`r`n"
        [IO.File]::WriteAllText($script:SetFile, $body + "`r`n")
        return $true
    } catch { return $false }
}

# ============================================================================
#  GLYPHS AND COLOURS
# ============================================================================
function New-GlyphTable {
    if ($script:Ascii) {
        $script:G = @{
            note = '#'; hold = '='; rail = '|'; receptor = '='; top = '-'
            barfull = '#'; empty = '.'; arrow = '>'; dot = '*'
        }
    } else {
        $script:G = @{
            note     = [string][char]0x2588   # full block
            hold     = [string][char]0x2593   # medium shade
            rail     = [string][char]0x2502   # box drawings light vertical
            receptor = [string][char]0x2550   # box drawings double horizontal
            top      = [string][char]0x2500   # box drawings light horizontal
            barfull  = [string][char]0x2588
            empty    = [string][char]0x2591   # light shade
            arrow    = [string][char]0x25B6   # black right pointing triangle
            dot      = [string][char]0x2605   # black star
        }
    }
    foreach ($k in @($script:G.Keys)) {
        if ($script:G[$k].Length -ne 1) { $script:G[$k] = [string]$script:G[$k][0] }
    }
}

function New-ColorTable {
    if ($script:Ascii) {
        $script:C = @{
            R = ''; Title = ''; Sel = ''; Nrm = ''; Dim = ''; Label = ''; Val = ''
            Perf = ''; Great = ''; Good = ''; Miss = ''; Hold = ''; Od = ''
            Bar = ''; Warn = ''; Ok = ''
        }
        return
    }
    $e = $script:E
    $script:C = @{
        R     = "$e[0m"
        Title = "$e[1;38;5;220m"
        Sel   = "$e[1;38;5;226m"
        Nrm   = "$e[38;5;250m"
        Dim   = "$e[38;5;240m"
        Label = "$e[38;5;245m"
        Val   = "$e[1;38;5;231m"
        Perf  = "$e[1;38;5;46m"
        Great = "$e[1;38;5;220m"
        Good  = "$e[38;5;51m"
        Miss  = "$e[1;38;5;203m"
        Hold  = "$e[38;5;208m"
        Od    = "$e[1;38;5;129m"
        Bar   = "$e[38;5;208m"
        Warn  = "$e[1;38;5;214m"
        Ok    = "$e[1;38;5;77m"
    }
}

# ============================================================================
#  AUDIO / INPUT HELPERS
# ============================================================================
function Play-Blip {
    param([int]$Kind = 0)
    if ($script:NoAudio -or $null -eq $script:Sfx) { return }
    try {
        if (-not $script:Blips.ContainsKey($Kind)) {
            $a = [RockHero.Synth]::Blip($Kind)
            $script:Blips[$Kind] = $a.Pcm
        }
        $script:Sfx.Play($script:Blips[$Kind], [int][RockHero.Synth]::SR)
    } catch { }
}

function Apply-Volume {
    try {
        if ($script:Sfx)   { $script:Sfx.Volume   = $script:Vol }
        if ($script:Music) { $script:Music.Volume = $script:Vol }
    } catch { }
}

function Get-AudioDiag {
    if ($script:AudioDiagText) { return $script:AudioDiagText }
    if ($script:NoAudio) { $script:AudioDiagText = 'audio: off (-NoAudio)'; return $script:AudioDiagText }
    if (-not ('RockHero.Player' -as [type])) {
        $script:AudioDiagText = 'audio: the C# engine did not compile'
        return $script:AudioDiagText
    }
    try { $script:AudioDiagText = 'audio: ' + [RockHero.Player]::Diagnose() }
    catch { $script:AudioDiagText = 'audio: probe failed - ' + $_.Exception.Message }
    return $script:AudioDiagText
}

# ---------------------------------------------------------------------------
#  -AudioDiag : say out loud why a song can be seen but not heard (or the
#  other way round).  Everything lands on screen and in a text file so the
#  report can be pasted somewhere else.
# ---------------------------------------------------------------------------
function Invoke-AudioDiag {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $num = { param([double]$v, [int]$d = 2) [Math]::Round($v, $d).ToString(('F' + $d), $inv) }
    $rep = New-Object System.Collections.Generic.List[string]
    $say = {
        param([string]$m)
        [void]$rep.Add($m)
        Write-Host ('  ' + $m) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  ROCK HERO - audio report' -ForegroundColor Yellow
    Write-Host ''

    & $say ('powerShell      : ' + $PSVersionTable.PSVersion)
    & $say ('engine compiled : ' + ('RockHero.Player' -as [type]))
    & $say ('-NoAudio switch : ' + [bool]$script:NoAudio)
    & $say ('waveOut probe   : ' + (Get-AudioDiag) + '   (only waveOut; the real backend is shown below)')

    $song = $script:Catalog[0]
    if ($DumpSong -ge 1 -and $DumpSong -le $script:Catalog.Count) { $song = $script:Catalog[$DumpSong - 1] }
    $meta = Get-SongMeta $song
    & $say ('song            : ' + $song.Band + ' - ' + $song.Title + '  (' + (& $num $meta.Total 1) + 's)')

    $aud = $null; $chart = $null; $err = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ev  = New-SongEvents $song $meta
        $aud = [RockHero.Synth]::Render($ev, $meta.Total)
        $chart = Get-Chart $song $meta 'Easy'
    } catch { $err = $_.Exception.Message }
    $sw.Stop()
    if ($err) { & $say ('RENDER FAILED   : ' + $err) }
    if ($null -ne $aud) {
        $peak = 0; $sum = 0.0
        foreach ($s in $aud.Pcm) {
            $a = [Math]::Abs([int]$s)
            if ($a -gt $peak) { $peak = $a }
            $sum += [double]$s * $s
        }
        $rms = [Math]::Sqrt($sum / [Math]::Max(1, $aud.Pcm.Length))
        & $say ('mix             : ' + $aud.Pcm.Length + ' bytes, ' + $aud.Rate + ' Hz, ' +
                (& $num ($aud.Pcm.Length / 2.0 / $aud.Rate) 2) + 's, peak=' + $peak + ', rms=' + (& $num $rms 1))
        if ($peak -eq 0) { & $say ('VERDICT         : the mix is digital silence - nothing can be heard.') }
    }
    if ($null -ne $chart) {
        & $say ('chart (Easy)    : ' + $chart.Count + ' notes, first at ' +
                (& $num $chart[0].T 2) + 's, last at ' +
                (& $num $chart[$chart.Count - 1].T 2) + 's')
    }
    & $say ('render took     : ' + (& $num $sw.Elapsed.TotalSeconds 2) + 's')

    $pl = $null
    try {
        $pl = [RockHero.Player]::new()
        $pl.Play($aud.Pcm, [int]$aud.Rate)
        $pl.Volume = $script:Vol
        & $say ('player mode     : ' + $pl.Mode + '   volume=' + $script:Vol + '/' + $pl.Volume)
        & $say ('hardware open   : ' + $pl.Hardware + '   duration=' + (& $num $pl.Duration 2) + 's')
        if ($pl.LastError) { & $say ('driver error    : ' + $pl.LastError) }
        if ($pl.Mode -like 'sound*') {
            & $say ('note            : waveOut is unusable on this PC (the driver opens but')
            & $say ('                  never reports a moving position), so playback moved')
            & $say ('                  to the MCI backend.  "sound+clock" means the music is')
            & $say ('                  really playing and the notes follow it on the wall clock.')
        }
        $at = @()
        for ($i = 0; $i -lt 6; $i++) {
            Start-Sleep -Milliseconds 450
            $at += (& $num $pl.Position 2)
        }
        & $say ('song clock      : ' + ($at -join ' -> ') + '  (seconds)')
        $moved = $false
        for ($i = 1; $i -lt $at.Count; $i++) { if ($at[$i] -gt $at[$i - 1]) { $moved = $true } }
        if (-not $moved) {
            & $say ('VERDICT         : the song clock never moves - the game falls back to the')
            & $say ('                  wall clock so the notes keep scrolling without sound.')
        }
    } catch {
        & $say ('PLAYER FAILED   : ' + $_.Exception.Message)
    }
    if ($null -ne $pl) { try { $pl.Stop(); $pl.Dispose() } catch { } }

    $where = $null
    try { $where = Join-Path (Get-DataDir) 'rockhero-audiodiag.txt' } catch { }
    if ($where) {
        try {
            [IO.File]::WriteAllText($where, ($rep -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
            Write-Host ''
            Write-Host ('  report written to ' + $where) -ForegroundColor Yellow
        } catch { }
    }
    Write-Host ''
    return 0
}

function Read-Keys {
    $out = New-Object System.Collections.ArrayList
    try {
        $n = 0
        while ($n -lt 48 -and [Console]::KeyAvailable) {
            [void]$out.Add([Console]::ReadKey($true))
            $n++
        }
    } catch { }
    return $out
}

function Wait-Key {
    while ($true) {
        $k = $null
        try {
            if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true) }
        } catch { return $null }
        if ($null -ne $k) { return $k }
        [Threading.Thread]::Sleep(14)
    }
}

function Get-Bar {
    param([double]$Frac, [int]$Width)
    if ($Width -lt 4) { return '' }
    $f = $Frac
    if ($f -lt 0) { $f = 0 }
    if ($f -gt 1) { $f = 1 }
    $n = [int][Math]::Round($f * $Width)
    return ($script:G.barfull * $n) + ($script:G.empty * ($Width - $n))
}

# ============================================================================
#  SONG CATALOG  -  original riffs written in the style of each band
#
#  Riff  : 16 chars per bar.  0-4 = fret (mapped onto chord tones),
#          '.' = rest, '-' = let ring
#  Prog  : semitone offset of each bar's chord root (one per riff bar)
#  Drums : 16 chars per bar.  K crash, k kick, s snare, h hat, H open hat
#  Lead  : 16 chars per bar, 0-9 = degree in the scale
# ============================================================================
function New-Song {
    param(
        [string]$Band, [string]$Title, [string]$Style, [int]$Bpm,
        [int]$Root = 40, [bool]$Minor = $true,
        [string[]]$Prog, [string[]]$Riff, [string[]]$Drums, [string[]]$Lead
    )
    [pscustomobject]@{
        Band = $Band; Title = $Title; Style = $Style; Bpm = $Bpm
        Root = $Root; Minor = $Minor
        Prog = $Prog; Riff = $Riff; Drums = $Drums; Lead = $Lead
    }
}

function Get-Catalog {
    $c = New-Object System.Collections.Generic.List[object]

    # -------------------------------------------------------- BLACK SABBATH
    $c.Add((New-Song -Band 'Black Sabbath' -Title 'Iron Man' -Style 'doom' -Bpm 100 -Root 40 -Minor $true -Prog @('0','0','0','0') `
        -Riff  @('0.1.2.3.4.3.2.1.', '2.2.3.3.4.4.3.3.', '0.1.2.3.4.3.2.1.', '0.0.4.4.0.0.4.4.') `
        -Drums @('K..ks...k..ks...', 'K...s...k.kks.kk', 'K..hs..hk..ks..h', 'Khhks...k.khk.kk') `
        -Lead  @('4.4.3.3.2.2.0.0.', '0...4...3...2...', '7...7...4...4...', '0.0.4.4.0.0.7.7.')))

    $c.Add((New-Song -Band 'Black Sabbath' -Title 'Paranoid' -Style 'blues' -Bpm 92 -Root 40 -Minor $true -Prog @('0','0','3','5') `
        -Riff  @('0.0.1.0.0.1.0.0.', '4.4.3.4.4.3.4.3.', '0.0.1.1.0.0.4.4.', '2.2.1.1.0.0.4.4.') `
        -Drums @('K.k.s.k.k.ks.k.s', 'K..ks...k..ks...', 'K.hhs..hk.hhs.kh', 'K..hs..hsKks..hs') `
        -Lead  @('4.4.7.7.4.4.2.2.', '7.6.4.3.2.1.0.0.', '0...7...4...2...', '4...4...7...7...')))

    $c.Add((New-Song -Band 'Black Sabbath' -Title 'War Pigs' -Style 'doom' -Bpm 90 -Root 40 -Minor $true -Prog @('0','0','8','0') `
        -Riff  @('0.0.0.0.0.0.0.0.', '0.0.0.0.1.1.1.1.', '0.0.0.0.0.0.4.4.', '0.0.0.0.2.2.2.2.') `
        -Drums @('K...s...K...s...', 'K...s.k.k...s.k.', 'K...s...K...s...', 'K.k.s.k.k.ks.k.s') `
        -Lead  @('0...0...4...4...', '4...4...0...0...', '0...0...7...7...', '4.4.4.4.2.2.2.2.')))

    $c.Add((New-Song -Band 'Black Sabbath' -Title 'N.I.B.' -Style 'doom' -Bpm 100 -Root 40 -Minor $true -Prog @('0','0','0','0') `
        -Riff  @('0...0...0...0...', '0...0...4...4...', '0...0...3...3...', '4...3...2...1...') `
        -Drums @('K...............', 'K...s...K...s...', 'K...............', 'K...s...K...s...') `
        -Lead  @('0...0...4...4...', '4...4...7...7...', '7...7...4...4...', '4.4.3.3.2.2.0.0.')))

    $c.Add((New-Song -Band 'Black Sabbath' -Title 'Children of the Grave' -Style 'proto-metal' -Bpm 90 -Root 43 -Minor $false -Prog @('0','0','5','3') `
        -Riff  @('0.0.0.0.1.1.0.0.', '0.0.1.1.1.1.0.0.', '2.2.1.1.0.0.0.0.', '1.1.0.0.4.4.0.0.') `
        -Drums @('K..ks...k..ks...', 'K.k.s.k.k.ks.k.s', 'K..hs..hk..hs.kk', 'K...s.k.k...s.k.') `
        -Lead  @('0.2.3.4.3.2.0...', '4.4.4.4.2.2.2.2.', '0...7...4...2...', '7...7...4...4...')))

    $c.Add((New-Song -Band 'Black Sabbath' -Title 'Loner' -Style 'proto-metal' -Bpm 128 -Root 40 -Minor $true -Prog @('0','0','5','3') `
        -Riff  @('0.1.2.1.0.1.2.1.', '4.3.2.1.0.1.2.3.', '2.1.0.1.2.3.4.3.', '0.0.2.2.4.4.2.2.') `
        -Drums @('K.ks.hKh.ks.hKh.', 'K.k.s.k.k.ks.k.s', 'K.ks.hKh.ks.hKh.', 'Kh.h.s.hKh.h.s.h') `
        -Lead  @('4.4.3.3.2.2.0.0.', '9.8.7.6.4.3.2.0.', '7.7.9.9.7.7.4.4.', '0.2.3.4.3.2.0...')))

    $c.Add((New-Song -Band 'Black Sabbath' -Title 'Age of Reason' -Style 'ballad' -Bpm 96 -Root 40 -Minor $true -Prog @('0','5','3','0') `
        -Riff  @('0...0...4...4...', '0.0.2.2.0.0.1.1.', '2.2.1.1.0.0.4.4.', '0.0.0.0.4.4.2.2.') `
        -Drums @('K...s...K...s...', 'K..hs..hk..hs.kk', 'K...s.k.k...s.k.', 'K.ks.hKh.ks.hKh.') `
        -Lead  @('0...7...4...2...', '4...4...7...7...', '7.6.4.3.2.1.0.0.', '0...4...3...2...')))

    # -------------------------------------------------------- LED ZEPPELIN
    $c.Add((New-Song -Band 'Led Zeppelin' -Title 'Stairway to Heaven' -Style 'prog' -Bpm 82 -Root 45 -Minor $true -Prog @('0','0','5','3') `
        -Riff  @('0...0...4...4...', '0.2.2.0.2.2.0.2.', '0.0.4.4.0.0.4.4.', '2.2.4.4.0.0.1.1.') `
        -Drums @('K...s...K...s...', 'K..hs..hk..hs.kk', 'K...s...K...s...', 'Kh.h.s.hKh.h.s.h') `
        -Lead  @('0...2...4...5...', '7.7.9.9.7.7.4.4.', '0...7...4...2...', '4.4.7.7.9.9.0.0.')))

    $c.Add((New-Song -Band 'Led Zeppelin' -Title 'Whole Lotta Love' -Style 'riff' -Bpm 116 -Root 40 -Minor $true -Prog @('0','0','0','0') `
        -Riff  @('0.0.4.0.0.4.0.0.', '2.2.4.2.2.4.2.2.', '0.0.4.4.0.0.4.4.', '1.1.4.4.1.1.4.4.') `
        -Drums @('K...s...K...s...', 'K..ks...k..ks...', 'K.hhs..hk.hhs.kh', 'K.k.s.k.k.ks.k.s') `
        -Lead  @('4...4...7...7...', '0.2.3.4.3.2.0...', '7.6.4.3.2.1.0.0.', '0.0.7.7.9.9.7.7.')))

    # -------------------------------------------------------- GUNS N' ROSES
    $c.Add((New-Song -Band "Guns N' Roses" -Title 'Sweet Child o Mine' -Style 'arena' -Bpm 126 -Root 40 -Minor $true -Prog @('0','0','0','0') `
        -Riff  @('0.2.0.2.0.2.0.2.', '0.2.0.2.1.3.1.3.', '0.0.4.4.0.0.4.4.', '2.2.4.4.3.3.1.1.') `
        -Drums @('K...s...K...s...', 'K...s.k.k...s.k.', 'K...s...K...s...', 'K.kks.k.kks.kks.') `
        -Lead  @('4.4.7.7.9.9.7.7.', '7.7.9.9.7.7.4.4.', '9.8.7.6.4.3.2.0.', '4...4...7...7...')))

    $c.Add((New-Song -Band "Guns N' Roses" -Title 'Paradise City' -Style 'ballad' -Bpm 104 -Root 43 -Minor $true -Prog @('0','5','3','0') `
        -Riff  @('0.0.0.0.0.0.4.4.', '0.0.2.2.0.0.1.1.', '2.2.1.1.0.0.4.4.', '0.0.0.0.4.4.2.2.') `
        -Drums @('K...s...K...s...', 'K..hs..hk..hs.kk', 'K...s...K...s...', 'K.ks.hKh.ks.hKh.') `
        -Lead  @('0...7...4...2...', '4.4.7.7.9.9.7.7.', '7.6.4.3.2.1.0.0.', '0...4...3...2...')))

    # -------------------------------------------------------- METALLICA
    $c.Add((New-Song -Band 'Metallica' -Title 'Enter Sandman' -Style 'thrash' -Bpm 120 -Root 40 -Minor $true -Prog @('0','0','0','0') `
        -Riff  @('0.0.0.0.0...0.0.', '4.4.4.4.4...4.4.', '0.0.0.0.0.0.0.0.', '0.0.0.0.1.1.1.1.') `
        -Drums @('K...s...K...s...', 'Kkkk.s...kkk.s.k', 'K...s...K...s...', 'Kkkksssskkkkssss') `
        -Lead  @('4...3...2...1...', '0...4...3...2...', '7...7...4...4...', '4.4.3.3.2.2.0.0.')))

    $c.Add((New-Song -Band 'Metallica' -Title 'Master of Puppets' -Style 'thrash' -Bpm 136 -Root 38 -Minor $true -Prog @('0','0','8','7') `
        -Riff  @('0.1.2.1.0.1.2.1.', '0.0.0.0.4.4.0.0.', '1.1.2.2.3.3.2.2.', '0.0.4.4.0.0.2.2.') `
        -Drums @('K.kks.k.kks.kks.', 'K.k.s.k.k.ks.k.s', 'Kkkk.s...kkk.s.k', 'K.kks.k.kks.kks.') `
        -Lead  @('9.8.7.6.4.3.2.0.', '7.7.9.9.7.7.4.4.', '4...4...7...7...', '0.2.3.4.3.2.0...')))

    # -------------------------------------------------------- NIRVANA
    $c.Add((New-Song -Band 'Nirvana' -Title 'Smells Like Teen Spirit' -Style 'grunge' -Bpm 147 -Root 38 -Minor $true -Prog @('0','0','8','7') `
        -Riff  @('0.0.0.0.0.0.0.0.', '4.4.4.4.4.4.4.4.', '1.1.1.1.1.1.1.1.', '0.0.0.0.0.0.0.4.') `
        -Drums @('K...s...K...s...', 'Kh.h.s.hKh.h.s.h', 'K.k.s.k.k.ks.k.s', 'K.h.h.s.h.h.s.hK') `
        -Lead  @('4.4.4.4.2.2.2.2.', '0...4...3...2...', '7.6.4.3.2.1.0.0.', '4...4...7...7...')))

    $c.Add((New-Song -Band 'Nirvana' -Title 'Come as You Are' -Style 'grunge' -Bpm 118 -Root 40 -Minor $true -Prog @('0','0','3','5') `
        -Riff  @('0.0.4.4.0.0.1.1.', '2.2.1.1.0.0.4.4.', '0.1.2.1.0.1.2.1.', '0.0.2.2.4.4.2.2.') `
        -Drums @('K..hs..hsKks..hs', 'K...s...K...s...', 'K.ks.hKh.ks.hKh.', 'K...s.k.k...s.k.') `
        -Lead  @('0.0.7.7.9.9.7.7.', '4...4...7...7...', '7.6.4.3.2.1.0.0.', '0...2...4...5...')))

    # -------------------------------------------------------- AC/DC
    $c.Add((New-Song -Band 'AC/DC' -Title 'Back in Black' -Style 'funk-metal' -Bpm 168 -Root 45 -Minor $false -Prog @('0','0','0','0') `
        -Riff  @('0.0.0.0.0.0.0.0.', '1.1.1.1.1.1.1.1.', '0.0.0.0.4.4.4.4.', '2.2.2.2.2.2.2.2.') `
        -Drums @('K.k.s.k.k.ks.k.s', 'K.kks.k.kks.kks.', 'K.k.s.k.k.ks.k.s', 'Kkkksssskkkkssss') `
        -Lead  @('4.4.4.4.7.7.7.7.', '4...4...7...7...', '7.7.9.9.7.7.4.4.', '9.8.7.6.4.3.2.0.')))

    $c.Add((New-Song -Band 'AC/DC' -Title 'Highway to Hell' -Style 'funk-metal' -Bpm 118 -Root 45 -Minor $false -Prog @('0','0','0','0') `
        -Riff  @('0.0.0.0.0.0.0.0.', '1.1.1.1.1.1.1.1.', '4.4.4.4.0.0.0.0.', '0.1.2.1.0.1.2.1.') `
        -Drums @('K..ks...k..ks...', 'K.k.s.k.k.ks.k.s', 'K...s...K...s...', 'K.kks.k.kks.kks.') `
        -Lead  @('0.2.3.4.3.2.0...', '4...4...7...7...', '7.6.4.3.2.1.0.0.', '4.4.4.4.2.2.2.2.')))

    # -------------------------------------------------------- DEEP PURPLE
    $c.Add((New-Song -Band 'Deep Purple' -Title 'Smoke on the Water' -Style 'classic' -Bpm 105 -Root 43 -Minor $false -Prog @('0','0','0','0') `
        -Riff  @('0.1.2.1.0.1.2.1.', '4.4.3.3.2.2.1.1.', '0.1.2.1.0.1.2.1.', '4.3.2.1.0.1.2.3.') `
        -Drums @('K..ks...k..ks...', 'K...s...K...s...', 'K..hs..hk..hs.kk', 'K...s.k.k...s.k.') `
        -Lead  @('0.0.4.4.7.7.9.9.', '4...4...7...7...', '7.6.4.3.2.1.0.0.', '0.2.3.4.3.2.0...')))

    $c.Add((New-Song -Band 'Deep Purple' -Title 'High Ball Shooter' -Style 'classic' -Bpm 132 -Root 40 -Minor $false -Prog @('0','5','3','0') `
        -Riff  @('0.0.0.0.0.0.0.0.', '4.4.4.4.4.4.4.4.', '0.1.2.1.0.1.2.1.', '2.2.4.4.3.3.1.1.') `
        -Drums @('K.k.s.k.k.ks.k.s', 'K...s...K...s...', 'K.kks.k.kks.kks.', 'K.hhs..hk.hhs.kh') `
        -Lead  @('4.4.7.7.9.9.7.7.', '0...7...4...2...', '7...7...4...4...', '9.8.7.6.4.3.2.0.')))

    # -------------------------------------------------------- QUEEN
    $c.Add((New-Song -Band 'Queen' -Title 'Bohemian Rhapsody' -Style 'opera' -Bpm 112 -Root 40 -Minor $true -Prog @('0','0','3','5') `
        -Riff  @('0.2.0.2.0.2.0.2.', '0.0.4.4.0.0.4.4.', '4.4.0.0.2.2.0.0.', '0.0.2.2.4.4.2.2.') `
        -Drums @('K...s...K...s...', 'K..hs..hk..hs.kk', 'K...s...K...s...', 'K.kks.k.kks.kks.') `
        -Lead  @('0...4...3...2...', '4.4.7.7.9.9.7.7.', '7.7.9.9.7.7.4.4.', '0.2.3.4.3.2.0...')))

    $c.Add((New-Song -Band 'Queen' -Title 'We Will Rock You' -Style 'anthem' -Bpm 81 -Root 45 -Minor $false -Prog @('0','0','0','0') `
        -Riff  @('0...0...4...4...', '0.0.0.0.0.0.0.0.', '2...2...1...1...', '0.0.1.1.2.2.4.4.') `
        -Drums @('K...s...K...s...', 'K..ks...k..ks...', 'K...s...K...s...', 'Kkkksssskkkkssss') `
        -Lead  @('0...7...4...2...', '4.4.7.7.9.9.7.7.', '7...7...4...4...', '9.8.7.6.4.3.2.0.')))

    # -------------------------------------------------------- OZZY
    $c.Add((New-Song -Band 'Ozzy Osbourne' -Title 'Crazy Train' -Style 'funk-metal' -Bpm 157 -Root 40 -Minor $true -Prog @('0','0','0','0') `
        -Riff  @('0..0.0..0.0.0...', '0.0.0.0.0..0.0..', '4.4.0.0.4.4.0.0.', '0.0.4.4.0.0.4.4.') `
        -Drums @('K.ks.hKh.ks.hKh.', 'K.k.s.k.k.ks.k.s', 'K.ks.hKh.ks.hKh.', 'K.h.h.s.h.h.s.hK') `
        -Lead  @('4.4.3.3.2.2.0.0.', '9.8.7.6.4.3.2.0.', '0...7...4...2...', '4...4...7...7...')))

    # -------------------------------------------------------- MOTORHEAD
    $c.Add((New-Song -Band 'Motorhead' -Title 'Ace of Spades' -Style 'speed' -Bpm 170 -Root 40 -Minor $true -Prog @('0','0','8','0') `
        -Riff  @('0.0.0.0.4.4.4.4.', '0.0.0.0.0.0.0.0.', '1.1.1.1.4.4.4.4.', '0.0.0.0.2.2.2.2.') `
        -Drums @('Kkkk.s...kkk.s.k', 'K.k.s.k.k.ks.k.s', 'Kkkk.s...kkk.s.k', 'Kkkksssskkkkssss') `
        -Lead  @('4.4.4.4.7.7.7.7.', '7.6.4.3.2.1.0.0.', '9.8.7.6.4.3.2.0.', '4...4...7...7...')))

    # -------------------------------------------------------- THE WHO
    $c.Add((New-Song -Band 'The Who' -Title "Won't Get Fooled Again" -Style 'mod-punk' -Bpm 172 -Root 45 -Minor $false -Prog @('0','0','0','0') `
        -Riff  @('0.0.0.0.1.1.1.1.', '2.2.1.1.0.0.4.4.', '0.1.2.1.0.1.2.1.', '0.0.0.0.0.0.0.0.') `
        -Drums @('K.k.s.k.k.ks.k.s', 'Kkkk.s...kkk.s.k', 'K.k.s.k.k.ks.k.s', 'Kkkksssskkkkssss') `
        -Lead  @('4.4.4.4.2.2.2.2.', '0.2.3.4.3.2.0...', '7.7.9.9.7.7.4.4.', '4...4...7...7...')))

    # -------------------------------------------------------- LYNYRD SKYNYRD
    $c.Add((New-Song -Band 'Lynyrd Skynyrd' -Title 'Sweet Home Alabama' -Style 'southern' -Bpm 98 -Root 40 -Minor $true -Prog @('0','0','8','7') `
        -Riff  @('0..0.0..0.0.0...', '0.0.0.0.4.0.4.0.', '2.2.2.2.1.1.1.1.', '0.0.4.4.0.0.4.4.') `
        -Drums @('K..hs..hk..hs.kk', 'K...s...K...s...', 'K.ks.hKh.ks.hKh.', 'K...s.k.k...s.k.') `
        -Lead  @('0...4...3...2...', '4.4.7.7.9.9.7.7.', '7.6.4.3.2.1.0.0.', '0.2.3.4.3.2.0...')))

    # -------------------------------------------------------- JIMI HENDRIX
    $c.Add((New-Song -Band 'Jimi Hendrix' -Title 'Purple Haze' -Style 'funk' -Bpm 130 -Root 40 -Minor $true -Prog @('0','0','3','5') `
        -Riff  @('0.0.4.0.0.4.0.0.', '2.2.4.2.2.4.2.2.', '0.0.2.2.0.0.2.2.', '1.1.4.4.1.1.4.4.') `
        -Drums @('K...s...K...s...', 'K.ks.hKh.ks.hKh.', 'K.k.s.k.k.ks.k.s', 'K...s.k.k...s.k.') `
        -Lead  @('4.4.7.7.9.9.7.7.', '0...7...4...2...', '7.7.9.9.7.7.4.4.', '9.8.7.6.4.3.2.0.')))

    # -------------------------------------------------------- RUSH
    $c.Add((New-Song -Band 'Rush' -Title 'Tom Sawyer' -Style 'prog' -Bpm 120 -Root 45 -Minor $false -Prog @('0','0','5','3') `
        -Riff  @('0.0.0.0.4.4.0.0.', '2.2.2.2.3.3.1.1.', '0.1.2.3.4.3.2.1.', '0.0.4.4.2.2.1.1.') `
        -Drums @('K.hhs..hk.hhs.kh', 'K.k.s.k.k.ks.k.s', 'K.kks.k.kks.kks.', 'K...s...K...s...') `
        -Lead  @('0...2...4...5...', '4...4...7...7...', '7.6.4.3.2.1.0.0.', '0.0.7.7.9.9.7.7.')))

    # -------------------------------------------------------- ZZ TOP
    $c.Add((New-Song -Band 'ZZ Top' -Title 'La Grange' -Style 'blues-rock' -Bpm 122 -Root 40 -Minor $false -Prog @('0','0','0','0') `
        -Riff  @('0.0.1.0.1.0.4.0.', '0.0.4.0.4.0.1.0.', '2.2.1.2.1.2.4.2.', '0.0.1.1.0.0.4.4.') `
        -Drums @('K...s...K...s...', 'K.hhs..hk.hhs.kh', 'K...s.k.k...s.k.', 'K.k.s.k.k.ks.k.s') `
        -Lead  @('0...4...3...2...', '4.4.7.7.9.9.7.7.', '7...7...4...4...', '0.2.3.4.3.2.0...')))

    # -------------------------------------------------------- AEROSMITH
    $c.Add((New-Song -Band 'Aerosmith' -Title 'Dream On' -Style 'ballad' -Bpm 96 -Root 40 -Minor $true -Prog @('0','5','3','0') `
        -Riff  @('0...0...0...4...', '0.0.2.2.0.0.4.4.', '2.2.1.1.0.0.4.4.', '0.0.0.0.4.4.2.2.') `
        -Drums @('K...s...K...s...', 'K..hs..hk..hs.kk', 'K...s...K...s...', 'K.ks.hKh.ks.hKh.') `
        -Lead  @('0...7...4...2...', '4...4...7...7...', '7.6.4.3.2.1.0.0.', '0...4...3...2...')))

    return $c.ToArray()
}

function Get-BandCount {
    $h = @{}
    foreach ($s in $script:Catalog) { $h[$s.Band] = 1 }
    $h.Count
}

# ============================================================================
#  THE PLAYER'S OWN MUSIC  (%LOCALAPPDATA%\RockHeroPS\music)
#
#  Any wav/mp3 file dropped in that folder shows up in the song list.  The
#  recording itself is the clock (MCI reports its real position), and the notes
#  are placed on the onsets the analysis finds in the audio, so the chart
#  follows what you actually hear instead of a guessed tempo.
# ============================================================================
$script:MusicExt = @('.wav', '.wave', '.mp3', '.wma', '.m4a', '.aac', '.ogg')
$script:ChartExt = @('.wav', '.wave', '.mp3', '.wma', '.m4a', '.aac', '.ogg')
$script:MusicFolder = $null
$script:ChartFolder = $null

# StrictMode 2 makes reading a missing property an error, and the built in songs
# have no Custom flag at all, so it is looked up instead of read.
function Test-CustomSong {
    param($Song)
    if ($null -eq $Song) { return $false }
    return ($null -ne $Song.PSObject.Properties['Custom'])
}

function Get-MusicFolder {
    if ($script:MusicFolder) { return $script:MusicFolder }
    $base = $script:DataDir
    if (-not $base) { $base = Get-DataDir }
    $d = Join-Path $base 'music'
    try {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
        }
    } catch { }
    $script:MusicFolder = $d
    $script:ChartFolder = (Join-Path $base 'charts')
    try {
        if (-not (Test-Path -LiteralPath $script:ChartFolder)) {
            New-Item -ItemType Directory -Path $script:ChartFolder -Force -ErrorAction Stop | Out-Null
        }
    } catch { }
    return $d
}

function Get-CleanTitle {
    param([string]$Path)
    $n = [IO.Path]::GetFileNameWithoutExtension($Path)
    # "03 - Artist - Title (live)" reads a lot better than the raw file name
    $n = $n -replace '^\s*\d{1,3}\s*[-._)]\s*', ''
    $n = $n -replace '[_]+', ' '
    $n = $n -replace '\s{2,}', ' '
    return $n.Trim()
}

# A song entry for a file on disk.  Nothing heavy happens here: only the wav
# header is read, so a folder full of songs costs no measurable time.
function New-CustomSong {
    param([string]$Path)
    $info = $null
    try { $info = [RockHero.Decode]::Info($Path) } catch { $info = $null }
    $dur = 0.0
    if ($null -ne $info -and $info.Ok) { $dur = [double]$info.Seconds }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $ready = ($dur -gt 0.5)
    $song = [pscustomobject]@{
        Custom = $true
        Path = $Path
        Title = (Get-CleanTitle $Path)
        Band = 'my music'
        Style = $ext.TrimStart('.')
        Bpm = 0
        Duration = $dur
        Ready = $ready
        Onsets = $null
        ChartNote = if ($ready) { '' } else { 'not analysed yet' }
    }
    # a file analysed before already knows its tempo, so the song list can show
    # it without decoding the audio again
    $cached = Read-AnalysisCache $song
    if ($null -ne $cached -and $cached.Length -gt 0) {
        $song.Onsets = $cached
        $song.Ready = $true
        $song.ChartNote = ('{0} onsets (cached)' -f $cached.Length)
    } elseif (-not $ready) {
        $song.ChartNote = 'not analysed yet'
    }
    return $song
}

function Get-CustomSongs {
    $out = New-Object System.Collections.Generic.List[object]
    $dir = Get-MusicFolder
    if (-not (Test-Path -LiteralPath $dir)) { return $out.ToArray() }
    $files = $null
    try { $files = [IO.Directory]::GetFiles($dir) } catch { $files = @() }
    foreach ($f in $files) {
        $ext = [IO.Path]::GetExtension($f).ToLowerInvariant()
        if ($script:MusicExt -notcontains $ext) { continue }
        try { $out.Add((New-CustomSong $f)) } catch { }
    }
    # no comma: the caller wraps this in @() so one file is still a list of one
    return $out.ToArray()
}

function Get-ChartCacheFile {
    param([string]$Path)
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $safe = ($name -replace '[^A-Za-z0-9._-]', '_')
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    return (Join-Path $script:ChartFolder ($safe + '.onsets'))
}

# The detector settings are part of the cache key: changing them must not be
# answered with onsets from an older run.
$script:ChartVer = 'v4 invariant-cache'

function Get-ChartStamp {
    param([string]$Path)
    $fi = New-Object IO.FileInfo $Path
    # The engine hash travels with the stamp: onsets from a different detector
    # must never be served from the cache.
    return ('#' + $script:ChartVer + ' ' + $script:EngineHash + ' ' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks)
}

function Read-AnalysisCache {
    param($Song)
    try {
        $f = Get-ChartCacheFile $Song.Path
        if (-not (Test-Path -LiteralPath $f)) { return $null }
        $lines = [IO.File]::ReadAllLines($f)
        if ($lines.Length -lt 3) { return $null }
        if ($lines[0] -ne (Get-ChartStamp $Song.Path)) { return $null }
        # line 2 carries the tempo and length so the cached path shows the same
        # numbers as a fresh analysis
        $meta = ($lines[1] -split '\|')
        if ($meta.Count -ge 2) {
            $Song.Bpm = [int][double]::Parse($meta[0], [Globalization.CultureInfo]::InvariantCulture)
            $Song.Duration = [double]::Parse($meta[1], [Globalization.CultureInfo]::InvariantCulture)
        }
        $list = New-Object System.Collections.Generic.List[object]
        $ic = [Globalization.CultureInfo]::InvariantCulture
        for ($i = 2; $i -lt $lines.Length; $i++) {
            $ln = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            $p = $ln.Split('|')
            if ($p.Length -lt 4) { continue }
            $o = [pscustomobject]@{
                T = [double]::Parse($p[0], $ic); Strength = [double]::Parse($p[1], $ic)
                Centroid = [double]::Parse($p[2], $ic); Sustain = [double]::Parse($p[3], $ic)
            }
            $list.Add($o)
        }
        return ,$list.ToArray()
    } catch { return $null }
}

function Write-AnalysisCache {
    param($Song, $Onsets)
    try {
        $f = Get-ChartCacheFile $Song.Path
        $ic = [Globalization.CultureInfo]::InvariantCulture
        $sb = New-Object Text.StringBuilder
        [void]$sb.AppendLine((Get-ChartStamp $Song.Path))
        [void]$sb.AppendLine(('{0}|{1}' -f ([int]$Song.Bpm).ToString('0', $ic), ([double]$Song.Duration).ToString('0.###', $ic)))
        foreach ($o in $Onsets) {
            # invariant culture: a comma here would be read back as a thousands
            # separator and turn 4.835 seconds into 4835
            [void]$sb.AppendLine(([double]$o.T).ToString('0.000', $ic) + '|' +
                ([double]$o.Strength).ToString('0.000', $ic) + '|' +
                ([double]$o.Centroid).ToString('0.###', $ic) + '|' +
                ([double]$o.Sustain).ToString('0.000', $ic))
        }
        [IO.File]::WriteAllText($f, $sb.ToString())
        return $true
    } catch { return $false }
}

# Runs the detector (or reads the cache).  Returns $null plus an error string
# when the file cannot be charted at all.
function Get-CustomAnalysis {
    param($Song, [ref]$ErrorText)
    $ErrorText.Value = ''
    $cached = Read-AnalysisCache $Song
    if ($null -ne $cached -and $cached.Length -gt 0) {
        $Song.Onsets = $cached
        $Song.Ready = $true
        if ($Song.Duration -lt 0.5) { $Song.Duration = Get-FileSeconds $Song.Path }
        $Song.ChartNote = ('{0} onsets (cached)' -f $cached.Length)
        return ,$cached
    }

    $tmp = $null
    $target = $Song.Path
    try {
        $ext = [IO.Path]::GetExtension($Song.Path).ToLowerInvariant()
        if ($ext -ne '.wav' -and $ext -ne '.wave') {
            # let Windows itself decode mp3/aac/wma into a wav we can read
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('rhchart-{0}.wav' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
            $err = [string][RockHero.Decode]::ToWav($Song.Path, $tmp)
            if ($err) { $ErrorText.Value = $err; return $null }
            $target = $tmp
        }

        $info = [RockHero.Decode]::Info($target)
        if (-not $info.Ok) { $ErrorText.Value = [string]$info.Error; return $null }

        # hop 5 ms for the time resolution, no two notes closer than 60 ms,
        # threshold 1.2 deviations above the local average
        $on = [RockHero.Decode]::Analyze($target, 5.0, 60.0, 1.2)
        if ($null -eq $on -or $on.Length -eq 0) {
            $ErrorText.Value = 'no clear rhythm found in this recording'
            return $null
        }
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($o in $on) {
            $list.Add(([pscustomobject]@{
                T = [double]$o.T; Strength = [double]$o.Strength
                Centroid = [double]$o.Centroid; Sustain = [double]$o.Sustain
            }))
        }
        $arr = $list.ToArray()
        $Song.Onsets = $arr
        $Song.Duration = [double]$info.Seconds
        $Song.Ready = $true
        $Song.Bpm = (Get-OnsetBpm $arr)
        Write-AnalysisCache $Song $arr | Out-Null
        $Song.ChartNote = ('{0} onsets, {1:N0} bpm' -f $arr.Length, $Song.Bpm)
        return $arr
    } catch {
        $ErrorText.Value = $_.Exception.Message
        return $null
    } finally {
        if ($tmp) { try { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue } catch { } }
    }
}

# Display-only tempo: finds the beat grid the onsets sit on. Every candidate
# bpm is tried and scored by how far the gaps are from a subdivision of it, so
# a fast song is not reported at half its speed.
function Get-OnsetBpm {
    param($Onsets)
    if ($null -eq $Onsets -or $Onsets.Length -lt 6) { return 0 }

    # histogram of the gaps in 20 ms bins
    $bin = 0.02
    $hist = New-Object 'int[]' 100
    $total = 0
    for ($i = 1; $i -lt $Onsets.Length; $i++) {
        $g = [double]$Onsets[$i].T - [double]$Onsets[$i - 1].T
        if ($g -lt 0.08 -or $g -gt 2.0) { continue }
        $b = [int][Math]::Floor($g / $bin)
        if ($b -lt 0 -or $b -ge $hist.Length) { continue }
        $hist[$b] = $hist[$b] + 1
        $total++
    }
    if ($total -lt 6) { return 0 }

    $bestBpm = 0
    $bestScore = [double]::MaxValue
    for ($bpm = 70; $bpm -le 180; $bpm++) {
        $step = 60.0 / $bpm
        $err = 0.0
        $hit = 0
        for ($b = 0; $b -lt $hist.Length; $b++) {
            if ($hist[$b] -le 0) { continue }
            $g = ($b + 0.5) * $bin
            $k = [Math]::Round($g / $step)
            if ($k -lt 1) { continue }
            $r = [Math]::Abs($g / $step - $k)
            if ($r -gt 0.30) { $r = 0.30 + $r }
            $err += $r * $hist[$b]
            if ($r -lt 0.18) { $hit += $hist[$b] }
        }
        # a grid that explains most of the gaps wins; ties go to the faster one
        $score = $err + (1.0 - ($hit / [double]$total)) * 3.0 + ($bpm * 0.0006)
        if ($score -lt $bestScore) { $bestScore = $score; $bestBpm = $bpm }
    }
    if ($bestBpm -le 0) { return 0 }
    return $bestBpm
}

function Get-FileSeconds {
    param([string]$Path)
    try {
        $p = New-Object RockHero.Player
        $ok = $p.PlayFile($Path)
        $s = 0.0
        if ($ok) { $s = [double]$p.Duration }
        $p.Stop(); $p.Dispose()
        if ($s -gt 0.2) { return $s }
    } catch { }
    # last resort: size over a plausible 128 kbit/s stream
    try {
        $kb = (New-Object IO.FileInfo $Path).Length / 16000.0
        if ($kb -gt 1) { return [Math]::Min(900.0, $kb) }
    } catch { }
    return 0.0
}

# Brightness decides the lane, the way high frets sit in the top lane: the
# quantiles are taken from this song itself, so a bright track fills the top
# lanes and a dark one the bottom without any hard coded frequency.
function Get-CustomLanes {
    param($Onsets)
    # Lanes come from the rank of the brightness, not from absolute Hz cutoffs:
    # every recording ends up with a spread over all five lanes, and the quiet
    # bass hits go to the low lane while the bright ones go to the high one.
    $n = $script:LANES
    $count = $Onsets.Length
    $lane = New-Object 'int[]' $count
    if ($count -eq 0) { return ,$lane }
    $order = New-Object 'int[]' $count
    for ($i = 0; $i -lt $count; $i++) { $order[$i] = $i }
    # ties are broken by index so the same onsets always give the same lanes,
    # fresh or cached
    $sorted = $order | Sort-Object -Property @{ Expression = { [double]$Onsets[$_].Centroid } }, @{ Expression = { $_ } }
    $pos = 0
    foreach ($i in $sorted) {
        $l = [int][Math]::Floor(($pos * $n) / $count)
        if ($l -ge $n) { $l = $n - 1 }
        if ($l -lt 0) { $l = 0 }
        $lane[$i] = $l
        $pos++
    }
    return ,$lane
}

function Get-CustomChart {
    param($Song, $Meta, [string]$DiffName)
    $d = Get-Difficulty $DiffName
    $ons = $Song.Onsets
    if ($null -eq $ons -or $ons.Length -eq 0) { return @() }

    $gapLimit = 0.26; $minStrength = 0.55
    switch ($d.Name) {
        'Easy'   { $gapLimit = 0.28; $minStrength = 0.60 }
        'Normal' { $gapLimit = 0.17; $minStrength = 0.42 }
        'Hard'   { $gapLimit = 0.12; $minStrength = 0.30 }
        default  { $gapLimit = 0.08; $minStrength = 0.00 }
    }

    $laneOf = Get-CustomLanes $ons
    $n = $script:LANES
    $notes = New-Object System.Collections.Generic.List[object]
    $lastT = -99.0
    $lastLane = -1
    $runSame = 0

    for ($i = 0; $i -lt $ons.Length; $i++) {
        $o = $ons[$i]
        if ($o.Strength -lt $minStrength) { continue }
        $t = [double]$o.T + [double]$Meta.LeadIn
        if (($t - $lastT) -lt $gapLimit) { continue }

        # lane chosen by brightness rank
        $lane = [int]$laneOf[$i]

        # three of the same lane in a row is not playable: walk it towards the middle
        if ($lane -eq $lastLane) {
            $runSame++
            if ($runSame -ge 2) {
                if ($lane -lt ($n - 1)) { $lane = $lane + 1 } else { $lane = $lane - 1 }
                $runSame = 0
            }
        } else { $runSame = 0 }

        $notes.Add((New-ChartNote $t $lane 0.0 0))
        $lastT = $t
        $lastLane = $lane
    }
    if ($notes.Count -eq 0) { return @() }

    # sustained sounds become hold notes: only when the lane stays free
    $busy = @{}
    foreach ($nn in $notes) {
        $k = [string]$nn.Lane
        if ($busy.ContainsKey($k)) {
            $busy[$k] = [double]$busy[$k] + [double]$nn.Hold + 0.070
        } else { $busy[$k] = [double]$nn.T }
    }
    for ($i = 0; $i -lt $ons.Length; $i++) {
        $o = $ons[$i]
        if ($o.Strength -lt $minStrength) { continue }
        $sus = [double]$o.Sustain
        if ($sus -lt 0.20) { continue }
        $t = [double]$o.T + [double]$Meta.LeadIn
        if (($t - $lastT) -gt 0.0 -and ($t - $lastT) -lt $gapLimit) { continue }
        foreach ($nn in $notes) {
            if ([Math]::Abs([double]$nn.T - $t) -gt 0.004) { continue }
            $hold = [Math]::Min(1.60, $sus - 0.06)
            if ($hold -lt 0.20) { continue }
            $clash = $false
            foreach ($other in $notes) {
                if ($other.Lane -ne $nn.Lane) { continue }
                if ($other -eq $nn) { continue }
                $d2 = [double]$other.T - $t
                if ($d2 -gt 0.001 -and $d2 -lt ($hold + 0.070)) { $clash = $true; break }
            }
            if (-not $clash) { $nn.Hold = $hold }
            break
        }
    }

    $arr = $notes.ToArray()
    [Array]::Sort($arr, [Comparison[object]] {
        param($x, $y)
        if ($x.T -lt $y.T) { return -1 }
        if ($x.T -gt $y.T) { return 1 }
        if ($x.Lane -lt $y.Lane) { return -1 }
        if ($x.Lane -gt $y.Lane) { return 1 }
        return 0
    })

    # same lane too close together cannot be hit
    $kept = New-Object System.Collections.Generic.List[object]
    $lastKept = @{}
    foreach ($nn in $arr) {
        if ($lastKept.ContainsKey($nn.Lane)) {
            if (([double]$nn.T - [double]$lastKept[$nn.Lane].T) -lt 0.048) { continue }
        }
        $kept.Add($nn)
        $lastKept[$nn.Lane] = $nn
    }
    return $kept.ToArray()
}

# ============================================================================
#  MUSIC THEORY / EVENT GENERATION
# ============================================================================
function Get-SongMeta {
    param($Song)
    # a file from the player's own folder: the length comes from the recording
    # and a short lead-in lets the first notes scroll in before they are judged
    if (Test-CustomSong $Song) {
        $leadIn = 2.0
        $dur = [double]$Song.Duration
        if ($dur -lt 1.0) { $dur = 1.0 }
        return [pscustomobject]@{
            Song = $Song; Step = 0.25; Bar = 1.0; Bars = 0
            LeadIn = $leadIn; Beat = 0.5
            Total = ($leadIn + $dur + 2.0)
            Custom = $true
        }
    }
    $step = 60.0 / $Song.Bpm / 4.0
    $bar  = $step * 16.0
    $bars = $Song.Riff.Count * 4
    $leadIn = $bar * 2.0
    $total  = $leadIn + ($bars * $bar) + 2.5
    [pscustomobject]@{
        Song = $Song; Step = $step; Bar = $bar; Bars = $bars
        LeadIn = $leadIn; Beat = $step * 4.0; Total = $total
    }
}

function New-Ev {
    param([double]$T, [double]$Dur, [int]$Kind, [int]$Midi, [double]$Vol, [int]$Third = 0)
    $e = [RockHero.Ev]::new()
    $e.T = $T; $e.Dur = $Dur; $e.Kind = $Kind; $e.Midi = $Midi; $e.Vol = $Vol; $e.Third = $Third
    return $e
}

function New-SongEvents {
    param($Song, $Meta)
    $list  = New-Object 'System.Collections.Generic.List[RockHero.Ev]'
    $offs  = if ($Song.Minor) { @(0, 3, 7, 12, 10) } else { @(0, 4, 7, 12, 11) }
    $third = if ($Song.Minor) { 3 } else { 4 }
    $scale = if ($Song.Minor) { @(0, 2, 3, 5, 7, 8, 10, 12, 14, 15) } else { @(0, 2, 4, 5, 7, 9, 11, 12, 14, 16) }
    $step  = $Meta.Step

    $kGtr = 0; $kBass = 1; $kKick = 2; $kSnare = 3; $kHat = 4; $kCrash = 5; $kLead = 6

    # ---- count-in: crash on the bar line, hats on every beat -------------
    for ($bi = 0; $bi -lt 2; $bi++) {
        for ($i = 0; $i -lt 16; $i += 4) {
            $t = ($bi * 16 + $i) * $step
            if ($i -eq 0) { $list.Add((New-Ev $t 0.04 $kCrash 72 0.50 0)) }
            $list.Add((New-Ev $t 0.01 $kHat 60 0.32 0))
        }
    }

    for ($bar = 0; $bar -lt $Meta.Bars; $bar++) {
        $riff = $Song.Riff[$bar % $Song.Riff.Count]
        $dm   = $Song.Drums[$bar % $Song.Drums.Count]
        $ld   = $Song.Lead[$bar % $Song.Lead.Count]
        $root = $Song.Root + [int]$Song.Prog[$bar % $Song.Prog.Count]
        $t0   = $Meta.LeadIn + ($bar * 16 * $step)

        # -------- rhythm guitar -------------------------------------------
        for ($i = 0; $i -lt 16; $i++) {
            $gl = [string]$riff[$i]
            if ($gl -notmatch '^[0-4]$') { continue }
            $f = [int]$gl
            $midi = $root + $offs[$f]
            $dur = $step * 2.0
            for ($j = $i + 1; $j -lt 16; $j++) {
                $nx = [string]$riff[$j]
                if ($nx -ne '.' -and $nx -ne '-') { $dur = ($j - $i) * $step; break }
            }
            if ($dur -gt 0.95)     { $dur = 0.95 }
            if ($dur -lt $step)     { $dur = $step }
            $list.Add((New-Ev ($t0 + $i * $step) $dur $kGtr $midi 0.46 $third))
        }

        # -------- bass -----------------------------------------------------
        for ($i = 0; $i -lt 16; $i += 2) {
            $t = $t0 + $i * $step
            $m = $root - 12
            $dur = $step * 1.6
            if ($i -eq 6) { $m = $root - 5; $dur = $step * 1.2 }
            $list.Add((New-Ev $t $dur $kBass $m 0.52 0))
        }

        # -------- drums ----------------------------------------------------
        for ($i = 0; $i -lt 16; $i++) {
            $dc = [string]$dm[$i]
            if ($dc -eq '.') { continue }
            $t = $t0 + $i * $step
            switch ($dc) {
                'K' { $list.Add((New-Ev $t 0.02 $kCrash 72 0.34 0)) }
                'k' { $list.Add((New-Ev $t 0.02 $kKick 36 0.72 0)) }
                's' { $list.Add((New-Ev $t 0.02 $kSnare 60 0.64 0)) }
                'h' { $list.Add((New-Ev $t 0.01 $kHat 62 0.24 0)) }
                'H' { $list.Add((New-Ev $t 0.01 $kHat 62 0.30 0)) }
                'x' { $list.Add((New-Ev $t 0.01 $kHat 62 0.36 0)) }
                default { }
            }
        }

        # -------- lead melody ----------------------------------------------
        for ($i = 0; $i -lt 16; $i++) {
            $lc = [string]$ld[$i]
            if ($lc -notmatch '^[0-9]$') { continue }
            $d = [int]$lc
            $midi = $root + 12 + $scale[$d]
            $dur = $step * 1.4
            for ($j = $i + 1; $j -lt 16; $j++) {
                $nx = [string]$ld[$j]
                if ($nx -ne '.' -and $nx -ne '-') { $dur = ($j - $i) * $step; break }
            }
            if ($dur -gt 0.7) { $dur = 0.7 }
            $list.Add((New-Ev ($t0 + $i * $step) $dur $kLead $midi 0.32 0))
        }
    }
    return $list
}

# ============================================================================
#  CHART BUILDING
# ============================================================================
$script:Difficulty = @(
    [pscustomobject]@{ Name = 'Easy';   Pt = 'Easy';   Speed = 0.72; Sub = 1; Lead = $false; Drum = $false
                        Desc = 'relaxed 8ths, slow scroll' }
    [pscustomobject]@{ Name = 'Normal'; Pt = 'Normal'; Speed = 1.00; Sub = 0; Lead = $false; Drum = $false
                        Desc = 'the full riff exactly as written' }
    [pscustomobject]@{ Name = 'Hard';   Pt = 'Hard';   Speed = 1.25; Sub = 0; Lead = $true;  Drum = $false
                        Desc = '+ lead-melody stream, faster scroll' }
    [pscustomobject]@{ Name = 'Expert'; Pt = 'Expert'; Speed = 1.52; Sub = 0; Lead = $true;  Drum = $true
                        Desc = '+ drums. brutal note streams' }
)

function Get-Difficulty { param([string]$Name)
    $d = $script:Difficulty | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $d) { $d = $script:Difficulty[1] }
    return $d
}

function New-ChartNote {
    param([double]$T, [int]$Lane, [double]$Hold, [int]$Step)
    [pscustomobject]@{ T = $T; Lane = $Lane; Hold = $Hold; Step = $Step
                       Judged = $false; Judgement = ''; Offset = 0.0 }
}

function Get-Chart {
    param($Song, $Meta, [string]$DiffName = 'Normal')
    if (Test-CustomSong $Song) { return (Get-CustomChart $Song $Meta $DiffName) }
    $d = Get-Difficulty $DiffName
    $notes = New-Object System.Collections.Generic.List[object]
    $step  = $Meta.Step
    $lastT = @{}
    $lastN = @{}

    for ($bar = 0; $bar -lt $Meta.Bars; $bar++) {
        $riff = $Song.Riff[$bar % $Song.Riff.Count]
        $t0   = $Meta.LeadIn + ($bar * 16 * $step)

        for ($i = 0; $i -lt 16; $i++) {
            $gl = [string]$riff[$i]
            $absStep = ($bar * 16) + $i
            if ($gl -notmatch '^[0-4]$') { continue }
            $f = [int]$gl
            # Easy keeps the 8th-note skeleton
            if ($d.Sub -eq 1 -and ($absStep % 2) -ne 0) { continue }

            # a repeated fret in the same lane becomes a hold note
            if ($lastN.ContainsKey($f) -and $lastT.ContainsKey($f)) {
                $gap = $absStep - $lastT[$f]
                $pn = $lastN[$f]
                if ($gap -ge 1 -and $gap -le 5 -and $pn.Hold -le 0.0) {
                    $pn.Hold = [Math]::Min(1.30, ($gap - 0.80) * $step)
                }
            }
            $n = New-ChartNote ($t0 + $i * $step) $f 0.0 $absStep
            $notes.Add($n)
            $lastN[$f] = $n
            $lastT[$f] = $absStep
        }
    }

    if ($d.Lead) {
        for ($bar = 0; $bar -lt $Meta.Bars; $bar++) {
            $ld = $Song.Lead[$bar % $Song.Lead.Count]
            $t0 = $Meta.LeadIn + ($bar * 16 * $step)
            for ($i = 0; $i -lt 16; $i += 2) {
                $lc = [string]$ld[$i]
                if ($lc -notmatch '^[0-9]$') { continue }
                $dg = [int]$lc
                $notes.Add((New-ChartNote ($t0 + $i * $step) (2 + ($dg % 3)) 0.0 (($bar * 16) + $i)))
            }
        }
    }

    if ($d.Drum) {
        for ($bar = 0; $bar -lt $Meta.Bars; $bar++) {
            $dm = $Song.Drums[$bar % $Song.Drums.Count]
            $t0 = $Meta.LeadIn + ($bar * 16 * $step)
            for ($i = 0; $i -lt 16; $i += 2) {
                $dc = [string]$dm[$i]
                if ($dc -eq '.') { continue }
                $lane = 4
                if ($dc -eq 'k')     { $lane = 1 }
                elseif ($dc -eq 's') { $lane = 3 }
                elseif ($dc -eq 'K') { $lane = 4 }
                elseif ($dc -eq 'x') { $lane = 2 }
                else                 { $lane = 0 }
                $notes.Add((New-ChartNote ($t0 + $i * $step) $lane 0.0 (($bar * 16) + $i)))
            }
        }
    }

    $arr = $notes.ToArray()
    if ($arr.Length -eq 0) { return $arr }
    [Array]::Sort($arr, [Comparison[object]] {
        param($a, $b)
        if ($a.T -lt $b.T) { return -1 }
        if ($a.T -gt $b.T) { return 1 }
        if ($a.Lane -lt $b.Lane) { return -1 }
        if ($a.Lane -gt $b.Lane) { return 1 }
        return 0
    })

    # Two notes in the same lane closer than 48 ms cannot both be hit, and the
    # drum stream overlaps the riff lanes, so the later note is dropped.
    $kept = New-Object System.Collections.Generic.List[object]
    $lastKept = @{}
    foreach ($n in $arr) {
        if ($lastKept.ContainsKey($n.Lane)) {
            if (($n.T - $lastKept[$n.Lane].T) -lt 0.048) { continue }
        }
        $kept.Add($n)
        $lastKept[$n.Lane] = $n
    }
    $arr = $kept.ToArray()

    # a hold tail may never run into the next note of the same lane
    $byLane = @{}
    foreach ($n in $arr) {
        if ($byLane.ContainsKey($n.Lane)) {
            $p = $byLane[$n.Lane]
            if (($n.T - $p.T) -lt ($p.Hold + 0.070)) { $p.Hold = 0.0 }
        }
        $byLane[$n.Lane] = $n
    }
    return $arr
}

# ============================================================================
#  SCORING  (pure functions - also exercised by -SelfTest)
# ============================================================================
function Get-Judgement {
    param([double]$Delta)
    $a = [Math]::Abs($Delta)
    if ($a -le $script:WPerfect) { return 'PERFECT' }
    if ($a -le $script:WGreat)   { return 'GREAT' }
    if ($a -le $script:WGood)    { return 'GOOD' }
    return 'MISS'
}

function Get-BasePoints {
    param([string]$J)
    switch ($J) { 'PERFECT' { 300 } 'GREAT' { 200 } 'GOOD' { 100 } default { 0 } }
}

function Get-Mult {
    param([int]$Combo)
    if ($Combo -ge 100) { return 5 }
    if ($Combo -ge 50)  { return 4 }
    if ($Combo -ge 25)  { return 3 }
    if ($Combo -ge 10)  { return 2 }
    return 1
}

function Get-Accuracy {
    param([int]$P, [int]$G, [int]$Gd, [int]$M)
    $n = $P + $G + $Gd + $M
    if ($n -le 0) { return 0.0 }
    return ($P + ($G * 0.75) + ($Gd * 0.45)) / $n
}

function Get-Rank {
    param([double]$Acc)
    if ($Acc -ge 0.97) { return 'S+' }
    if ($Acc -ge 0.93) { return 'S' }
    if ($Acc -ge 0.88) { return 'A' }
    if ($Acc -ge 0.80) { return 'B' }
    if ($Acc -ge 0.70) { return 'C' }
    return 'D'
}

function Get-Stars {
    param([double]$Acc)
    $n = [int][Math]::Floor($Acc * 5.0)
    if ($n -lt 0) { $n = 0 }
    if ($n -gt 5) { $n = 5 }
    return $n
}

# ============================================================================
#  CONSOLE / SCREEN LAYOUT
# ============================================================================
function Get-ScreenSize {
    $w = 0; $h = 0
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { }
    if ($w -le 0 -or $h -le 0) {
        try { $sz = $Host.UI.RawUI.WindowSize; $w = $sz.Width; $h = $sz.Height } catch { }
    }
    if ($w -lt 20) { $w = $script:IDEALW }
    if ($h -lt 10) { $h = $script:IDEALH }
    return [pscustomobject]@{ W = $w; H = $h }
}

function Set-Screen {
    param([switch]$Ideal)
    try {
        $ws = $Host.UI.RawUI.WindowSize
        $nw = [Math]::Max($ws.Width,  $script:IDEALW)
        $nh = [Math]::Max($ws.Height, $script:IDEALH)
        if ($nw -ne $ws.Width -or $nh -ne $ws.Height) {
            $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($nw, $nh)
        }
    } catch { }
    if ($Ideal) { }

    $sz = Get-ScreenSize
    $script:W = $sz.W
    $script:H = $sz.H
    $script:HITROW = [Math]::Max($script:HWTOP + 8, $script:H - 6)
    # a short window must not push the hit row off the bottom of the screen
    if ($script:HITROW -gt ($script:H - 1)) { $script:HITROW = $script:H - 1 }
    if ($script:HITROW -lt 0) { $script:HITROW = 0 }
    $script:PANELX = $script:HWLEFT + ($script:LANES * $script:LW) + 4
    $script:PANELW = [Math]::Max(12, $script:W - $script:PANELX - 1)
    if ($script:PANELW -gt 32) { $script:PANELW = 32 }
    Update-Base
}

function Update-Base {
    $w = $script:W; $h = $script:H
    if ($script:Base -and $w -eq $script:BaseW -and $h -eq $script:BaseH) { return }
    $script:BaseW = $w; $script:BaseH = $h

    $base = New-Object 'string[]' $h
    $rail = $script:G.rail
    $rep  = $script:G.receptor
    $hit  = $script:HITROW
    $lanesTail = $script:LW - 1

    for ($r = 0; $r -lt $h; $r++) {
        if ($r -eq ($script:HWTOP - 1)) {
            $sb = New-Object Text.StringBuilder
            [void]$sb.Append(' ' * $script:HWLEFT)
            for ($l = 0; $l -lt $script:LANES; $l++) { [void]$sb.Append($script:G.top * $script:LW) }
            $base[$r] = $sb.ToString()
            continue
        }
        if ($r -lt $script:HWTOP -or $r -gt $hit) { $base[$r] = ''; continue }
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append(' ' * $script:HWLEFT)
        for ($l = 0; $l -lt $script:LANES; $l++) {
            [void]$sb.Append($rail)
            if ($r -eq $hit) { [void]$sb.Append($rep * $lanesTail) } else { [void]$sb.Append(' ' * $lanesTail) }
        }
        $line = $sb.ToString()
        if ($line.Length -gt $w) { $line = $line.Substring(0, $w) }
        $base[$r] = $line
    }
    $script:Base = $base
}

function Get-BaseRow {
    param([int]$Index)
    if ($script:Base -and $Index -ge 0 -and $Index -lt $script:Base.Count) {
        if ($null -ne $script:Base[$Index]) { return $script:Base[$Index] }
    }
    return ' ' * $script:W
}

# Copy a line keeping only printable columns: an escape sequence occupies no
# space on screen, so counting raw characters chopped the right hand side off
# every coloured line (and cut colours in half) on a real console.
function Copy-Visible {
    param([string]$Line, [int]$Skip = 0, [int]$Take = -1)
    if ($null -eq $Line) { return '' }
    if ($Line.Length -eq 0) { return '' }
    $sb = New-Object Text.StringBuilder
    $vis = 0
    $i = 0
    $n = $Line.Length
    while ($i -lt $n) {
        $cp = [int]$Line[$i]
        if ($cp -eq 27) {
            [void]$sb.Append($Line[$i]); $i++
            while ($i -lt $n) {
                $c2 = [int]$Line[$i]
                [void]$sb.Append($Line[$i]); $i++
                if (($c2 -ge 65 -and $c2 -le 90) -or ($c2 -ge 97 -and $c2 -le 122)) { break }
            }
            continue
        }
        if ($vis -lt $Skip) { $i++; continue }
        if ($Take -ge 0 -and $vis -ge ($Skip + $Take)) { break }
        [void]$sb.Append($Line[$i])
        $vis++
        $i++
    }
    return $sb.ToString()
}

# Fast path used every frame: colour runs are removed by the regex engine and
# only a genuinely too wide line falls back to the character walk. Short rows
# are padded too, otherwise the columns they leave behind keep an older frame.
$script:AnsiRun = [string][char]27 + '\[[0-9;]*[A-Za-z]'
function Limit-Line {
    param([string]$Line)
    if ($null -eq $Line -or $script:W -le 0) { return $Line }
    if ($Line.IndexOf([char]27) -lt 0) {
        if ($Line.Length -gt $script:W) { return $Line.Substring(0, $script:W) }
        return $Line + (' ' * ($script:W - $Line.Length))
    }
    $plain = [regex]::Replace($Line, $script:AnsiRun, '')
    if ($plain.Length -eq $script:W) { return $Line }
    if ($plain.Length -gt $script:W) { return Copy-Visible $Line 0 $script:W }
    return $Line + (' ' * ($script:W - $plain.Length))
}

function New-BlankLines {
    $lines = New-Object 'string[]' $script:H
    $blank = ' ' * $script:W
    for ($i = 0; $i -lt $script:H; $i++) { $lines[$i] = $blank }
    # the comma keeps the array intact: without it PowerShell unrolls it into
    # the pipeline and Set-Cell would later be handed a copy it cannot write to
    return ,$lines
}

function Write-Screen {
    param([string[]]$Lines)
    $sb = New-Object Text.StringBuilder (($script:W * ($script:H + 2)) + 256)
    for ($i = 0; $i -lt $script:H; $i++) {
        $l = ''
        if ($i -lt $Lines.Count -and $null -ne $Lines[$i]) { $l = $Lines[$i] }
        $l = $l.Replace("`r", '').Replace("`n", '')
        # never wider than the console: a longer line wraps and smears the screen
        # (counting columns, not the escape bytes hidden between them)
        $l = Limit-Line $l
        # only between rows: a line feed after the last visible row scrolls the
        # window down by one on every frame, which makes the game shake
        if ($i -gt 0) { [void]$sb.Append("`r`n") }
        [void]$sb.Append($l)
    }
    $txt = $sb.ToString()
    try {
        [Console]::SetCursorPosition(0, 0)
        [Console]::Out.Write($txt)
        [Console]::Out.Flush()
    } catch {
        try { [Console]::Write($txt) } catch { }
    }
}

# ============================================================================
#  HIGH SCORES
# ============================================================================
function Load-Scores {
    $script:High = @{}
    if (-not $script:ScoreFile) { return }
    try {
        if (Test-Path -LiteralPath $script:ScoreFile) {
            $d = Import-Clixml -LiteralPath $script:ScoreFile -ErrorAction Stop
            if ($d -is [System.Collections.IDictionary]) {
                foreach ($k in $d.Keys) { $script:High[[string]$k] = $d[$k] }
            }
        }
    } catch { $script:High = @{} }
}

function Save-Scores {
    param([string]$Path)
    $target = $Path
    if (-not $target) { $target = $script:ScoreFile }
    if (-not $target) { return $false }
    try {
        $script:High | Export-Clixml -LiteralPath $target -Depth 4 -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-ScoreKey { param([int]$Idx, [string]$Diff) return ('{0}|{1}' -f $Idx, $Diff) }

function Get-ScoreFor {
    param([int]$Idx, [string]$Diff)
    $k = Get-ScoreKey $Idx $Diff
    if ($script:High.ContainsKey($k)) { return $script:High[$k] }
    return $null
}

function Set-ScoreFor {
    param([int]$Idx, [string]$Diff, $Rec)
    $k = Get-ScoreKey $Idx $Diff
    $old = Get-ScoreFor $Idx $Diff
    if ($null -eq $old -or $Rec.Score -gt $old.Score) { $script:High[$k] = $Rec; return $true }
    return $false
}

# ============================================================================
#  GENERIC MENU
# ============================================================================
function Show-Menu {
    param(
        [string]$Title,
        [string]$Sub = '',
        [string[]]$Items,
        [scriptblock]$DrawRow,
        [scriptblock]$DrawFoot = $null,
        [int]$Sel = 0,
        [switch]$NoNumber
    )
    $sel = $Sel
    if ($sel -lt 0) { $sel = 0 }
    if ($Items.Count -gt 0 -and $sel -ge $Items.Count) { $sel = $Items.Count - 1 }
    $top = 0

    while ($true) {
        $lines = New-BlankLines
        $c = $script:C
        # a long list (the song catalogue) has to scroll, otherwise the cursor
        # can sit on a row the screen never drew
        $rows = $script:H - 6
        if ($rows -lt 1) { $rows = 1 }
        if ($sel -lt $top) { $top = $sel }
        if ($sel -ge ($top + $rows)) { $top = $sel - $rows + 1 }
        $last = $Items.Count - $rows
        if ($top -gt $last) { $top = $last }
        if ($top -lt 0) { $top = 0 }
        if ($Title -gt '') {
            $t = $Title
            if ($t.Length -gt $script:W) { $t = $t.Substring(0, $script:W) }
            $pad = ' ' * [Math]::Max(0, [int](($script:W - $t.Length) / 2))
            $lines[1] = $pad + $c.Title + $t + $c.R
        }
        if ($Sub -gt '') {
            $s = $Sub
            if ($s.Length -gt $script:W) { $s = $s.Substring(0, $script:W) }
            $pad = ' ' * [Math]::Max(0, [int](($script:W - $s.Length) / 2))
            $lines[2] = $pad + $c.Label + $s + $c.R
        }
        for ($i = $top; $i -lt $Items.Count; $i++) {
            $row = 4 + ($i - $top)
            if ($row -ge ($script:H - 2)) { break }
            $lines[$row] = '  ' + (& $DrawRow $i ($i -eq $sel))
        }
        if ($null -ne $DrawFoot) {
            $lines[$script:H - 2] = '  ' + (& $DrawFoot)
        } else {
            $hint = 'UP/DOWN or W/S to move    ENTER confirm    ESC back'
            if ($NoNumber) { $hint = 'UP/DOWN or W/S to move    ENTER confirm    ESC back' }
            $lines[$script:H - 2] = '  ' + $c.Label + $hint + $c.R
        }
        Write-Screen $lines

        $k = Wait-Key
        if ($null -eq $k) { return -1 }
        $kc = $k.Key
        $ch = [string]$k.KeyChar
        $move = 0; $act = $false; $back = $false
        if ($kc -eq 'UpArrow' -or $kc -eq 'LeftArrow') { $move = -1 }
        elseif ($kc -eq 'DownArrow' -or $kc -eq 'RightArrow') { $move = 1 }
        elseif ($kc -eq 'Home') { $move = -999 }
        elseif ($kc -eq 'End') { $move = 999 }
        elseif ($kc -eq 'Enter' -or $kc -eq 'Space') { $act = $true }
        elseif ($kc -eq 'Escape' -or $kc -eq 'Backspace') { $back = $true }
        elseif ($ch -match '^[wW]$') { $move = -1 }
        elseif ($ch -match '^[sS]$') { $move = 1 }
        elseif (-not $NoNumber -and $ch -match '^[1-9]$') {
            $i = [int]$ch - 1
            if ($i -lt $Items.Count) { $sel = $i; $act = $true }
        }
        if ($move -ne 0 -and $Items.Count -gt 0) {
            $ns = $sel + $move
            if ($ns -lt 0) { $ns = 0 }
            if ($ns -ge $Items.Count) { $ns = $Items.Count - 1 }
            if ($ns -ne $sel) { Play-Blip 0; $sel = $ns }
        }
        if ($back) { Play-Blip 2; return -1 }
        if ($act)  { Play-Blip 1; return $sel }
    }
}

# ============================================================================
#  SCORE STATE
# ============================================================================
$script:LaneKeys = @{
    '1' = 0; '2' = 1; '3' = 2; '4' = 3; '5' = 4
    'A' = 0; 'S' = 1; 'D' = 2; 'F' = 3; 'G' = 4
}

function New-ScoreState {
    param($Chart)
    $fl = New-Object 'double[]' $script:LANES
    $cn = New-Object 'int[]'    $script:LANES
    $hn = New-Object 'object[]' $script:LANES
    $dn = New-Object 'bool[]'   $script:LANES
    for ($i = 0; $i -lt $script:LANES; $i++) { $fl[$i] = -99.0 }
    [pscustomobject]@{
        Chart = $Chart
        Score = 0; Combo = 0; MaxCombo = 0; Idx = 0; WinLo = 0
        Perfect = 0; Great = 0; Good = 0; Miss = 0
        Holds = 0; HoldDrop = 0; Judged = 0
        Meter = 0.0; Od = 0.0; OdReady = $false
        Judgement = ''; JudAt = -999.0; JudColor = 'Nrm'
        Flash = $fl; Cur = $cn; HoldN = $hn; Down = $dn
        Done = $false; Failed = $false
    }
}

function Add-Score {
    param($S, [int]$Base, [double]$Delta)
    $mult = Get-Mult $S.Combo
    $od = 1
    if ($S.Od -gt 0) { $od = 2 }
    $bonus = 1.0 + [Math]::Min(0.5, [Math]::Abs($Delta) * 0.6)
    $S.Score += [int][Math]::Round($Base * $mult * $od * $bonus)
}

function Get-LaneFromKey {
    param($KeyInfo)
    switch ($KeyInfo.Key) {
        'D1' { return 0 }
        'D2' { return 1 }
        'D3' { return 2 }
        'D4' { return 3 }
        'D5' { return 4 }
    }
    $ch = [string]$KeyInfo.KeyChar
    if ($ch.Length -eq 1 -and $script:LaneKeys.ContainsKey($ch)) { return $script:LaneKeys[$ch] }
    return -1
}

# ============================================================================
#  FRAME RENDERING
# ============================================================================
# Wrap a plain string with colour escape runs.  String.Insert counts RAW
# characters, so the line handed in must not carry an escape prefix yet -
# otherwise every run lands to the left of its column and slices the escape
# sequence itself apart, which is what used to shred the highway.
function Wrap-Runs {
    param([string]$Line, $Runs)
    if (-not $script:Ansi) { return $Line }
    if ($null -eq $Runs -or $Runs.Count -eq 0) { return $Line }
    for ($i = $Runs.Count - 1; $i -ge 0; $i--) {
        $r = $Runs[$i]
        $Line = $Line.Insert($r[0] + $r[1], $script:C.Dim)
        $Line = $Line.Insert($r[0], $r[2])
    }
    return $Line
}

function Set-Cell {
    # $Plain is kept for the call sites but no longer trusted: a wrong guess left
    # rows a few columns short or overlong, and an overlong row wraps and shakes
    # the console.
    param([string[]]$Lines, [int]$Row, [int]$X, [string]$Text, [int]$Plain, [int]$Width = 0)
    if ($Row -lt 0 -or $Row -ge $Lines.Count) { return }
    if ($Width -le 0) { $Width = $script:W }
    if ($X -lt 0) { $X = 0 }
    if ($X -gt $Width) { $X = $Width }
    # count what the console will really print: an escape run takes no column
    $vis = $Text.Length
    if ($Text.IndexOf([char]27) -ge 0) { $vis = ([regex]::Replace($Text, $script:AnsiRun, '')).Length }
    $pad = $Width - $X - $vis
    if ($pad -lt 0) { $pad = 0 }
    $Lines[$Row] = (' ' * $X) + $Text + (' ' * $pad)
}

function New-GameFrame {
    param($S, $Song, $Df, [double]$Pos, [double]$InvRow, [string]$AudioMode, $Meta)

    $w   = $script:W; $h = $script:H; $c = $script:C; $g = $script:G
    $hit = $script:HITROW; $top = $script:HWTOP
    # the hit row is cached from the last Set-Screen: a smaller screen (or a
    # resize) must not push it past the last line or the frame throws
    if ($hit -ge $h) { $hit = $h - 1 }
    if ($hit -lt 0)  { $hit = 0 }
    if ($top -ge $hit) { $top = $hit }
    if ($top -lt 0)   { $top = 0 }
    # panel seam: on a very narrow screen the highway would leave the panel with
    # no room at all, which used to compute a negative width and throw
    $px = $script:PANELX
    if ($px -gt ($w - 8)) { $px = [Math]::Max(0, $w - 8) }
    $pwTot = $w - $px
    if ($pwTot -lt 0) { $pwTot = 0 }
    $pw = $script:PANELW
    if ($pw -gt $pwTot) { $pw = $pwTot }
    if ($pw -lt 4)      { $pw = [Math]::Min(4, $pwTot) }
    $lines = New-BlankLines
    $chart = $S.Chart
    $count = $chart.Count
    $nRows = $hit - $top + 1
    if ($nRows -lt 1) { $nRows = 1 }
    $spr = 1.0 / $InvRow          # seconds per highway row

    # ---------------- highway ---------------------------------------------
    $bufs = New-Object 'char[][]' $nRows
    $runs = New-Object 'object[]' $nRows
    for ($i = 0; $i -lt $nRows; $i++) {
        $baseRow = [string](Get-BaseRow ($top + $i))
        # a cached base row can be empty (the hit row moved after the cache was
        # built) and writing a note into an empty array throws: never go narrower
        # than the highway seam
        if ($baseRow.Length -lt $px) { $baseRow = $baseRow.PadRight($px) }
        $bufs[$i] = [char[]]$baseRow
        $runs[$i] = $null
    }

    $winLo = $S.WinLo
    if ($winLo -lt 0) { $winLo = 0 }
    if ($winLo -gt $count) { $winLo = $count }

    # Walk the chart once and drop every note into the row it actually belongs
    # to.  The old loop went row by row and painted whatever note fell in that
    # row's time window, so notes never landed on their own row: they flashed
    # near the hit line and the highway looked empty.
    $reach = ($hit - 1 - $top) * $InvRow          # seconds a note is visible
    if ($reach -le 0) { $reach = 1.0 }
    $tShow = $Pos + $reach + $spr
    $tGone = $Pos - 0.35
    while ($winLo -lt $count -and $chart[$winLo].T -lt $tGone) { $winLo++ }

    $j = $winLo
    while ($j -lt $count -and $chart[$j].T -le $tShow) {
        $n = $chart[$j]; $j++
        if ($n.Lane -lt 0 -or $n.Lane -ge $script:LANES) { continue }
        $col = $script:HWLEFT + ($n.Lane * $script:LW) + 2
        if ($col + 1 -ge $w) { continue }
        $hr = [int][Math]::Round($hit - 1 - (($n.T - $Pos) * $InvRow))
        if ($hr -lt ($top - 1) -or $hr -gt ($hit + 3)) { continue }
        $idx = $hr - $top
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -ge $nRows) { $idx = $nRows - 1 }
        $buf = $bufs[$idx]

        if ($n.Hold -gt 0.06) {
            $hr2 = [int][Math]::Round($hit - 1 - (($n.T + $n.Hold - $Pos) * $InvRow))
            if ($hr2 -lt $hr) { $hr2 = $hr }
            for ($q = $hr2; $q -le $hr; $q++) {
                $qi = $q - $top
                if ($qi -lt 0) { $qi = 0 }
                if ($qi -ge $nRows) { $qi = $nRows - 1 }
                $qb = $bufs[$qi]
                $qb[$col]     = [char]$g.hold[0]
                $qb[$col + 1] = [char]$g.hold[0]
            }
        }
        $past = ($n.T -lt ($Pos - 0.05))
        $ch = $g.hold[0]
        if (-not $past) { $ch = $g.note[0] }
        $buf[$col]     = [char]$ch[0]
        $buf[$col + 1] = [char]$ch[0]
        if (-not $n.Judged) {
            $col2 = $c.Nrm
            if ($past) { $col2 = $c.Miss }
            elseif ($n.Hold -gt 0.06) { $col2 = $c.Hold }
            if ($null -eq $runs[$idx]) { $runs[$idx] = New-Object System.Collections.ArrayList }
            [void]$runs[$idx].Add(@($col, 2, $col2))
        }
    }
    $S.WinLo = $winLo

    # receptor flash
    $recBuf = $bufs[$hit - $top]
    $recRuns = $null
    for ($l = 0; $l -lt $script:LANES; $l++) {
        $age = $Pos - $S.Flash[$l]
        if ($age -ge 0 -and $age -lt 0.17) {
            $x = $script:HWLEFT + ($l * $script:LW)
            for ($q = 1; $q -lt $script:LW; $q++) {
                if (($x + $q) -lt $w) { $recBuf[$x + $q] = [char]$g.note[0] }
            }
            if ($null -eq $recRuns) { $recRuns = New-Object System.Collections.ArrayList }
            [void]$recRuns.Add(@($x, $script:LW, $c.Od))
        }
    }

    for ($i = 0; $i -lt $nRows; $i++) {
        $r = $top + $i
        $content = -join $bufs[$i]
        $plain = $content.Length
        # the highway owns only the columns left of the panel: clamp to that
        # seam so the row can be concatenated with the panel row as it is
        if ($plain -gt $px) { $content = $content.Substring(0, $px) }
        elseif ($plain -lt $px) { $content = $content + (' ' * ($px - $plain)) }
        $rowRuns = $runs[$i]
        if ($r -eq $hit) { $rowRuns = $recRuns }
        $line = Wrap-Runs $content $rowRuns
        if ($script:Ansi) { $line = $c.Dim + $line + $c.R }
        $lines[$r] = $line
    }

    # ---------------- header -----------------------------------------------
    $band = $Song.Band; if ($band.Length -gt 24) { $band = $band.Substring(0, 24) }
    $ttl  = $Song.Title; if ($ttl.Length -gt 26) { $ttl = $ttl.Substring(0, 26) }
    $scoreTxt = '{0,9}' -f $S.Score
    # visible width of the header text: 'ROCK HERO' + '   ' + band + ' - ' + title
    $headPlain = 9 + 3 + $band.Length + 3 + $ttl.Length
    $headTxt = $c.Title + 'ROCK HERO' + $c.R + '   ' + $c.Val + $band + $c.R + ' - ' + $c.Nrm + $ttl + $c.R
    $set = $headTxt
    if ($headPlain + $scoreTxt.Length -lt $w) {
        $set = $headTxt + (' ' * ($w - $headPlain - $scoreTxt.Length)) + $c.Title + $scoreTxt + $c.R
    }
    Set-Cell $lines 0 0 $set $script:W
    Set-Cell $lines 1 0 ($c.Dim + ('  ' + ($g.top * [Math]::Max(0, $w - 4))) + $c.R) $script:W

    # ---------------- right panel ------------------------------------------
    # The panel gets its own buffer and its own local coordinates: Set-Cell
    # rewrites a whole row, so drawing the panel straight onto the frame used to
    # wipe the lanes and every note that scrolled past those rows.
    $prows = New-Object 'string[]' $h
    $pblank = ' '
    if ($pwTot -gt 0) { $pblank = ' ' * $pwTot }
    for ($i = 0; $i -lt $h; $i++) { $prows[$i] = $pblank }
    $mult = Get-Mult $S.Combo
    $acc  = Get-Accuracy $S.Perfect $S.Great $S.Good $S.Miss
    $leftN = $count - $S.Idx

    Set-Cell $prows 4  0 ($c.Label + 'SCORE' + $c.R) (6) $pwTot
    Set-Cell $prows 5  0 ($c.Val + ('{0,9}' -f $S.Score) + $c.R) (9) $pwTot

    $comboTxt = '    -'
    if ($S.Combo -gt 0) { $comboTxt = '{0,5}' -f $S.Combo }
    Set-Cell $prows 7  0 ($c.Label + 'COMBO' + $c.R) (5) $pwTot
    Set-Cell $prows 8  0 ($c.Val + $comboTxt + $c.R + '  ' + $c.Title + ('x{0}' -f $mult) + $c.R) (5 + 2 + 2) $pwTot
    Set-Cell $prows 9  0 ($c.Label + ('max {0,-5} acc {1,5:N1}%' -f $S.MaxCombo, ($acc * 100)) + $c.R) (21) $pwTot

    Set-Cell $prows 11 0 ($c.Label + 'ROCK' + $c.R) (4) $pwTot
    $barCol = $c.Bar
    if ($S.Od -gt 0) { $barCol = $c.Od }
    Set-Cell $prows 12 0 ($barCol + (Get-Bar $S.Meter $pw) + $c.R) $pw $pwTot
    Set-Cell $prows 13 0 ($c.Label + ('perfect {0,-5} great {1}' -f $S.Perfect, $S.Great) + $c.R) (20) $pwTot
    Set-Cell $prows 14 0 ($c.Label + ('good {0,-10} miss {1}' -f $S.Good, $S.Miss) + $c.R) (20) $pwTot
    Set-Cell $prows 15 0 ($c.Label + ('holds {0,-9} drops {1}' -f $S.Holds, $S.HoldDrop) + $c.R) (20) $pwTot

    Set-Cell $prows 17 0 ($c.Label + 'NOTES LEFT' + $c.R) (10) $pwTot
    Set-Cell $prows 18 0 ($c.Val + ('{0,6}' -f $leftN) + $c.R + '  ' + $c.Label + $Df.Pt + $c.R) (8 + $Df.Pt.Length) $pwTot

    # strikes left: how many more misses this song tolerates before the fail
    $used = $S.Miss + $S.HoldDrop
    if ($script:FailMisses -le 0) {
        Set-Cell $prows 19 0 ($c.Label + 'FAIL ON' + $c.R + '  ' + $c.Ok + 'never' + $c.R) (18) $pwTot
    } else {
        $leftStrikes = $script:FailMisses - $used
        if ($leftStrikes -lt 0) { $leftStrikes = 0 }
        $stCol = if ($leftStrikes -le 3) { $c.Warn } else { $c.Val }
        $stTxt = ('{0,4} of {1}' -f $leftStrikes, $script:FailMisses)
        Set-Cell $prows 19 0 ($c.Label + 'MISSES LEFT' + $c.R + '  ' + $stCol + $stTxt + $c.R) (11 + $stTxt.Length) $pwTot
    }

    if ($AudioMode -eq 'off' -or $AudioMode -eq 'none' -or $AudioMode -eq '') {
        Set-Cell $prows 20 0 ($c.Warn + 'AUDIO OFF' + $c.R) (9) $pwTot
    } elseif ($S.Od -gt 0) {
        Set-Cell $prows 20 0 ($c.Od + ('OVERDRIVE {0:N1}s' -f $S.Od) + $c.R) (15) $pwTot
    } elseif ($S.OdReady) {
        Set-Cell $prows 20 0 ($c.Ok + 'SPACE = OVERDRIVE' + $c.R) (18) $pwTot
    } else {
        Set-Cell $prows 20 0 ($c.Dim + ('audio: ' + $AudioMode) + $c.R) (6 + $AudioMode.Length) $pwTot
    }

    # ---------------- count-in ---------------------------------------------
    if ($Pos -lt $Meta.LeadIn -and $count -gt 0) {
        $beat = $Meta.Beat
        $left2 = [Math]::Ceiling(($Meta.LeadIn - $Pos) / $beat)
        $msg = 'GET READY'
        $col = $c.Title
        if ($left2 -le 0)      { $msg = 'ROCK!'; $col = $c.Od }
        elseif ($left2 -le 3) { $msg = [string][int]$left2; $col = $c.Sel }
        $block = $g.empty * $pw
        for ($k = $top; $k -le ($top + 4); $k++) {
            Set-Cell $prows $k 2 $block $pw $pwTot
        }
        $mid = $top + 2
        $mx = 2 + [int](($pw - $msg.Length) / 2)
        if ($mx -lt 0) { $mx = 0 }
        Set-Cell $prows $mid $mx ($col + $msg + $c.R) $msg.Length $pwTot
    }

    # ---- compose: lanes + notes on the left, panel on the right -------------
    # both halves are padded to a fixed visible width and carry no escape run
    # across the seam, so this is a plain concatenation: no per-frame scanning.
    for ($r = $top; $r -le $hit; $r++) {
        if ($r -lt 0 -or $r -ge $h) { continue }
        $lines[$r] = $lines[$r] + $prows[$r]
    }

    # ---------------- bottom rows ------------------------------------------
    $r1 = $hit + 1
    if ($r1 -lt $h) {
        $keysTxt = ''
        $keysPlain = 0
        for ($l = 0; $l -lt $script:LANES; $l++) {
            $keysTxt  += $c.Label + ([string]($l + 1)) + $c.R + $c.Val + $g.note + $c.R + '  '
            $keysPlain += 4
        }
        $keysTxt   += $c.Dim + 'or ' + $c.R + $c.Label + 'A S D F G' + $c.R
        $keysPlain += 12
        Set-Cell $lines $r1 $script:HWLEFT $keysTxt $keysPlain
    }

    $r2 = $hit + 2
    if ($r2 -lt $h) {
        $age = $Pos - $S.JudAt
        if ($age -ge 0 -and $age -lt 0.65 -and $S.Judgement -gt '') {
            $col = $c[$S.JudColor]
            if ($null -eq $col) { $col = $c.Nrm }
            $txt = $col + '  ' + $S.Judgement + '  ' + $c.R + $c.Dim + 'x' + $mult + $c.R
            Set-Cell $lines $r2 ($script:HWLEFT + 6) $txt (4 + $S.Judgement.Length + 2)
        } else {
            Set-Cell $lines $r2 0 '' 0
        }
    }

    $r3 = $hit + 3
    if ($r3 -lt $h) {
        $frac = 0.0
        if ($Meta.Total -gt 0) { $frac = $Pos / $Meta.Total }
        if ($frac -lt 0) { $frac = 0 }
        if ($frac -gt 1) { $frac = 1 }
        $bw = $w - 22
        if ($bw -lt 8) { $bw = 8 }
        $barCol = $c.Bar
        if ($S.Od -gt 0) { $barCol = $c.Od }
        $pct = '{0,4:N0}%' -f ($frac * 100)
        Set-Cell $lines $r3 2 ($barCol + (Get-Bar $frac $bw) + $c.R + ' ' + $c.Label + $pct + $c.R) ($bw + 1 + $pct.Length)
    }

    $r4 = $hit + 4
    if ($r4 -lt $h) {
        $t = $c.Dim + 'ESC pause' + $c.R + $c.Label + '    strike as a note touches the line' + $c.R
        Set-Cell $lines $r4 2 $t (9 + 4 + 34)
    }

    return $lines
}

# ============================================================================
#  GAME RULES
#  These are plain functions of (score state, chart, position) so the whole
#  judgement / hold / meter / fail system can be driven head-less by -SelfTest.
# ============================================================================
function Invoke-Hit {
    # a lane was struck at time $pos
    param($S, $Chart, [double]$Pos, [int]$Lane)
    if ($Lane -lt 0 -or $Lane -ge $script:LANES) { return }
    $best = -1; $bd = 9.0e9
    for ($j = $S.Cur[$Lane]; $j -lt $Chart.Count; $j++) {
        $n = $Chart[$j]
        $dt = $n.T - $Pos
        if ($dt -gt $script:WMiss) { break }
        if ($n.Judged) { continue }
        if ($n.Lane -ne $Lane) { continue }
        $ad = [Math]::Abs($dt)
        if ($ad -lt $bd) { $bd = $ad; $best = $j }
    }
    if ($best -lt 0) { return }

    $n = $Chart[$best]
    $n.Judged = $true
    $n.Offset = $n.T - $Pos
    $jt = Get-Judgement $n.Offset
    switch ($jt) {
        'PERFECT' { $S.Perfect++; $S.Meter += 0.017; Add-Score $S 300 $n.Offset; $S.JudColor = 'Perf' }
        'GREAT'   { $S.Great++;   $S.Meter += 0.012; Add-Score $S 200 $n.Offset; $S.JudColor = 'Great' }
        'GOOD'    { $S.Good++;    $S.Meter += 0.007; Add-Score $S 100 $n.Offset; $S.JudColor = 'Good' }
    }
    $S.Judged++
    $S.Judgement = $jt; $S.JudAt = $Pos
    if ($n.Hold -gt 0.06) { $S.HoldN[$Lane] = $n }
    else {
        $S.Combo++
        if ($S.Combo -gt $S.MaxCombo) { $S.MaxCombo = $S.Combo }
    }
    if ($S.Meter -ge 1.0) { $S.Meter = 1.0; $S.OdReady = $true }
}

function Step-LaneCursors {
    # keep each lane's cursor on the next note that could still be struck
    param($S, $Chart, [double]$Pos)
    for ($l = 0; $l -lt $script:LANES; $l++) {
        while ($S.Cur[$l] -lt $Chart.Count) {
            $cn = $Chart[$S.Cur[$l]]
            if ($cn.Lane -eq $l -and -not $cn.Judged) { break }
            if ($cn.T -gt ($Pos + 1.0)) { break }
            $S.Cur[$l]++
        }
    }
}

# The player is out when the misses he allowed himself run out.  A dropped
# hold counts as a miss, exactly like it does in the real thing.  With
# $script:FailMisses = 0 there is no limit at all and the song can only end
# when the last note is done.
function Get-StrikeLeft {
    param($S)
    if ($script:FailMisses -le 0) { return -1 }
    return ($script:FailMisses - ($S.Miss + $S.HoldDrop))
}

function Test-RockOut {
    param($S)
    if ($script:FailMisses -le 0) { return $false }
    return (($S.Miss + $S.HoldDrop) -ge $script:FailMisses)
}

function Kill-Player {
    param($S)
    $S.Meter = 0; $S.Failed = $true; $S.Done = $true
}

function Step-Misses {
    param($S, $Chart, [double]$Pos)
    while ($S.Idx -lt $Chart.Count -and ($Chart[$S.Idx].T - $Pos) -lt (-$script:WMiss)) {
        $n = $Chart[$S.Idx]
        if (-not $n.Judged) {
            $n.Judged = $true
            $S.Miss++; $S.Judged++
            $S.Combo = 0
            $S.Meter -= 0.062
            $S.Judgement = 'MISS'; $S.JudAt = $Pos; $S.JudColor = 'Miss'
            if (Test-RockOut $S) { Kill-Player $S }
        }
        $S.Idx++
    }
}

function Step-Holds {
    param($S, [double]$Pos)
    for ($l = 0; $l -lt $script:LANES; $l++) {
        $n = $S.HoldN[$l]
        if ($null -eq $n) { continue }
        $end = $n.T + $n.Hold
        if ($Pos -ge ($end - 0.025)) {
            $S.Holds++
            $S.Meter += 0.012
            $S.Combo++
            if ($S.Combo -gt $S.MaxCombo) { $S.MaxCombo = $S.Combo }
            Add-Score $S (120 + [int]($n.Hold * 240)) 0.0
            $S.Judgement = 'HOLD'; $S.JudAt = $Pos; $S.JudColor = 'Hold'
            $S.HoldN[$l] = $null
            if ($S.Meter -ge 1.0) { $S.Meter = 1.0; $S.OdReady = $true }
        } elseif (-not $S.Down[$l]) {
            $S.HoldDrop++
            $S.Combo = 0
            $S.Meter -= 0.030
            $S.Judgement = 'DROPPED'; $S.JudAt = $Pos; $S.JudColor = 'Miss'
            $S.HoldN[$l] = $null
            if (Test-RockOut $S) { Kill-Player $S }
        } elseif (($Pos - $end) -gt 0.6) {
            $S.HoldN[$l] = $null
        }
    }
}

function Step-Meter {
    param($S, [int]$Frame)
    if ($S.Od -gt 0) {
        if (($Frame % 2) -eq 0) { $S.Od -= 1.0 / 30.0 }
        if ($S.Od -le 0) { $S.Od = 0; $S.Meter = 0.92; $S.OdReady = $false }
    } else {
        $S.Meter -= 0.0006
        if ($S.Meter -lt 0) { $S.Meter = 0 }
    }
}

function Invoke-Overdrive {
    param($S, [double]$Pos)
    if (-not $S.OdReady -or $S.Od -gt 0) { return $false }
    $S.Od = 8.0; $S.OdReady = $false; $S.Meter = 1.0
    $S.Judgement = 'OVERDRIVE'; $S.JudAt = $Pos; $S.JudColor = 'Od'
    return $true
}

# ============================================================================
#  THE GAME LOOP
# ============================================================================
function Invoke-Game {
    param([int]$SongIndex, [string]$DiffName)

    $song = $script:Catalog[$SongIndex]
    $meta = Get-SongMeta $song
    $df   = Get-Difficulty $DiffName
    Set-Screen

    # ---- build the band -------------------------------------------------
    $lines = New-BlankLines
    # keep the status line on a row the console actually has, otherwise a short
    # window shows a blank screen for as long as the band takes to synthesise
    $brow = 10
    if ($brow -gt ($script:H - 2)) { $brow = [Math]::Max(0, $script:H - 2) }
    $bcol = [Math]::Max(0, [int](($script:W - 22) / 2))
    Set-Cell $lines $brow $bcol ($script:C.Title + 'building the band...' + $script:C.R) 21
    Write-Screen $lines
    try { [Console]::Out.Flush() } catch { }

    $aud = $null; $chart = $null; $err = $null
    $bw = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (Test-CustomSong $song) {
            # the chart comes out of the recording itself, and the recording is
            # what plays: nothing is synthesised for these songs
            $cErr = ''
            $ce = [ref]$cErr
            $null = Get-CustomAnalysis $song $ce
            if ($cErr) { throw $cErr }
            # a file from the music folder can end up with no notes at all, and
            # @() keeps that an empty list instead of nothing
            $chart = @(Get-Chart $song $meta $DiffName)
            if ($chart.Count -eq 0) { throw 'no notes could be placed in this recording' }
            $meta = Get-SongMeta $song
        } else {
            $ev = New-SongEvents $song $meta
            $aud = [RockHero.Synth]::Render($ev, $meta.Total)
            $chart = @(Get-Chart $song $meta $DiffName)
            if ($chart.Count -eq 0) { throw 'chart is empty' }
        }
    } catch {
        $err = $_.Exception.Message
    }
    $bw.Stop()

    if ($err) {
        Set-Screen
        $items = @('BACK')
        $null = Show-Menu -Title 'AUDIO ERROR' -Sub $err -Items $items `
            -DrawRow { param($i, $s)
                if ($s) { return $script:C.Sel + $script:G.arrow + ' BACK' + $script:C.R }
                return '   BACK' }
        return 'back'
    }

    # ---- start the song --------------------------------------------------
    $S  = New-ScoreState $chart
    $audioMode = 'off'
    if (-not $script:NoAudio -and $null -ne $script:Music) {
        try {
            if (Test-CustomSong $song) {
                $ok = $false
                try { $ok = [bool]$script:Music.PlayFile($song.Path) } catch { $ok = $false }
                if ($ok) {
                    $script:Music.Volume = $script:Vol
                    $audioMode = 'file'
                    $dur = [double]$script:Music.Duration
                    if ($dur -gt 0.2) {
                        $meta.Total = [double]$meta.LeadIn + $dur + 2.0
                        $song.Duration = $dur
                    }
                } else {
                    $audioMode = 'off'
                }
            } else {
                $script:Music.Play($aud.Pcm, [int]$aud.Rate)
                $script:Music.Volume = $script:Vol
                $audioMode = $script:Music.Mode
            }
        } catch { $audioMode = 'off' }
    }
    if ($audioMode -eq 'none') { $audioMode = 'off' }
    if ($audioMode -ne 'off' -and $audioMode -notlike 'sound*') {
        # be honest about a driver that opens but produces no sound at all,
        # otherwise the panel just says "audio: waveOut" and looks healthy.
        # The probe only exercises waveOut, so skip it when MCI is the backend.
        $probe = Get-AudioDiag
        if ($probe -match 'silent|refused|no audio device') { $audioMode = $audioMode + ' NO SOUND' }
    }

    $travel = $script:BaseTravel / ($df.Speed * $script:SpScale)
    $nRows  = ($script:HITROW - $script:HWTOP) + 1
    if ($nRows -lt 4) { $nRows = 4 }
    $invRow = $nRows / $travel
    $lastT  = $chart[$chart.Count - 1].T
    $endAt  = $meta.Total
    if (($lastT + 3.0) -gt $endAt) { $endAt = $lastT + 3.0 }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $frame = 0
    $pauseOffset = 0.0
    # The note timeline follows the sound, but never at the cost of a frozen
    # screen: if the device position stops moving while the wall clock does not,
    # the song carries on driven by the stopwatch.
    $useClock  = ($audioMode -eq 'off')
    $audioPos  = 0.0
    $audioSeen = 0.0

    while ($true) {
        $f0 = $sw.Elapsed.TotalMilliseconds

        if (-not $useClock) {
            $wall = $sw.Elapsed.TotalSeconds - $pauseOffset
            $ap = -1.0
            try { $ap = [double]$script:Music.Position } catch { $ap = -1.0 }
            if ($ap -lt 0) {
                $useClock = $true
            } elseif ($ap -gt ($audioPos + 0.002)) {
                $audioPos = $ap; $audioSeen = $wall
            } elseif (($wall - $audioSeen) -gt 0.75) {
                $useClock = $true
            }
            if ($useClock) { $audioMode = $audioMode + '+clock' }
        }
        if ($useClock) { $pos = $sw.Elapsed.TotalSeconds - $pauseOffset }
        else           { $pos = $audioPos }
        if ($pos -lt 0) { $pos = 0 }

        # ---------------- input -------------------------------------------
        foreach ($k in (Read-Keys)) {
            if ($k.Key -eq 'Escape') {
                $tPause = $sw.Elapsed.TotalSeconds
                $act = Show-Pause
                if ($act -eq 'list')  { $S.Done = $true; break }
                if ($act -eq 'main')  { $S.Done = $true; $script:ForceMain = $true; break }
                if ($act -eq 'restart') {
                    try { if ($script:Music) { $script:Music.Stop() } } catch { }
                    return 'restart'
                }
                if ($useClock) { $pauseOffset += $sw.Elapsed.TotalSeconds - $tPause }
                else { $audioSeen = $sw.Elapsed.TotalSeconds - $pauseOffset }
                continue
            }
            if ($k.Key -eq 'Space') {
                $null = Invoke-Overdrive $S $pos
                continue
            }
            $lane = Get-LaneFromKey $k
            if ($lane -lt 0) { continue }
            if ($k.Key -eq 'KeyUp') { $S.Down[$lane] = $false; continue }

            $S.Down[$lane] = $true
            $S.Flash[$lane] = $pos
            Invoke-Hit $S $chart $pos $lane
        }

        Step-LaneCursors $S $chart $pos
        Step-Misses     $S $chart $pos
        Step-Holds      $S $pos
        Step-Meter      $S $frame

        if ($pos -ge $endAt) { $S.Done = $true }
        if ($S.Failed) { $S.Done = $true }

        Write-Screen (New-GameFrame $S $song $df $pos $invRow $audioMode $meta)
        $frame++

        if ($S.Done) { break }

        # ---------------- frame pacing ------------------------------------
        $el = $sw.Elapsed.TotalMilliseconds - $f0
        $rem = $script:FrameMs - $el
        if ($rem -gt 2.0) {
            [Threading.Thread]::Sleep([int]($rem - 1.0))
        } elseif ($rem -gt 0.3) {
            $sp = [Diagnostics.Stopwatch]::StartNew()
            while ($sp.Elapsed.TotalMilliseconds -lt $rem) { }
        }
    }

    try { if ($script:Music) { $script:Music.Stop() } } catch { }
    $rv = Show-Results $SongIndex $DiffName $S $song $df
    if ($rv -eq 'main') { return 'main' }
    if ($rv -eq 'retry') { return 'restart' }
    return 'back'
}

# ============================================================================
#  PAUSE
# ============================================================================
function Show-Pause {
    while ($true) {
        if ($script:Music) { $script:Music.Pause() }
        Set-Screen
        $items = @('RESUME', 'RESTART SONG', 'SONG LIST', 'MAIN MENU')
        $sel = Show-Menu -Title 'PAUSED' -Sub 'the song is waiting' -Items $items `
            -DrawRow {
                param($i, $s)
                $mark = if ($s) { $script:C.Sel + $script:G.arrow + ' ' } else { '   ' }
                $col  = if ($s) { $script:C.Sel } else { $script:C.Nrm }
                return $mark + $col + $items[$i] + $script:C.R
            } `
            -DrawFoot { $script:C.Label + 'ESC resumes' + $script:C.R }
        if ($null -ne $script:Music) { $script:Music.Resume() }
        if ($sel -eq -1 -or $sel -eq 0) { return 'resume' }
        if ($sel -eq 1) { return 'restart' }
        if ($sel -eq 2) { return 'list' }
        if ($sel -eq 3) { return 'main' }
    }
}

# ============================================================================
#  RESULTS
# ============================================================================
function Show-Results {
    param([int]$SongIndex, [string]$DiffName, $S, $Song, $Df)

    $acc  = Get-Accuracy $S.Perfect $S.Great $S.Good $S.Miss
    $rank = Get-Rank $acc
    $stars = Get-Stars $acc
    $rec = [pscustomobject]@{
        Score = $S.Score; Combo = $S.MaxCombo; Acc = $acc; Rank = $rank
        Stars = $stars; When = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Diff = $DiffName; Song = $Song.Title; Band = $Song.Band
        Perfect = $S.Perfect; Great = $S.Great; Good = $S.Good; Miss = $S.Miss
    }
    $isNew = Set-ScoreFor $SongIndex $DiffName $rec
    if ($isNew) { Save-Scores | Out-Null }

    Set-Screen
    while ($true) {
        $lines = New-BlankLines
        $c = $script:C; $g = $script:G
        $w = $script:W

        $head = if ($S.Failed) { 'YOU ROCKED OUT' } else { 'RESULTS' }
        $pad = [int][Math]::Max(0, [int](($w - $head.Length) / 2))
        Set-Cell $lines 1 $pad ($c.Title + $head + $c.R) $head.Length
        Set-Cell $lines 2 4 ($c.Label + ('{0} - {1}   [{2}]' -f $Song.Band, $Song.Title, $Df.Pt) + $c.R) 40

        # rank block
        $rankCol = $c.Title
        if ($rank -eq 'D' -or $rank -eq 'C') { $rankCol = $c.Miss }
        elseif ($rank -eq 'A' -or $rank -eq 'B') { $rankCol = $c.Good }
        $rw = [Math]::Max(0, [int](($w - 10) / 2))
        Set-Cell $lines 5 $rw ($rankCol + ('  ' + $rank + '  ') + $c.R) ($rank.Length + 4)
        $starTxt = ($g.dot * $stars) + ($g.empty * (5 - $stars))
        Set-Cell $lines 6 ($rw - 1) ($c.Title + $starTxt + $c.R) 5

        $stats = @(
            @('SCORE',    ('{0,10}' -f $S.Score),      11),
            @('ACCURACY', ('{0,9:N2}%' -f ($acc * 100)), 12),
            @('MAX COMBO',('{0,10}' -f $S.MaxCombo),     11),
            @('PERFECT',  ('{0,10}' -f $S.Perfect),      10),
            @('GREAT',    ('{0,10}' -f $S.Great),        10),
            @('GOOD',     ('{0,10}' -f $S.Good),         10),
            @('MISS',     ('{0,10}' -f $S.Miss),         10),
            @('HOLDS',    ('{0,10}  ({1} dropped)' -f $S.Holds, $S.HoldDrop), 25)
        )
        $lw = 10
        $sx = 4
        $row = 9
        foreach ($st in $stats) {
            $label = [string]$st[0]
            $value = [string]$st[1]
            $vlen  = [int]$st[2]
            Set-Cell $lines $row $sx ($c.Label + ('{0,-' + $lw + '}') -f $label) $lw
            $vc = $c.Val
            if ($label -eq 'MISS' -and $S.Miss -gt 0) { $vc = $c.Miss }
            if ($label -eq 'PERFECT') { $vc = $c.Perf }
            if ($label -eq 'GREAT')   { $vc = $c.Great }
            Set-Cell $lines $row ($sx + $lw + 2) ($vc + $value + $c.R) ($vlen + 2)
            $row++
        }

        if ($isNew) {
            Set-Cell $lines $row 4 ($c.Ok + '>> NEW HIGH SCORE <<' + $c.R) 22
        } else {
            $best = Get-ScoreFor $SongIndex $DiffName
            if ($best) {
                Set-Cell $lines $row 4 ($c.Label + ('best {0}  [{1}]' -f $best.Score, $best.Rank) + $c.R) 22
            }
        }
        $row++
        Set-Cell $lines $row 4 ($c.Label + 'ENTER = song list    ESC = main menu    R = retry' + $c.R) 48

        Write-Screen $lines
        $k = Wait-Key
        if ($null -eq $k) { return 'list' }
        if ($k.Key -eq 'Enter' -or $k.Key -eq 'Space') { return 'list' }
        if ($k.Key -eq 'Escape') { return 'main' }
        $ch = [string]$k.KeyChar
        if ($ch -match '^[rR]$') { return 'retry' }
    }
}

# ============================================================================
#  SCREENS
# ============================================================================
$script:SplashLines = @(
    'A GUITAR-HERO-STYLE RHYTHM GAME  -  100% PURE POWERSHELL',
    '',
    'The guitar, the bass, the drums and every note you hit are synthesised',
    'at runtime by an engine compiled inside this script.  No samples, no',
    'downloads, no dependencies.',
    '',
    'KEYS',
    '   1 2 3 4 5        strike lane 1 to 5',
    '   A S D F G        the same five lanes, left hand',
    '   SPACE            activate OVERDRIVE when the ROCK meter is full',
    '   ESC              pause / go back          ENTER  confirm',
    '',
    'SCORING',
    '   PERFECT 300    GREAT 200    GOOD 100    x1 .. x5 combo multiplier',
    '   Long notes: keep the lane pressed for the whole tail or you lose the combo.',
    '   The ROCK meter fills on hits and drains on misses.  Fill it, then press',
    '   SPACE: OVERDRIVE doubles your score for eight seconds.  Let it hit zero',
    '   and you rock out.',
    '',
    'THE MUSIC',
    '   Every riff is an original composition written in the style of the band',
    '   it is credited to - a playable tribute, not a recording.',
    '',
    'PRESS ENTER to continue...'
)

function Show-Splash {
    Set-Screen
    $title = 'R O C K   H E R O'
    while ($true) {
        $lines = New-BlankLines
        $c = $script:C
        $pad = [int][Math]::Max(0, [int](($script:W - $title.Length) / 2))
        Set-Cell $lines 1 $pad ($c.Title + $title + $c.R) $title.Length
        $i = 0
        foreach ($l in $script:SplashLines) {
            $col = $c.Label
            if ($l -match '^(KEYS|SCORING|THE MUSIC)$') { $col = $c.Nrm }
            if ($l -match '^PRESS ENTER') { $col = $c.Ok }
            Set-Cell $lines (4 + $i) 4 ($col + $l + $c.R) $l.Length
            $i++
        }
        Write-Screen $lines
        $k = Wait-Key
        if ($null -eq $k) { return }
        if ($k.Key -eq 'Enter' -or $k.Key -eq 'Space') { return }
        $ch = [string]$k.KeyChar
        if ($ch -match '^[qQ]$') { return }
        if ($ch -match '^[sS]$') { return }
    }
}

function Show-SongListScreen {
    Show-SongTable
}

function Show-SongTable {
    # full scrollable song table
    Set-Screen
    $n = $script:Catalog.Count
    $perPage = [Math]::Max(6, $script:H - 9)
    $top = 0
    while ($true) {
        $lines = New-BlankLines
        $c = $script:C
        Set-Cell $lines 1 0 ($c.Title + '  ALL SONGS' + $c.R) 13
        Set-Cell $lines 2 0 ($c.Label + ('  {0} songs from {1} bands      page {2}/{3}' -f $n, (Get-BandCount), ([int]($top / $perPage) + 1), ([int][Math]::Ceiling($n / $perPage))) + $c.R) 60
        Set-Cell $lines 4 2 ($c.Label + ('  {0,3}  {1,-18} {2,-22} {3,4}  {4}' -f '#', 'BAND', 'TITLE', 'BPM', 'STYLE') + $c.R) 56
        for ($i = 0; $i -lt $perPage; $i++) {
            $idx = $top + $i
            if ($idx -ge $n) { break }
            $s = $script:Catalog[$idx]
            $txt = '  ' + ('{0,3}  {1,-18} {2,-22} {3,4}  {4}' -f ($idx + 1), $s.Band, $s.Title, $s.Bpm, $s.Style)
            Set-Cell $lines (5 + $i) 2 ($c.Nrm + $txt + $c.R) 55
        }
        Set-Cell $lines ($script:H - 2) 2 ($c.Label + 'UP/DOWN scroll   HOME/END jump   ESC back' + $c.R) 44
        Write-Screen $lines
        $k = Wait-Key
        if ($null -eq $k) { return }
        $kc = $k.Key
        if ($kc -eq 'Escape' -or $kc -eq 'Enter') { return }
        $ch = [string]$k.KeyChar
        if ($kc -eq 'DownArrow' -or $ch -match '^[sS]$') { $top++ }
        elseif ($kc -eq 'UpArrow' -or $ch -match '^[wW]$') { $top-- }
        elseif ($kc -eq 'PageDown') { $top += $perPage }
        elseif ($kc -eq 'PageUp')   { $top -= $perPage }
        elseif ($kc -eq 'Home') { $top = 0 }
        elseif ($kc -eq 'End')  { $top = $n }
        if ($top -lt 0) { $top = 0 }
        if ($top -gt $n) { $top = $n }
    }
}

function Show-Options {
    while ($true) {
        Set-Screen
        $items = @('Volume', 'Note speed', 'Misses to fail', 'Colour mode', 'Delete high scores', 'Back')
        $sel = Show-Menu -Title 'OPTIONS' -Sub 'LEFT / RIGHT to change a value' -Items $items `
            -DrawRow {
                param($i, $s)
                $mark = if ($s) { $script:C.Sel + $script:G.arrow + ' ' } else { '   ' }
                $col  = if ($s) { $script:C.Sel } else { $script:C.Nrm }
                $name = $items[$i]
                switch ($i) {
                    0 { return $mark + $col + ('{0,-20}' -f $name) + ' ' + $script:C.Bar + (Get-Bar ($script:Vol / 100.0) 20) + $script:C.R + '  ' + $script:C.Val + ('{0,3}' -f $script:Vol) + $script:C.R }
                    1 { return $mark + $col + ('{0,-20}' -f $name) + ' ' + $script:C.Bar + (Get-Bar (($script:SpScale - 0.5) / 1.5) 20) + $script:C.R + '  ' + $script:C.Val + ('{0,4:N2}x' -f $script:SpScale) + $script:C.R }
                    2 { return $mark + $col + ('{0,-20}' -f $name) + '   ' + $script:C.Val + (Get-FailLabel $script:FailMisses) + $script:C.R }
                    3 {
                        $m = 'no colour (ASCII)'
                        if (-not $script:Ascii) {
                            if ($script:Ansi) { $m = 'ANSI 256 colour' } else { $m = 'plain (console has no VT)' }
                        }
                        return $mark + $col + ('{0,-20}' -f $name) + '   ' + $script:C.Val + $m + $script:C.R
                    }
                    4 {
                        $cnt = $script:High.Count
                        return $mark + $col + ('{0,-20}' -f $name) + '   ' + $script:C.Dim + ('{0} record(s) stored' -f $cnt) + $script:C.R + $script:C.Warn + ' ENTER to wipe' + $script:C.R
                    }
                    default { return $mark + $col + $name + $script:C.R }
                }
            } `
            -DrawFoot {
                $t = 'ESC also leaves options'
                $d = Get-AudioDiag
                $room = $script:W - (2 + $t.Length + 3) - 1
                if ($room -lt 12) { $room = 12 }
                if ($d.Length -gt $room) { $d = $d.Substring(0, $room) }
                return $script:C.Label + $t + $script:C.R + '   ' + $script:C.Warn + $d + $script:C.R
            }
        if ($sel -eq -1 -or $sel -eq 5) { return }

        switch ($sel) {
            0 {
                $v = $script:Vol
                while ($true) {
                    $k = Wait-Key; if ($null -eq $k) { break }
                    $ch = [string]$k.KeyChar
                    if ($k.Key -eq 'LeftArrow' -or $ch -eq '[') { $v = [Math]::Max(0, $v - 5) }
                    elseif ($k.Key -eq 'RightArrow' -or $ch -eq ']') { $v = [Math]::Min(100, $v + 5) }
                    else { break }
                    $script:Vol = $v; Apply-Volume; Play-Blip 0
                    $done = Show-OptionsBar $sel $v
                    if ($done) { break }
                }
                return
            }
            1 {
                $v = $script:SpScale
                while ($true) {
                    $k = Wait-Key; if ($null -eq $k) { break }
                    $ch = [string]$k.KeyChar
                    if ($k.Key -eq 'LeftArrow' -or $ch -eq '[') { $v = [Math]::Max(0.5, $v - 0.05) }
                    elseif ($k.Key -eq 'RightArrow' -or $ch -eq ']') { $v = [Math]::Min(2.0, $v + 0.05) }
                    else { break }
                    $script:SpScale = [Math]::Round($v, 2); Play-Blip 0
                    if (Show-OptionsBar $sel $v) { break }
                }
                return
            }
            2 {
                # cycle the strike budget: fewer misses left = harder
                $lad = $script:FailLadder
                $v = $script:FailMisses
                while ($true) {
                    $k = Wait-Key; if ($null -eq $k) { break }
                    $ch = [string]$k.KeyChar
                    if ($k.Key -eq 'LeftArrow' -or $ch -eq '[') {
                        $i2 = $lad.IndexOf($v); if ($i2 -lt 0) { $i2 = 0 }
                        $v = $lad[[Math]::Max(0, $i2 - 1)]
                    } elseif ($k.Key -eq 'RightArrow' -or $ch -eq ']') {
                        $i2 = $lad.IndexOf($v); if ($i2 -lt 0) { $i2 = 0 }
                        $v = $lad[[Math]::Min($lad.Count - 1, $i2 + 1)]
                    } else { break }
                    $script:FailMisses = $v; Save-Settings | Out-Null
                    if ($v -le 3) { Play-Blip 2 } else { Play-Blip 0 }
                    if (Show-OptionsBar $sel $v) { break }
                }
                return
            }
            3 {
                $script:Ascii = -not $script:Ascii
                New-GlyphTable; New-ColorTable; Set-Screen
                continue
            }
            4 {
                $items2 = @('CANCEL', 'YES - ERASE EVERY RECORD')
                $r2 = Show-Menu -Title 'ERASE SCORES?' -Sub 'this cannot be undone' -Items $items2 `
                    -DrawRow {
                        param($i, $s)
                        $mark = if ($s) { $script:C.Sel + $script:G.arrow + ' ' } else { '   ' }
                        $col = if ($s) { $script:C.Sel } else { $script:C.Nrm }
                        return $mark + $col + $items2[$i] + $script:C.R
                    }
                if ($r2 -eq 1) { $script:High = @{}; Save-Scores | Out-Null; Play-Blip 2 }
                continue
            }
        }
    }
}

function Show-OptionsBar {
    param([int]$Which, [double]$Value)
    Set-Screen
    $items = @('Volume', 'Note speed', 'Misses to fail', 'Colour mode', 'Delete high scores', 'Back')
    $lines = New-BlankLines
    $c = $script:C
    Set-Cell $lines 1 0 ($c.Title + '  OPTIONS' + $c.R) 13
    Set-Cell $lines 2 0 ($c.Label + 'LEFT / RIGHT to change, ENTER to accept' + $c.R) 44
    for ($i = 0; $i -lt $items.Count; $i++) {
        $mark = if ($i -eq $Which) { $c.Sel + $c.R + $script:G.arrow + ' ' } else { '   ' }
        $col = if ($i -eq $Which) { $c.Sel } else { $c.Nrm }
        $val = ''
        switch ($i) {
            0 { $val = ' ' + $c.Bar + (Get-Bar ($script:Vol / 100.0) 20) + $c.R + '  ' + $c.Val + ('{0,3}' -f $script:Vol) + $c.R; $pl = 26 }
            1 { $val = ' ' + $c.Bar + (Get-Bar (($script:SpScale - 0.5) / 1.5) 20) + $c.R + '  ' + $c.Val + ('{0,4:N2}x' -f $script:SpScale) + $c.R; $pl = 27 }
            2 { $val = '   ' + $c.Val + (Get-FailLabel $script:FailMisses) + $c.R; $pl = 30 }
            3 { $val = '   ' + $c.Val + $(if ($script:Ascii) { 'no colour (ASCII)' } else { 'ANSI 256 colour' }) + $c.R; $pl = 20 }
            4 { $val = '   ' + $c.Warn + 'ENTER to wipe' + $c.R; $pl = 15 }
            default { $val = ''; $pl = 0 }
        }
        Set-Cell $lines (4 + $i) 2 ($mark + $col + ('{0,-20}' -f $items[$i]) + $val + $c.R) (22 + $pl)
    }
    Write-Screen $lines
    return $false
}

function Show-SongSelect {
    while ($true) {
        Set-Screen
        $n = $script:Catalog.Count
        $items = New-Object 'string[]' $n
        for ($i = 0; $i -lt $n; $i++) { $items[$i] = 'x' }
        $sel = Show-Menu -Title 'CHOOSE A SONG' -Sub 'UP/DOWN pick    ENTER play    ESC back' -Items $items `
            -DrawRow {
                param($i, $s)
                $sg = $script:Catalog[$i]
                $mark = if ($s) { $script:C.Sel + $script:G.arrow + ' ' } else { '   ' }
                $col  = if ($s) { $script:C.Sel } else { $script:C.Nrm }
                $band = $sg.Band;  if ($band.Length -gt 18) { $band = $band.Substring(0, 18) }
                $ttl  = $sg.Title; if ($ttl.Length -gt 24) { $ttl = $ttl.Substring(0, 24) }
                $rec = Get-ScoreFor $i $script:Difficulty[0].Name
                $rt = '     -   '
                if ($null -ne $rec) { $rt = ('{0,7} {1,-3}' -f $rec.Score, $rec.Rank) }
                return $mark + $col + ('{0,3} ' -f ($i + 1)) + ('{0,-18} ' -f $band) + ('{0,-24} ' -f $ttl) +
                       $script:C.Label + ('{0,4} ' -f $sg.Bpm) + $script:C.Dim + ('{0,-7}' -f $sg.Style) +
                       $script:C.Val + ('  ' + $rt + ' ') + $script:C.R
            } `
            -DrawFoot { $script:C.Label + 'ESC returns to the main menu' + $script:C.R }
        if ($sel -lt 0) { return 'back' }

        $diff = Show-Difficulty $sel
        if ($null -eq $diff) { continue }
        $r = Invoke-Game $sel $diff
        if ($r -eq 'main') { $script:ForceMain = $false; return 'main' }
        if ($r -eq 'restart') { $r = Invoke-Game $sel $diff }
        if ($r -eq 'main') { return 'main' }
    }
}

function Show-Difficulty {
    param([int]$SongIndex)
    while ($true) {
        Set-Screen
        $items = New-Object 'string[]' $script:Difficulty.Count
        for ($i = 0; $i -lt $script:Difficulty.Count; $i++) { $items[$i] = $script:Difficulty[$i].Name }
        $sg = $script:Catalog[$SongIndex]
        $sel = Show-Menu -Title 'DIFFICULTY' -Sub ('{0} - {1}' -f $sg.Band, $sg.Title) -Items $items `
            -DrawRow {
                param($i, $s)
                $df = $script:Difficulty[$i]
                $mark = if ($s) { $script:C.Sel + $script:G.arrow + ' ' } else { '   ' }
                $col  = if ($s) { $script:C.Sel } else { $script:C.Nrm }
                $rec = Get-ScoreFor $SongIndex $df.Name
                $rt = '   -  '
                if ($null -ne $rec) { $rt = ('{0,7} {1,-3}' -f $rec.Score, $rec.Rank) }
                return $mark + $col + ('{0,-7}' -f $df.Pt) + $script:C.Label + ('{0,-32}' -f $df.Desc) +
                       $script:C.Val + ('  {0}' -f $rt) + $script:C.R
            } `
            -DrawFoot { $script:C.Label + 'ESC goes back to the song list' + $script:C.R }
        if ($sel -lt 0) { return $null }
        return $script:Difficulty[$sel].Name
    }
}

function Invoke-MainMenu {
    while ($true) {
        $script:ForceMain = $false
        Set-Screen
        $items = @('PLAY', 'HOW TO PLAY', 'ALL SONGS', 'OPTIONS', 'RUN SELF-TEST', 'QUIT')
        $sel = Show-Menu -Title 'R O C K   H E R O' -Sub 'a PowerShell tribute' -Items $items `
            -DrawRow {
                param($i, $s)
                $mark = if ($s) { $script:C.Sel + $script:G.arrow + ' ' } else { '   ' }
                $col  = if ($s) { $script:C.Sel } else { $script:C.Nrm }
                $extra = ''
                if ($i -eq 0) { $extra = $script:C.Label + ('   {0} songs / {1} bands' -f $script:Catalog.Count, (Get-BandCount)) + $script:C.R }
                if ($i -eq 5) { $extra = $script:C.Dim + '   ESC' + $script:C.R }
                return $mark + $col + ('{0,-20}' -f $items[$i]) + $extra + $script:C.R
            } `
            -DrawFoot { $script:C.Label + 'ESC or Q to quit' + $script:C.R }

        if ($sel -lt 0 -or $sel -eq 5) { return 'quit' }
        switch ($sel) {
            0 {
                $r = Show-SongSelect
                if ($r -eq 'main') { return 'menu' }
            }
            1 { Show-Splash }
            2 { Show-SongTable }
            3 { Show-Options }
            4 { Run-SelfTestScreen }
        }
    }
}

# ============================================================================
#  SELF TEST
# ============================================================================
$script:TPass = 0
$script:TFail = 0
$script:TLog  = New-Object System.Collections.ArrayList

function T-Result {
    param([bool]$Ok, [string]$Name, [string]$Detail = '')
    if ($Ok) {
        $script:TPass++
        [void]$script:TLog.Add(@($true, $Name, ''))
    } else {
        $script:TFail++
        [void]$script:TLog.Add(@($false, $Name, $Detail))
        Write-Host ("  FAIL  " + $Name + $(if ($Detail) { "  ->  " + $Detail } else { '' })) -ForegroundColor Red
    }
}

function T-Is {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    T-Result $Cond $Name $Detail
}

function T-Throws {
    param([scriptblock]$Block, [string]$Name)
    $threw = $false
    try { $null = & $Block } catch { $threw = $true }
    T-Result $threw $Name 'expected an exception but none was thrown'
}

function T-NoThrow {
    param([scriptblock]$Block, [string]$Name)
    $msg = ''
    $ok = $true
    try { $null = & $Block } catch { $ok = $false; $msg = $_.Exception.Message }
    T-Result $ok $Name $msg
}

# same check, but the value the block produced is left in $script:TVal so the
# caller can look at it (an assignment inside a plain scriptblock would not
# survive the scope)
function T-Try {
    param([scriptblock]$Block, [string]$Name)
    $script:TVal = $null
    $script:TOk = $true
    $script:TErr = ''
    try { $script:TVal = & $Block } catch { $script:TOk = $false; $script:TErr = $_.Exception.Message }
    T-Result $script:TOk $Name $script:TErr
    return $script:TOk
}

function Test-ValidBar {
    param([string]$Pattern, [string]$Name)
    $rx = [regex]::new($Pattern)
    return $rx.IsMatch($Name)
}

function Simulate-Play {
    param($Chart, [string]$Mode, [double]$Delta = 0.0, [int]$Seed = 7)
    $P = 0; $G = 0; $Gd = 0; $M = 0
    $rng = New-Object Random $Seed
    foreach ($n in $Chart) {
        $hit = $true
        if ($Mode -eq 'idle') { $hit = $false }
        elseif ($Mode -eq 'random') { $hit = ($rng.NextDouble() -lt 0.65) }
        if ($hit) {
            switch (Get-Judgement $Delta) {
                'PERFECT' { $P++ }
                'GREAT'   { $G++ }
                'GOOD'    { $Gd++ }
                default   { $M++ }
            }
        } else { $M++ }
    }
    return [pscustomobject]@{ P = $P; G = $G; Gd = $Gd; M = $M }
}

function New-TestChart {
    # every scenario needs its own note objects: Judged lives on the note
    param([switch]$WithHold)
    $l = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(@(1.0, 0), @(2.0, 1), @(3.0, 2), @(4.0, 3), @(5.0, 4), @(6.0, 1))) {
        $l.Add((New-ChartNote $p[0] $p[1] 0.0 0))
    }
    if ($WithHold) {
        $l.Clear()
        $l.Add((New-ChartNote 2.0 2 0.0 0))
        $l.Add((New-ChartNote 4.0 4 0.60 1))
    }
    return $l.ToArray()
}

function Invoke-SelfTest {
    $script:TPass = 0; $script:TFail = 0; $script:TLog = New-Object System.Collections.ArrayList
    Write-Host ''
    Write-Host '  ROCK HERO - SELF TEST' -ForegroundColor Yellow
    Write-Host '  ----------------------' -ForegroundColor DarkGray

    $SR = [int][RockHero.Synth]::SR

    # ---------------- engine ---------------------------------------------
    T-Is ($null -ne ('RockHero.Synth' -as [type])) 'engine type loaded'
    T-Is ($SR -eq 32000) 'sample rate is 32000' ("got $SR")

    foreach ($b in 0..3) {
        T-NoThrow { $null = [RockHero.Synth]::Blip($b) } "blip kind $b synthesises"
    }
    $b0 = [RockHero.Synth]::Blip(0)
    T-Is ($b0.Pcm.Length -gt 100) 'blip produces samples' ("len=$($b0.Pcm.Length)")
    T-Is (-not $b0.HasNaN) 'blip has no NaN samples'

    $empty = [RockHero.Synth]::Render((New-Object 'System.Collections.Generic.List[RockHero.Ev]'), 0.5)
    T-Is ($empty.Pcm.Length -gt 0) 'rendering an empty score still yields a buffer'
    T-Is (-not $empty.HasNaN) 'empty render has no NaN'
    T-Is ($empty.Peak -eq 0) 'empty render is silent' ("peak=$($empty.Peak)")

    $zero = [RockHero.Synth]::Render((New-Object 'System.Collections.Generic.List[RockHero.Ev]'), -5.0)
    T-Is ($zero.Seconds -gt 0.1) 'negative duration is clamped' ("sec=$($zero.Seconds)")

    $w = [RockHero.Synth]::WrapWav($empty)
    T-Is ($w.Length -eq ($empty.Pcm.Length + 44)) 'WAV header adds exactly 44 bytes'
    T-Is ([Text.Encoding]::ASCII.GetString($w, 0, 4) -eq 'RIFF') 'WAV starts with RIFF'
    T-Is ([Text.Encoding]::ASCII.GetString($w, 8, 4) -eq 'WAVE') 'WAV has WAVE type'
    T-Is ([Text.Encoding]::ASCII.GetString($w, 36, 4) -eq 'data') 'WAV has data chunk'
    $bits = [BitConverter]::ToInt16($w, 34)
    T-Is ($bits -eq 16) 'WAV is 16 bit'
    $ch = [BitConverter]::ToInt16($w, 22)
    T-Is ($ch -eq 1) 'WAV is mono'

    # ---------------- player ---------------------------------------------
    $p = [RockHero.Player]::new()
    T-NoThrow { $p.Play($null, 32000) } 'player tolerates a null buffer'
    T-Is ($p.Mode -eq 'silent' -or $p.Mode -eq 'none') 'player falls back safely on a null buffer' ("mode=$($p.Mode)")

    $tiny = New-Object 'byte[]' (32000 * 2)
    T-NoThrow { $p.Play($tiny, 32000) } 'player accepts a 1 second buffer'
    T-Is ($p.Duration -gt 0.9 -and $p.Duration -lt 1.1) 'player reports the right duration' ("dur=$($p.Duration)")
    $pos1 = $p.Position
    [Threading.Thread]::Sleep(120)
    $pos2 = $p.Position
    T-Is ($pos2 -ge $pos1) 'player position never goes backwards' ("$pos1 -> $pos2")
    T-NoThrow { $p.Volume = -50 } 'player clamps a negative volume'
    T-Is ($p.Volume -eq 0) 'volume clamps at 0' ("vol=$($p.Volume)")
    $p.Volume = 500
    T-Is ($p.Volume -eq 100) 'volume clamps at 100'
    T-NoThrow { $p.Pause(); $p.Resume(); $p.Stop() } 'pause/resume/stop do not throw'
    T-NoThrow { $p.Stop() } 'stop is idempotent'
    T-NoThrow { $p.Dispose(); $p.Dispose() } 'dispose is idempotent'

    # ---------------- catalogue -------------------------------------------
    $cat = $script:Catalog
    T-Is ($null -ne $cat -and $cat.Count -ge 20) 'catalogue has at least 20 songs' ("count=$(if ($cat) { $cat.Count } else { 0 })")

    $riffRx   = '^[.\-0-4]{16}$'
    $drumRx   = '^[.KksshHx]{16}$'
    $leadRx   = '^[.\-0-9]{16}$'
    $badRiff = @(); $badDrum = @(); $badLead = @()
    $badMeta = @(); $badProg = @(); $badBars = @()
$titles = @{}; $dupes = @()
    $nOwn = 0

    foreach ($s in $cat) {
        # a file from the player's own folder has no riff, and it is checked on
        # its own further down
        if (Test-CustomSong $s) { $nOwn++; continue }
        if ($titles.ContainsKey($s.Title + '|' + $s.Band)) { $dupes += ($s.Band + '/' + $s.Title) }
        $titles[$s.Title + '|' + $s.Band] = 1
        if ($s.Bpm -lt 40 -or $s.Bpm -gt 220) { $badMeta += ($s.Title + ' bpm=' + $s.Bpm) }
        if ($s.Root -lt 20 -or $s.Root -gt 80) { $badMeta += ($s.Title + ' root=' + $s.Root) }
        foreach ($r in $s.Riff)  { if (-not (Test-ValidBar $riffRx $r)) { $badRiff  += ($s.Title + ':[' + $r + ']') } }
        foreach ($r in $s.Drums) { if (-not (Test-ValidBar $drumRx $r)) { $badDrum  += ($s.Title + ':[' + $r + ']') } }
        foreach ($r in $s.Lead)  { if (-not (Test-ValidBar $leadRx $r)) { $badLead  += ($s.Title + ':[' + $r + ']') } }
        foreach ($p in $s.Prog) {
            $v = 0
            if (-not [int]::TryParse($p, [ref]$v)) { $badProg += ($s.Title + ':[' + $p + ']') }
            elseif ($v -lt -12 -or $v -gt 12) { $badProg += ($s.Title + ':[' + $p + ']') }
        }
        if ($s.Prog.Count -ne $s.Riff.Count)  { $badBars += ($s.Title + ' prog=' + $s.Prog.Count + ' riff=' + $s.Riff.Count) }
        if ($s.Drums.Count -ne $s.Riff.Count) { $badBars += ($s.Title + ' drums=' + $s.Drums.Count) }
        if ($s.Lead.Count -ne $s.Riff.Count)  { $badBars += ($s.Title + ' lead=' + $s.Lead.Count) }
        if ($s.Riff.Count -lt 1) { $badBars += ($s.Title + ' empty riff') }
    }
    T-Is ($badRiff.Count -eq 0) 'every riff bar is 16 valid characters' ($badRiff -join ', ')
    T-Is ($badDrum.Count -eq 0) 'every drum bar is 16 valid characters' ($badDrum -join ', ')
    T-Is ($badLead.Count -eq 0) 'every lead bar is 16 valid characters' ($badLead -join ', ')
    T-Is ($badProg.Count -eq 0) 'every progression value parses as a small semitone offset' ($badProg -join ', ')
    T-Is ($badMeta.Count -eq 0) 'tempo and key of every song are sane' ($badMeta -join ', ')
    T-Is ($badBars.Count -eq 0) 'prog/drums/lead bar counts match the riff' ($badBars -join ', ')
    T-Is ($dupes.Count -eq 0) 'no duplicate song titles' ($dupes -join ', ')

    # ---------------- music, charts, audio --------------------------------
    $badEv = @(); $badCh = @(); $badAud = @(); $slow = @()
    $swTot = [Diagnostics.Stopwatch]::StartNew()
foreach ($s in $cat) {
        if (Test-CustomSong $s) { continue }
        $meta = Get-SongMeta $s
        if (-not ($meta.Bars -gt 0 -and $meta.LeadIn -gt 0 -and $meta.Total -gt 0 -and $meta.Total -lt 900)) {
            $badEv += ($s.Title + ' meta')
        }
        $evs = New-SongEvents $s $meta
        if ($evs.Count -lt 20) { $badEv += ($s.Title + ' only ' + $evs.Count + ' events') }
        $badt = $false
        foreach ($e in $evs) {
            if ($e.T -lt -0.001 -or $e.T -gt ($meta.Total + 0.01)) { $badt = $true; break }
            if ($e.Midi -lt 12 -or $e.Midi -gt 108) { $badt = $true; break }
            if ($e.Kind -lt 0 -or $e.Kind -gt 6) { $badt = $true; break }
        }
        if ($badt) { $badEv += ($s.Title + ' event range') }

        $sw1 = [Diagnostics.Stopwatch]::StartNew()
        $aud = [RockHero.Synth]::Render($evs, $meta.Total)
        $sw1.Stop()
        if ($aud.HasNaN) { $badAud += ($s.Title + ' NaN') }
        if ($aud.Peak -lt 8000) { $badAud += ($s.Title + ' too quiet peak=' + $aud.Peak) }
        if ($aud.Peak -gt 32767) { $badAud += ($s.Title + ' clipping peak=' + $aud.Peak) }
        if ($aud.Rms -lt 0.02 -or $aud.Rms -gt 0.65) { $badAud += ($s.Title + ' rms=' + [Math]::Round($aud.Rms, 4)) }
        if ($aud.Pcm.Length -lt 1000) { $badAud += ($s.Title + ' no audio') }
        if ($sw1.ElapsedMilliseconds -gt 6000) { $slow += ($s.Title + ' ' + $sw1.ElapsedMilliseconds + 'ms') }

        $prevCount = -1
        foreach ($dn in $script:Difficulty) {
            $ch = Get-Chart $s $meta $dn.Name
            if ($null -eq $ch -or $ch.Count -eq 0) { $badCh += ($s.Title + '/' + $dn.Name + ' empty'); continue }
            if ($ch.Count -lt $prevCount) { $badCh += ($s.Title + '/' + $dn.Name + ' fewer notes than easier tier') }
            $prevCount = $ch.Count
            $sorted = $true; $lastT = -1.0; $laneLast = @{}
            foreach ($n in $ch) {
                if ($n.T -lt $lastT) { $sorted = $false }
                $lastT = $n.T
                if ($n.Lane -lt 0 -or $n.Lane -ge 5) { $badCh += ($s.Title + '/' + $dn.Name + ' lane=' + $n.Lane); break }
                if ($n.T -lt ($meta.LeadIn - 0.01)) { $badCh += ($s.Title + '/' + $dn.Name + ' before count-in'); break }
                if ($n.T -gt $meta.Total) { $badCh += ($s.Title + '/' + $dn.Name + ' past end'); break }
                if ($n.Hold -lt 0 -or $n.Hold -gt 1.35) { $badCh += ($s.Title + '/' + $dn.Name + ' hold=' + $n.Hold); break }
                if ($laneLast.ContainsKey($n.Lane)) {
                    if (($n.T - $laneLast[$n.Lane]) -lt 0.045) { $badCh += ($s.Title + '/' + $dn.Name + ' unhittable stack in lane ' + $n.Lane); break }
                }
                $laneLast[$n.Lane] = $n.T
            }
            if (-not $sorted) { $badCh += ($s.Title + '/' + $dn.Name + ' chart not sorted') }
        }
    }
    $swTot.Stop()
    T-Is ($badEv.Count -eq 0) 'event lists are valid and inside the song bounds' ($badEv -join '; ')
    T-Is ($badAud.Count -eq 0) 'every song renders loud, clean, unclipped audio' ($badAud -join '; ')
    T-Is ($slow.Count -eq 0) 'no song takes longer than 6s to synthesise' ($slow -join ', ')
    T-Is ($badCh.Count -eq 0) 'every chart is sorted, in range and actually playable' ($badCh -join '; ')

    # ---------------- scoring ---------------------------------------------
    T-Is ((Get-Judgement 0.0)      -eq 'PERFECT') 'delta 0 is PERFECT'
    T-Is ((Get-Judgement 0.0479)   -eq 'PERFECT') 'inside the perfect window'
    T-Is ((Get-Judgement 0.0481)   -eq 'GREAT')   'just past perfect is GREAT'
    T-Is ((Get-Judgement -0.0479)  -eq 'PERFECT') 'negative delta is PERFECT (late keypress)'
    T-Is ((Get-Judgement -0.09)    -eq 'GREAT')   'late at the great boundary'
    T-Is ((Get-Judgement 0.1399)   -eq 'GOOD')    'just inside the good window'
    T-Is ((Get-Judgement 0.2)      -eq 'MISS')    'way off is a MISS'
    T-Is ((Get-BasePoints 'PERFECT') -eq 300) 'PERFECT is worth 300'
    T-Is ((Get-BasePoints 'NOPE')    -eq 0)   'unknown judgement is worth 0'
    T-Is ((Get-Mult 0)   -eq 1) 'combo 0 is x1'
    T-Is ((Get-Mult 9)   -eq 1) 'combo 9 is x1'
    T-Is ((Get-Mult 10)  -eq 2) 'combo 10 is x2'
    T-Is ((Get-Mult 25)  -eq 3) 'combo 25 is x3'
    T-Is ((Get-Mult 50)  -eq 4) 'combo 50 is x4'
    T-Is ((Get-Mult 100) -eq 5) 'combo 100 is x5'
    T-Is ((Get-Mult 9999) -eq 5) 'combo beyond 100 caps at x5'
    T-Is ((Get-Accuracy 0 0 0 0) -eq 0.0) 'accuracy of nothing is 0'
    T-Is ((Get-Accuracy 10 0 0 0) -eq 1.0) 'flawless accuracy is 1'
    T-Is ((Get-Accuracy 0 0 0 10) -eq 0.0) 'all miss accuracy is 0'
    T-Is ((Get-Rank 0.99) -eq 'S+') '99% is S+'
    T-Is ((Get-Rank 0.94) -eq 'S')  '94% is S'
    T-Is ((Get-Rank 0.89) -eq 'A')  '89% is A'
    T-Is ((Get-Rank 0.81) -eq 'B')  '81% is B'
    T-Is ((Get-Rank 0.71) -eq 'C')  '71% is C'
    T-Is ((Get-Rank 0.10) -eq 'D')  '10% is D'
    T-Is ((Get-Stars 1.0) -eq 5) 'perfect run is 5 stars'
    T-Is ((Get-Stars 0.0) -eq 0) 'empty run is 0 stars'
    T-Is ((Get-Stars 0.19) -eq 0) '19% is still 0 stars'
    T-Is ((Get-Stars 0.99) -eq 4) '99% is 4 stars (floor)'

    $s0 = $script:Catalog[0]
    $m0 = Get-SongMeta $s0
    $c0 = Get-Chart $s0 $m0 'Normal'
    $perf = Simulate-Play $c0 'perfect' 0.0
    $acc0 = Get-Accuracy $perf.P $perf.G $perf.Gd $perf.M
    T-Is ($perf.M -eq 0) 'a flawless run misses nothing'
    T-Is ($acc0 -eq 1.0) 'a flawless run has 100% accuracy'
    T-Is ((Get-Rank $acc0) -eq 'S+') 'a flawless run ranks S+'

    $idle = Simulate-Play $c0 'idle'
    T-Is ($idle.M -eq $c0.Count) 'standing still misses every note'
    T-Is ((Get-Rank (Get-Accuracy $idle.P $idle.G $idle.Gd $idle.M)) -eq 'D') 'standing still ranks D'

    $rnd = Simulate-Play $c0 'random' 0.03
    $tot = $rnd.P + $rnd.G + $rnd.Gd + $rnd.M
    T-Is ($tot -eq $c0.Count) 'random play still accounts for every note'

    $S = New-ScoreState $c0
    Add-Score $S 300 0.0
    T-Is ($S.Score -eq 300) 'score accumulates'
    $S.Combo = 50
    Add-Score $S 300 0.0
    T-Is ($S.Score -gt 300) 'the multiplier increases the score'
    $before = $S.Score
    Add-Score $S 0 0.0
    T-Is ($S.Score -eq $before) 'a zero-value hit adds nothing'

    # ---------------- game rules, driven head-less -----------------------
    # a deterministic six-note chart: one note a second, no holds

    # Judged lives on the note object, so every scenario needs its own chart
    $tcl = New-TestChart


    $tcl = New-TestChart


    $G1 = New-ScoreState $tcl
    for ($i = 0; $i -lt $tcl.Count; $i++) {
        Step-LaneCursors $G1 $tcl $tcl[$i].T
        Invoke-Hit $G1 $tcl $tcl[$i].T $tcl[$i].Lane
    }
    T-Is ($G1.Perfect -eq 6) 'flawless input registers six perfects' ("perfect=$($G1.Perfect)")
    T-Is ($G1.Miss -eq 0) 'flawless input registers no misses'
    T-Is ($G1.Combo -eq 6) 'flawless input builds a six combo' ("combo=$($G1.Combo)")
    T-Is ($G1.MaxCombo -eq 6) 'the best combo is remembered' ("max=$($G1.MaxCombo)")
    T-Is ($G1.Judged -eq 6) 'every note is accounted for exactly once' ("judged=$($G1.Judged)")
    T-Is ($G1.Score -gt 0) 'flawless input scores points' ("score=$($G1.Score)")
    T-Is ((Get-Rank (Get-Accuracy $G1.Perfect $G1.Great $G1.Good $G1.Miss)) -eq 'S+') 'a perfect run ranks S+'

    $tcl = New-TestChart

    $G1b = New-ScoreState $tcl
    Step-LaneCursors $G1b $tcl $tcl[0].T
    Invoke-Hit $G1b $tcl $tcl[0].T $tcl[0].Lane
    Invoke-Hit $G1b $tcl $tcl[0].T $tcl[0].Lane
    T-Is ($G1b.Judged -eq 1) 'the same note cannot be hit twice' ("judged=$($G1b.Judged)")

    $tcl = New-TestChart

    $G1c = New-ScoreState $tcl
    Step-LaneCursors $G1c $tcl $tcl[0].T
    Invoke-Hit $G1c $tcl $tcl[0].T (($tcl[0].Lane + 1) % $script:LANES)
    T-Is ($G1c.Judged -eq 0) 'striking the wrong lane does nothing'

    $tcl = New-TestChart

    $G1d = New-ScoreState $tcl
    Step-LaneCursors $G1d $tcl ($tcl[0].T - 0.5)
    Invoke-Hit $G1d $tcl ($tcl[0].T - 0.5) $tcl[0].Lane
    T-Is ($G1d.Judged -eq 0) 'a strike far outside the window does nothing'

    T-NoThrow { $G1x = New-ScoreState $tcl; Invoke-Hit $G1x $tcl 1.0 -1; Invoke-Hit $G1x $tcl 1.0 99 } 'stray lane numbers are ignored safely'
    T-NoThrow { $G1y = New-ScoreState (New-Object 'object[]' 0); Invoke-Hit $G1y (New-Object 'object[]' 0) 1.0 0; Step-Misses $G1y (New-Object 'object[]' 0) 9.0; Step-Holds $G1y 9.0 } 'an empty chart is safe'

    $tcl = New-TestChart

    $G2 = New-ScoreState $tcl
    Step-LaneCursors $G2 $tcl $tcl[0].T
    Invoke-Hit $G2 $tcl ($tcl[0].T + 0.060) $tcl[0].Lane
    T-Is ($G2.Great -eq 1 -and $G2.Perfect -eq 0) 'a late strike inside the great window is a GREAT' ("great=$($G2.Great)")

    $tcl = New-TestChart

    $G3 = New-ScoreState $tcl
    Step-LaneCursors $G3 $tcl $tcl[0].T
    Invoke-Hit $G3 $tcl ($tcl[0].T - 0.120) $tcl[0].Lane
    T-Is ($G3.Good -eq 1) 'a strike inside the good window is a GOOD' ("good=$($G3.Good)")

$tcl = New-TestChart

    $saveFail = $script:FailMisses
    try {
        $script:FailMisses = 4
        $G4 = New-ScoreState $tcl
        Step-Misses $G4 $tcl 99.0
        T-Is ($G4.Miss -eq 6) 'letting every note pass counts six misses' ("miss=$($G4.Miss)")
        T-Is ($G4.Failed) 'missing everything makes you rock out'
        T-Is ($G4.Combo -eq 0) 'missing everything leaves no combo'
        T-Is ($G4.Meter -eq 0) 'the rock meter bottoms out'

        # the limit the player picked decides when the song is lost.
        # a fresh chart per state: Judged lives on the note objects.
        $script:FailMisses = 3
        $tcl = New-TestChart
        $two = New-Object 'object[]' 2
        $two[0] = $tcl[0]; $two[1] = $tcl[1]
        $G4b = New-ScoreState $two
        Step-Misses $G4b $two 99.0
        T-Is ($G4b.Miss -eq 2) 'two misses were counted' ("miss=$($G4b.Miss)")
        T-Is (-not $G4b.Failed) 'staying under the miss limit keeps the song going'
        T-Is ((Get-StrikeLeft $G4b) -eq 1) 'the panel knows one strike is left' ("left=$(Get-StrikeLeft $G4b)")

        $script:FailMisses = 2
        $tcl = New-TestChart
        $two = New-Object 'object[]' 2
        $two[0] = $tcl[0]; $two[1] = $tcl[1]
        $G4c = New-ScoreState $two
        Step-Misses $G4c $two 99.0
        T-Is ($G4c.Failed) 'the miss that reaches the limit is the fatal one'

        $script:FailMisses = 0
        $tcl = New-TestChart
        $G4d = New-ScoreState $tcl
        Step-Misses $G4d $tcl 99.0
        T-Is ($G4d.Miss -eq 6) 'with no limit every note can still be missed' ("miss=$($G4d.Miss)")
        T-Is (-not $G4d.Failed) 'fail = never means you cannot rock out'
        T-Is ((Get-StrikeLeft $G4d) -eq -1) 'no limit reports no strikes at all'

        $script:FailMisses = 6
        $tcl = New-TestChart
        $G4e = New-ScoreState $tcl
        Step-Misses $G4e $tcl 99.0
        T-Is ($G4e.Failed) 'the sixth miss is fatal at a limit of six'
        $script:FailMisses = 7
        $tcl = New-TestChart
        $G4f = New-ScoreState $tcl
        Step-Misses $G4f $tcl 99.0
        T-Is (-not $G4f.Failed) 'the same six misses survive a limit of seven'
    } finally { $script:FailMisses = $saveFail }
    T-Is ($script:FailMisses -eq $saveFail) 'the self test leaves the miss limit as it was'
    T-Is ((Get-FailLabel 0) -like 'never*') 'a zero limit is spelled out in words'
    T-Is ((Get-FailLabel 16) -like '16*') 'a normal limit shows the number'

    $tcl = New-TestChart

    $G5 = New-ScoreState $tcl
    Step-Misses $G5 $tcl ($tcl[0].T + $script:WMiss - 0.01)
    T-Is ($G5.Miss -eq 0) 'a note still inside the miss window is hittable' ("miss=$($G5.Miss)")
    Step-Misses $G5 $tcl ($tcl[0].T + $script:WMiss + 0.01)
    T-Is ($G5.Miss -eq 1) 'a note is only missed once it is truly gone' ("miss=$($G5.Miss)")
    Step-Misses $G5 $tcl 99.0
    T-Is ($G5.Miss -eq 6 -and $G5.Idx -eq 6) 'the miss cursor walks the whole chart exactly once'

    # ---- overdrive -------------------------------------------------------
    $tcl = New-TestChart
    $G6 = New-ScoreState $tcl
    T-Is (-not (Invoke-Overdrive $G6 1.0)) 'overdrive refuses to fire on a cold meter'
    $G6.Meter = 1.0; $G6.OdReady = $true
    T-Is (Invoke-Overdrive $G6 1.0) 'overdrive fires when the meter is full'
    T-Is ($G6.Od -eq 8.0) 'overdrive lasts eight seconds'
    T-Is (-not (Invoke-Overdrive $G6 1.1)) 'overdrive cannot be stacked while it runs'
    $base0 = $G6.Score
    Step-LaneCursors $G6 $tcl $tcl[0].T
    Invoke-Hit $G6 $tcl $tcl[0].T $tcl[0].Lane
    $withOd = $G6.Score - $base0
    $tcl = New-TestChart
    $G6b = New-ScoreState $tcl
    Step-LaneCursors $G6b $tcl $tcl[0].T
    Invoke-Hit $G6b $tcl $tcl[0].T $tcl[0].Lane
    T-Is ($withOd -eq ($G6b.Score * 2)) 'overdrive doubles the score of a hit' ("od=$withOd plain=$($G6b.Score)")
    for ($f = 0; $f -lt 600; $f++) { Step-Meter $G6 $f }
    T-Is ($G6.Od -eq 0) 'overdrive eventually runs out'
    T-Is (-not $G6.OdReady) 'overdrive has to be earned again'

    # ---- hold notes ------------------------------------------------------
    # the loop always marks the lane down before striking it, so do the same
    $hcl = New-TestChart -WithHold
    $H1 = New-ScoreState $hcl
    Step-LaneCursors $H1 $hcl 2.0
    $H1.Down[2] = $true
    Invoke-Hit $H1 $hcl 2.0 2
    T-Is ($H1.Perfect -eq 1 -and $H1.Combo -eq 1) 'a normal note scores and builds combo'
    Step-Holds $H1 2.1
    T-Is ($H1.Combo -eq 1) 'a tapped note cannot be held'
    Step-LaneCursors $H1 $hcl 4.0
    $H1.Down[4] = $true
    Invoke-Hit $H1 $hcl 4.0 4
    T-Is ($H1.Combo -eq 1) 'striking a hold does not finish the combo yet' ("combo=$($H1.Combo)")
    T-Is ($null -ne $H1.HoldN[4]) 'the hold is now being tracked'
    Step-Holds $H1 4.30
    T-Is ($H1.Holds -eq 0 -and $H1.Combo -eq 1) 'holding early does nothing' ("holds=$($H1.Holds) combo=$($H1.Combo)")
    Step-Holds $H1 4.65
    T-Is ($H1.Holds -eq 1) 'holding to the end completes the hold' ("holds=$($H1.Holds)")
    T-Is ($H1.Combo -eq 2) 'completing a hold builds the combo' ("combo=$($H1.Combo)")
    T-Is ($null -eq $H1.HoldN[4]) 'a finished hold is cleared'
    T-Is ($H1.HoldDrop -eq 0) 'a finished hold is not a drop'

    $hcl = New-TestChart -WithHold
    $H2 = New-ScoreState $hcl
    Step-LaneCursors $H2 $hcl 4.0
    $H2.Down[4] = $true
    Invoke-Hit $H2 $hcl 4.0 4
    Step-Holds $H2 4.10
    $H2.Down[4] = $false
    $H2.Combo = 20
    Step-Holds $H2 4.20
    T-Is ($H2.HoldDrop -eq 1) 'letting go of a hold drops it' ("drops=$($H2.HoldDrop)")
    T-Is ($H2.Combo -eq 0) 'dropping a hold breaks the combo'
    T-Is ($H2.Judgement -eq 'DROPPED') 'a dropped hold says so on screen'
    T-Is ($null -eq $H2.HoldN[4]) 'a dropped hold is cleared'

    # a dropped hold burns a strike, exactly like a missed note
    $saveFail2 = $script:FailMisses
    try {
        $script:FailMisses = 1
        $hcl = New-TestChart -WithHold
        $H2b = New-ScoreState $hcl
        Step-LaneCursors $H2b $hcl 4.0
        $H2b.Down[4] = $true
        Invoke-Hit $H2b $hcl 4.0 4
        Step-Holds $H2b 4.10
        $H2b.Down[4] = $false
        Step-Holds $H2b 4.20
        T-Is ($H2b.HoldDrop -eq 1) 'the drop was counted'
        T-Is ($H2b.Failed) 'a dropped hold counts against the miss limit'

        $script:FailMisses = 2
        $hcl = New-TestChart -WithHold
        $H2c = New-ScoreState $hcl
        Step-LaneCursors $H2c $hcl 4.0
        $H2c.Down[4] = $true
        Invoke-Hit $H2c $hcl 4.0 4
        Step-Holds $H2c 4.10
        $H2c.Down[4] = $false
        Step-Holds $H2c 4.20
        T-Is (-not $H2c.Failed) 'one drop is survivable at a limit of two'

        $script:FailMisses = 0
        $hcl = New-TestChart -WithHold
        $H2d = New-ScoreState $hcl
        Step-LaneCursors $H2d $hcl 4.0
        $H2d.Down[4] = $true
        Invoke-Hit $H2d $hcl 4.0 4
        Step-Holds $H2d 4.10
        $H2d.Down[4] = $false
        Step-Holds $H2d 4.20
        T-Is (-not $H2d.Failed) 'with no limit even a drop cannot end the song'
    } finally { $script:FailMisses = $saveFail2 }

    $hcl = New-TestChart -WithHold
    $H3 = New-ScoreState $hcl
    Step-LaneCursors $H3 $hcl 4.0
    $H3.Down[4] = $true
    Invoke-Hit $H3 $hcl 4.0 4
    Step-Holds $H3 9.0
    T-Is ($null -eq $H3.HoldN[4]) 'a hold nobody finished eventually times out'
    T-Is ($H3.Holds -eq 1 -and $H3.HoldDrop -eq 0) 'a timed-out hold that reached its end still counts' ("holds=$($H3.Holds) drops=$($H3.HoldDrop)")

    # a real chart must exercise the hold code path
    $holdFound = $false
    foreach ($sg in $cat) {
        $mt = Get-SongMeta $sg
        foreach ($dn in $script:Difficulty) {
            $cc = Get-Chart $sg $mt $dn.Name
            foreach ($n in $cc) { if ($n.Hold -gt 0.06) { $holdFound = $true; break } }
            if ($holdFound) { break }
        }
        if ($holdFound) { break }
    }
    T-Is $holdFound 'at least one real chart produces hold notes'


    $oldW = $script:W; $oldH = $script:H
    $layoutOk = $true; $layoutMsg = ''
    foreach ($sz in @(@(40, 12), @(72, 24), @(104, 40), (300, 100))) {
        try {
            $script:W = $sz[0]; $script:H = $sz[1]
            $script:Base = $null
            Update-Base
            if ($script:PANELW -lt 12) { $layoutOk = $false; $layoutMsg = "panel too narrow at $($sz[0])x$($sz[1])" }
            $script:HITROW = [Math]::Max($script:HWTOP + 8, $script:H - 6)
            $dummy = New-GameFrame $S $s0 (Get-Difficulty 'Normal') 1.0 8.0 'off' $m0
            if ($null -eq $dummy) { $layoutOk = $false; $layoutMsg = 'renderer returned nothing' }
        } catch {
$layoutOk = $false
            $layoutMsg = "$($sz[0])x$($sz[1]): " + $_.Exception.Message + ' @ ' + (($_.ScriptStackTrace -split "`n")[0])
        }
    }
    T-Is $layoutOk 'the renderer survives tiny, minimum, normal and huge consoles' $layoutMsg
    $script:W = $oldW; $script:H = $oldH; $script:Base = $null; Set-Screen

    T-NoThrow { $null = Wrap-Runs 'abc' $null } 'Wrap-Runs handles a null run list'
    T-NoThrow { $rr = New-Object System.Collections.ArrayList; [void]$rr.Add(@(0, 2, 'X')); $null = Wrap-Runs 'abcdef' $rr } 'Wrap-Runs handles a run list'
    $escBefore = [RockHero.Synth]::SR
    T-Is ($escBefore -eq 32000) 'engine constant readable'

    $f0 = New-GameFrame $S $s0 (Get-Difficulty 'Normal') 0.0 8.0 'off' $m0
    T-Is ($f0.Count -eq $script:H) 'frame has exactly one line per screen row'
    $badLen = 0
    foreach ($l in $f0) { if ($null -eq $l) { $badLen++ } }
    T-Is ($badLen -eq 0) 'no null lines in a rendered frame'

    $midPos = $m0.Total * 0.5
    $S2 = New-ScoreState $c0
    $S2.WinLo = 0
    T-NoThrow { $null = New-GameFrame $S2 $s0 (Get-Difficulty 'Expert') $midPos 12.0 'waveOut' $m0 } 'mid-song frame renders'

    # frame with an empty chart must not divide by zero or read past the end
    $Sempty = New-ScoreState (New-Object 'object[]' 0)
    T-NoThrow { $null = New-GameFrame $Sempty $s0 (Get-Difficulty 'Normal') 1.0 8.0 'off' $m0 } 'frame renders with an empty chart'

    $d1 = $script:Ansi
    $script:Ansi = $true
    T-NoThrow { $null = New-GameFrame $S2 $s0 (Get-Difficulty 'Normal') $midPos 10.0 'off' $m0 } 'frame renders with ANSI colour on'
    $script:Ansi = $d1

    T-Is ((Get-Bar 0.5 20).Length -eq 20) 'progress bar is exactly the requested width'
    T-Is ((Get-Bar -3 20) -eq (Get-Bar 0 20)) 'progress bar survives a negative fraction'
    T-Is ((Get-Bar 5 20) -eq (Get-Bar 1 20)) 'progress bar survives a fraction above 1'
    T-Is ((Get-Bar 0 20) -notmatch [regex]::Escape([string]$script:G.barfull)) 'an empty bar is all empty cells'
    T-Is ((Get-Bar 1 20) -notmatch [regex]::Escape([string]$script:G.empty)) 'a full bar is all full cells'
    T-Is ((Get-Bar 0.5 2) -eq '') 'progress bar refuses a silly width'
    T-Is ((Get-Bar 0.5 0) -eq '') 'progress bar survives a zero width'

    # ---------------- difficulty fallback ----------------------------------
    $fb = Get-Chart $s0 $m0 'NoSuchMode'
    T-Is ($fb.Count -gt 0) 'an unknown difficulty falls back to a valid chart'
    $fbd = Get-Difficulty 'NoSuchMode'
    T-Is ($fbd.Name -eq 'Normal') 'an unknown difficulty name falls back to Normal'

    # ---------------- extreme tempo ---------------------------------------
    $t1 = (New-Song -Band 'x' -Title 't' -Style 't' -Bpm 30  -Riff @('0...0...4...4...') -Drums @('K...s...K...s...') -Lead @('0...4...3...2...') -Prog @('0'))
    $t2 = (New-Song -Band 'x' -Title 't' -Style 't' -Bpm 400 -Riff @('0...0...4...4...') -Drums @('K...s...K...s...') -Lead @('0...4...3...2...') -Prog @('0'))
    $extOk = $true; $extMsg = ''
    foreach ($t in @($t1, $t2)) {
        try {
            $mt = Get-SongMeta $t
            if (-not ($mt.Total -gt 0 -and $mt.Total -lt 4000 -and -not [double]::IsInfinity($mt.Step))) {
                $extOk = $false; $extMsg = 'meta out of range for bpm ' + $t.Bpm
            }
            $et = New-SongEvents $t $mt
            if ($et.Count -lt 5) { $extOk = $false; $extMsg = 'no events for bpm ' + $t.Bpm }
            $ct = Get-Chart $t $mt 'Normal'
            if ($ct.Count -eq 0) { $extOk = $false; $extMsg = 'no chart for bpm ' + $t.Bpm }
        } catch { $extOk = $false; $extMsg = $_.Exception.Message }
    }
    T-Is $extOk 'extreme tempos (30 and 400 BPM) build correctly' $extMsg

    # ---------------- input when redirected --------------------------------
    T-NoThrow { $null = Read-Keys } 'Read-Keys is safe when stdin is redirected'
    T-NoThrow { $k = Get-LaneFromKey ([pscustomobject]@{ Key = 'A'; KeyChar = [char]97 }); if ($k -ne 0) { throw 'lane map wrong for a' } } 'letter keys map to lanes'
    T-NoThrow { $k = Get-LaneFromKey ([pscustomobject]@{ Key = 'F1'; KeyChar = [char]0 }); if ($k -ne -1) { throw 'function keys must not map to a lane' } } 'function keys are ignored'
    T-NoThrow { $k = Get-LaneFromKey ([pscustomobject]@{ Key = 'D3'; KeyChar = [char]0 }); if ($k -ne 2) { throw 'numpad map wrong' } } 'numpad keys map to lanes'

    # ---------------- high scores -----------------------------------------
    $testDir = Join-Path ([IO.Path]::GetTempPath()) ('rh_test_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    $f = Join-Path $testDir 'hs.xml'
    $realScoreFile = $script:ScoreFile
    $script:ScoreFile = $f
    $script:High = @{}
    $saveOk = $true
    try {
        Set-ScoreFor 1 'Normal' ([pscustomobject]@{ Score = 12345; Rank = 'A'; Combo = 40; Acc = 0.9; When = 'now' }) | Out-Null
        if (-not (Save-Scores)) { $saveOk = $false; 'Save-Scores returned false' }
        $script:High = @{}
        Load-Scores
        if (-not (Get-ScoreFor 1 'Normal')) { $saveOk = $false }
    } catch { $saveOk = $false; $_.Exception.Message }

    Load-Scores
    T-Is $saveOk 'high scores survive a save/load round trip'
    $r1 = Get-ScoreFor 1 'Normal'
    T-Is ($null -ne $r1 -and $r1.Score -eq 12345) 'the loaded score is the right one'
    $replaced = Set-ScoreFor 1 'Normal' ([pscustomobject]@{ Score = 500; Rank = 'D'; Combo = 1; Acc = 0.1; When = 'now' })
    T-Is (-not $replaced) 'a worse score does not overwrite the record'
    T-Is ((Get-ScoreFor 1 'Normal').Score -eq 12345) 'the record still holds the best score'
    $replaced = Set-ScoreFor 1 'Normal' ([pscustomobject]@{ Score = 99999; Rank = 'S'; Combo = 99; Acc = 0.99; When = 'now' })
    T-Is $replaced 'a better score does overwrite the record'
    T-Is ($null -eq (Get-ScoreFor 99 'Normal')) 'an unknown song has no record'

    Set-Content -LiteralPath $f -Value 'this is not xml at all' -Encoding UTF8
    T-NoThrow { Load-Scores } 'a corrupted score file does not crash the game'
    T-Is ($script:High.Count -eq 0) 'a corrupted score file resets to empty'
    T-NoThrow { Save-Scores } 'saving over a corrupted file repairs it'
    T-Is ((Save-Scores -Path 'Z:\definitely\not\here\hs.xml') -eq $false) 'saving to an impossible path fails quietly'

    $script:ScoreFile = $realScoreFile
    $script:High = @{}
    Load-Scores
    Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue

    # ---------------- the player's own music ------------------------------
    $ownRoot = Join-Path $testDir 'music'
    $ownCache = Join-Path $testDir 'owncharts'
    New-Item -ItemType Directory -Path $ownRoot -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path $ownCache -Force -ErrorAction SilentlyContinue | Out-Null
    $savedMusic = $script:MusicFolder
    $savedChart = $script:ChartFolder
    $script:MusicFolder = $ownRoot
    $script:ChartFolder = $ownCache

    try {
        # a four second click track, eight snare hits every 500 ms
        $evOwn = New-Object 'System.Collections.Generic.List[RockHero.Ev]'
        for ($i = 0; $i -lt 8; $i++) { $evOwn.Add((New-Ev ($i * 0.5) 0.12 3 38 0.95 0)) }
        $audOwn = [RockHero.Synth]::Render($evOwn, 4.0)
        $ownWav = Join-Path $ownRoot 'zz-selftest-click.wav'
        [IO.File]::WriteAllBytes($ownWav, [RockHero.Synth]::WrapWav($audOwn))

        $ownList = @(Get-CustomSongs)
        T-Is ($ownList.Count -eq 1) 'a wav in the music folder is picked up' ("count=$($ownList.Count)")
        T-Is ($ownList.Count -eq 1 -and $ownList[0].Custom) 'the picked up song is flagged as own music'
        T-Is ($ownList.Count -eq 1 -and $ownList[0].Band -eq 'my music') 'own music shows under its own band'

        $ownInfo = $null
        if (T-Try { [RockHero.Decode]::Info($ownWav) } 'wav header can be read') { $ownInfo = $script:TVal }
        T-Is ($null -ne $ownInfo -and $ownInfo.Ok) 'wav header is valid' ("err=" + $ownInfo.Error)
        T-Is ($ownInfo.Rate -eq 32000 -and $ownInfo.Channels -eq 1 -and $ownInfo.Bits -eq 16) 'wav format is reported' ("rate=$($ownInfo.Rate) ch=$($ownInfo.Channels) bits=$($ownInfo.Bits)")
        T-Is ([Math]::Abs($ownInfo.Seconds - 4.0) -lt 0.1) 'wav length is reported in seconds' ("sec=$($ownInfo.Seconds)")

        $ownSong = $ownList[0]
        $ownErr = ''
        $ownOnsets = $null
        if (T-Try { Get-CustomAnalysis $ownSong ([ref]$ownErr) } 'the analysis of own music does not crash') { $ownOnsets = $script:TVal }
        T-Is ($null -ne $ownOnsets -and @($ownOnsets).Count -ge 6) 'the click track yields onsets' ("onsets=$(if ($ownOnsets) { @($ownOnsets).Count } else { 0 })")
        $ownSorted = $true
        $ownInRange = $true
        $ownNear = 0
        if ($ownOnsets) {
            $prevT = -1.0
            foreach ($o in $ownOnsets) {
                if ($o.T -le $prevT) { $ownSorted = $false }
                $prevT = $o.T
                if ($o.T -lt 0.0 -or $o.T -gt $ownInfo.Seconds) { $ownInRange = $false }
                if ($o.Strength -lt 0.0 -or $o.Strength -gt 1.0) { $ownInRange = $false }
                for ($k = 0; $k -lt 8; $k++) {
                    if ([Math]::Abs($o.T - ($k * 0.5)) -lt 0.06) { $ownNear++; break }
                }
            }
        }
        T-Is $ownSorted 'onsets come out in ascending order'
        T-Is $ownInRange 'every onset is inside the recording and 0..1 strong'
        T-Is ($ownNear -ge 6) 'most onsets sit on the clicks that were actually rendered' ("near=$ownNear")
        T-Is ($ownSong.Bpm -ge 70 -and $ownSong.Bpm -le 180) 'the tempo guess lands in a sane range' ("bpm=$($ownSong.Bpm)")

        # the cache has to hand back exactly what the detector produced
        $ownSong2 = $ownList[0]
        $ownErr2 = ''
        $ownCached = Get-CustomAnalysis $ownSong2 ([ref]$ownErr2)
        $same = ($null -ne $ownCached -and @($ownCached).Count -eq @($ownOnsets).Count)
        if ($same) {
            for ($i = 0; $i -lt @($ownOnsets).Count; $i++) {
                if ([Math]::Abs([double]$ownCached[$i].T - [double]$ownOnsets[$i].T) -gt 0.002) { $same = $false; break }
            }
        }
        T-Is $same 'a second read returns the onsets from the cache unchanged'
        T-Is ($ownSong2.Bpm -eq $ownSong.Bpm -and [Math]::Abs($ownSong2.Duration - $ownSong.Duration) -lt 0.01) 'the cached tempo and length match'

        $ownMeta = Get-SongMeta $ownSong
        T-Is ([Math]::Abs($ownMeta.LeadIn - 2.0) -lt 0.001) 'own music gets a two second lead in'
        T-Is ($ownMeta.Total -gt $ownSong.Duration) 'own music lasts longer than the recording'

        $ownBad = @(); $ownCount = 0
        foreach ($dset in $script:Difficulty) {
            $c = @(Get-Chart $ownSong $ownMeta $dset.Name)
            $ownCount += $c.Count
            if ($c.Count -eq 0) { $ownBad += ($dset.Name + ' empty'); continue }
            $limit = 0.30
            if ($dset.Name -eq 'Normal') { $limit = 0.17 }
            elseif ($dset.Name -eq 'Hard') { $limit = 0.12 }
            elseif ($dset.Name -eq 'Expert') { $limit = 0.08 }
            $runLane = -1; $run = 0
            for ($i = 0; $i -lt $c.Count; $i++) {
                $nt = [double]$c[$i].T
                if ($nt -lt $ownMeta.LeadIn - 0.05 -or $nt -gt $ownMeta.Total) { $ownBad += ($dset.Name + ' note out of range') }
                if ($i -gt 0 -and ($nt - [double]$c[$i - 1].T) -lt $limit - 0.001) { $ownBad += ($dset.Name + ' notes too close') }
                $ln = [int]$c[$i].Lane
                if ($ln -lt 0 -or $ln -ge $script:LANES) { $ownBad += ($dset.Name + ' lane out of range') }
                if ($ln -eq $runLane) { $run++ } else { $run = 1; $runLane = $ln }
                if ($run -ge 4) { $ownBad += ($dset.Name + ' long repeat on one lane') }
            }
        }
        T-Is ($ownBad.Count -eq 0) 'generated charts for own music are playable' (($ownBad | Select-Object -Unique) -join ', ')
        T-Is ($ownCount -gt 0) 'own music produces notes' ("notes=$ownCount")

        # a recording with nothing to chart must say so instead of crashing
        $silence = New-Object 'byte[]' (44 + 32000 * 2)
        [Array]::Copy([RockHero.Synth]::WrapWav($audOwn), 0, $silence, 0, 44)
        $silWav = Join-Path $ownRoot 'zz-selftest-silence.wav'
        [IO.File]::WriteAllBytes($silWav, $silence)
        $silSong = @(Get-CustomSongs | Where-Object { $_.Title -like '*silence*' })[0]
        $silErr = ''
        $silOn = $null
        if (T-Try { Get-CustomAnalysis $silSong ([ref]$silErr) } 'a silent recording does not crash the analysis') { $silOn = $script:TVal }
        T-Is ($null -eq $silOn -and $silErr -ne '') 'a silent recording reports why it has no chart' ("err=$silErr")
        T-Is (@(Get-Chart $silSong $ownMeta 'Easy').Count -eq 0) 'a silent recording charts as empty'

        # playing the recording has to drive the clock
        $pp = [RockHero.Player]::new()
        $ownOk = $false
        if (T-Try { $pp.PlayFile($ownWav) } 'the player opens a wav from disk') { $ownOk = $script:TVal }
        T-Is ($ownOk -and $pp.Mode -eq 'file') 'the player reports file mode' ("ok=$ownOk mode=$($pp.Mode)")
        T-Is ([Math]::Abs($pp.Duration - $ownInfo.Seconds) -lt 0.2) 'the player reports the length of the recording' ("dur=$($pp.Duration)")
        $posA = $pp.Position
        Start-Sleep -Milliseconds 400
        $posB = $pp.Position
        T-Is ($posB -gt $posA) 'the position of a file moves forward while it plays' ("$posA -> $posB")
        T-NoThrow { $pp.Stop() } 'stopping a file leaves the clock at zero'
        $pp.Dispose()

        # a broken path has to fail instead of taking the song down
        $badPath = Join-Path $ownRoot 'zz-selftest-missing.wav'
        $pb2 = [RockHero.Player]::new()
        T-Is ((-not $pb2.PlayFile($badPath))) 'a missing file fails cleanly'
        T-Is ($pb2.LastError -ne '') 'a missing file says what went wrong'
        $pb2.Dispose()

        T-NoThrow { [RockHero.Decode]::Info((Join-Path $ownRoot 'zz-selftest-nope.wav')) } 'reading a missing wav does not crash'
        T-Is (-not [RockHero.Decode]::Info((Join-Path $ownRoot 'zz-selftest-nope.wav')).Ok) 'a missing wav is reported as unreadable'
        $notAudio = Join-Path $ownRoot 'zz-selftest-notes.txt'
        Set-Content -LiteralPath $notAudio -Value 'plain text, not audio at all' -Encoding UTF8
        T-Is (-not [RockHero.Decode]::Info($notAudio).Ok) 'a file that is not audio is rejected'
        T-NoThrow { [RockHero.Decode]::Analyze($notAudio, 5.0, 60.0, 1.2) } 'analysing something that is not audio does not crash'
        T-Is (@([RockHero.Decode]::Analyze($notAudio, 5.0, 60.0, 1.2)).Length -eq 0) 'something that is not audio has no onsets'
    } catch {
        T-Result $false 'own music section runs to the end' $_.Exception.Message
    } finally {
        $script:MusicFolder = $savedMusic
        $script:ChartFolder = $savedChart
        Remove-Item -LiteralPath $ownRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ownCache -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---------------- summary ---------------------------------------------
    $tot = $script:TPass + $script:TFail
    Write-Host ''
    if ($script:TFail -eq 0) {
        Write-Host ("  ALL {0} TESTS PASSED   (total synthesising time {1:N1}s)" -f $tot, $swTot.Elapsed.TotalSeconds) -ForegroundColor Green
    } else {
        Write-Host ("  {0} of {1} TESTS FAILED" -f $script:TFail, $tot) -ForegroundColor Red
    }
    Write-Host ''
    return [pscustomobject]@{ Pass = $script:TPass; Fail = $script:TFail; Total = $tot }
}

function Run-SelfTestScreen {
    $null = Invoke-SelfTest
    Set-Screen
    $items = @('BACK')
    $null = Show-Menu -Title 'SELF-TEST COMPLETE' -Sub ('{0} passed, {1} failed' -f $script:TPass, $script:TFail) -Items $items `
        -DrawRow {
            param($i, $s)
            if ($s) { return $script:C.Sel + $script:G.arrow + ' BACK' + $script:C.R }
            return '   BACK'
        } `
        -DrawFoot { $script:C.Label + 'ESC to go back' + $script:C.R }
}

# ============================================================================
#  MAIN
# ============================================================================
function Show-StartupError {
    param([string]$Msg)
    Write-Host ''
    Write-Host '  ROCK HERO cannot start.' -ForegroundColor Red
    Write-Host ('  ' + $Msg) -ForegroundColor Yellow
    Write-Host ''
}

function Main {
    Get-DataDir | Out-Null

    try {
        $ok = Initialize-Engine
    } catch {
        Show-StartupError ("The audio engine failed to compile: " + $_.Exception.Message)
        return 2
    }
    if (-not $ok) {
        Show-StartupError 'The audio engine could not be loaded.'
        return 2
    }

$script:Catalog = Get-Catalog
    try { $script:Catalog = @($script:Catalog + @(Get-CustomSongs)) } catch { }
    New-GlyphTable
    New-ColorTable
    Load-Settings
    Apply-Volume
    Load-Scores

    # ---- non interactive modes ------------------------------------------
if ($SelfTest) {
        $r = Invoke-SelfTest
        if ($r.Fail -gt 0) { return 1 }
        return 0
    }

    if ($AudioDiag) {
        return Invoke-AudioDiag
    }

    if ($ListSongs) {
        Write-Host ''
        Write-Host '  ROCK HERO - song list' -ForegroundColor Yellow
        Write-Host ('  {0} songs from {1} bands' -f $script:Catalog.Count, (Get-BandCount)) -ForegroundColor DarkGray
        Write-Host ''
        $i = 0
        foreach ($s in $script:Catalog) {
            $i++
            Write-Host ('  {0,3}. {1,-18} {2,-24} {3,4} bpm  {4}' -f $i, $s.Band, $s.Title, $s.Bpm, $s.Style)
        }
        Write-Host ''
        Write-Host '  All riffs are original compositions written in the style of each band.' -ForegroundColor DarkGray
        Write-Host ''
        return 0
    }

    if ($Benchmark) {
        Write-Host ''
        Write-Host '  ROCK HERO - synthesis benchmark' -ForegroundColor Yellow
        Write-Host ''
        Write-Host ('  {0,-18} {1,-24} {2,7} {3,10} {4,9} {5,8}' -f 'BAND', 'TITLE', 'BPM', 'SECONDS', 'RENDER', 'SIZE') -ForegroundColor DarkGray
        $tot = 0.0
        foreach ($s in $script:Catalog) {
            $m = Get-SongMeta $s
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $a = [RockHero.Synth]::Render((New-SongEvents $s $m), $m.Total)
            $sw.Stop()
            $tot += $sw.Elapsed.TotalSeconds
            Write-Host ('  {0,-18} {1,-24} {2,7} {3,10:N1} {4,8}ms {5,7:N1}MB' -f $s.Band, $s.Title, $s.Bpm, $m.Total, $sw.ElapsedMilliseconds, ($a.Pcm.Length / 1MB))
        }
        Write-Host ''
        Write-Host ('  total render time {0:N2}s' -f $tot) -ForegroundColor Green
        Write-Host ''
        return 0    }

    if ($DumpWav -gt '') {
        if ($DumpSong -lt 1 -or $DumpSong -gt $script:Catalog.Count) {
            Show-StartupError ("-DumpSong must be between 1 and " + $script:Catalog.Count)
            return 2
        }
        $s = $script:Catalog[$DumpSong - 1]
        $m = Get-SongMeta $s
        Write-Host ''
        Write-Host ("  synthesising '{0} - {1}' ..." -f $s.Band, $s.Title)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $a = [RockHero.Synth]::Render((New-SongEvents $s $m), $m.Total)
        $sw.Stop()
        $bytes = [RockHero.Synth]::WrapWav($a)
        try {
            $dir = Split-Path -Parent $DumpWav
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllBytes($DumpWav, $bytes)
            Write-Host ('  wrote {0}  ({1:N1}s of audio, {2:N1}MB, peak {3}, rms {4:N3})' -f $DumpWav, $a.Seconds, ($bytes.Length / 1MB), $a.Peak, $a.Rms)
            Write-Host ('  synthesis took {0}ms' -f $sw.ElapsedMilliseconds)
            return 0
        } catch {
            Show-StartupError ("Could not write '$DumpWav': " + $_.Exception.Message)
            return 2
        }
    }

    # ---- interactive -----------------------------------------------------
    if ([RockHero.Term]::IsRedirected()) {
        Show-StartupError 'Input is redirected, so the keyboard cannot be read. Run rockhero.ps1 in a normal PowerShell console (or Windows Terminal).'
        return 2
    }

    $rc = 0
    try {
        try { [Console]::CursorVisible = $false } catch { }
        try { [Console]::TreatControlCAsInput = $true } catch { }
        try { $script:Ansi = [RockHero.Term]::TryEnableAnsi() } catch { $script:Ansi = $false }
        try { [Console]::Title = 'ROCK HERO - PowerShell' } catch { }
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

        if (-not $script:NoAudio) {
            try {
                $script:Sfx = [RockHero.Player]::new()
                $script:Sfx.Volume = $script:Vol
                $script:Music = [RockHero.Player]::new()
                $script:Music.Volume = $script:Vol
            } catch {
                $script:Sfx = $null; $script:Music = $null
                $script:NoAudio = $true
            }
        }

        Set-Screen
        while ($script:W -lt $script:MINW -or $script:H -lt $script:MINH) {
            $lines = New-BlankLines
            $r1 = [Math]::Max(0, [Math]::Min(6, $script:H - 2))
            Set-Cell $lines $r1 2 ($script:C.Warn + 'Your console is only ' + $script:W + 'x' + $script:H + ' characters.' + $script:C.R) 60
            Set-Cell $lines ($r1 + 1) 2 ($script:C.Label + 'At least ' + $script:MINW + 'x' + $script:MINH + ' is needed. Enlarge the window and press ENTER.' + $script:C.R) 80
            Write-Screen $lines
            $k = Wait-Key
            if ($null -ne $k -and $k.Key -eq 'Escape') { return 2 }
            Set-Screen
        }

        $script:CursorSave = $true
        while ($true) {
            $r = Invoke-MainMenu
            if ($r -eq 'quit') { break }
        }
    } catch {
        Write-Host ''
        Write-Host ('  unexpected error: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  The window stays open so the message can be read. Press ENTER to close.' -ForegroundColor DarkGray
        try { [Console]::TreatControlCAsInput = $false } catch { }
        try { [Console]::CursorVisible = $true } catch { }
        try { $null = [Console]::ReadLine() } catch { }
        $rc = 3
    } finally {
        try { if ($script:Music) { $script:Music.Stop() } } catch { }
        try { if ($script:Sfx) { $script:Sfx.Stop() } } catch { }
        try { [Console]::CursorVisible = $true } catch { }
        try { [Console]::TreatControlCAsInput = $false } catch { }
        try { [Console]::Out.Flush() } catch { }
    }
    Write-Host ''
    Write-Host '  Rock out.' -ForegroundColor Yellow
    Write-Host ''
    return $rc
}

$exitCode = Main
if (-not $NoAudio) {
    try { if ($script:Music) { $script:Music.Dispose() } } catch { }
    try { if ($script:Sfx) { $script:Sfx.Dispose() } } catch { }
}
exit $exitCode
