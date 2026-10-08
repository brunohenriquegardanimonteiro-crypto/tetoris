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
