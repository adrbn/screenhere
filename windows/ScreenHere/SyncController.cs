using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Threading;
using Windows.Devices.Enumeration;
using Windows.Networking.ServiceDiscovery.Dnssd;
using Windows.Networking.Sockets;

namespace ScreenHere;

/// The shared clipboard (beta, off by default): what is copied on this PC is
/// on the clipboard of the Mac or PC it was connected to, and the other way
/// round, while both are on the same network.
///
/// Nothing leaves that network: the two devices find each other with the
/// same local announcements printers use, talk to each other directly, and
/// encrypt everything with a key made when they were introduced. Text and
/// pictures are shared; files are not, and neither is anything a password
/// manager marked as private.
internal sealed class SyncController
{
    public static SyncController Shared { get; } = new();

    /// A device announcing itself nearby.
    public sealed record Found(string Id, string Name, IReadOnlyList<string> Addresses, int Port);

    /// The code both screens show while two devices are being introduced.
    public sealed record Offer(string Name, string Code, bool Confirmed);

    public bool IsEnabled { get; private set; }
    public string? PeerName => posed?.Peer ?? Settings.Current.SyncPeerName;
    public bool IsPaired => posed != null ? posed.Peer != null : Settings.Current.SyncPeerId != null && peerKey != null;
    public bool IsConnected => posed?.Connected ?? session != null;
    /// The panel is asking to connect a device: this one can be seen and asked.
    public bool IsPairing { get; private set; }
    public Offer? Pending { get; private set; }
    /// Documentation shots only: a state to show, with nothing behind it.
    public sealed record Posed(string? Peer, bool Connected);
    private Posed? posed;

    public void Pose(bool enabled, Posed state, bool pairing = false, Offer? offer = null, params Found[] nearby)
    {
        (IsEnabled, posed, IsPairing, Pending) = (enabled, state, pairing, offer);
        found.Clear();
        foreach (var device in nearby) found[device.Id] = device;
    }

    public IReadOnlyList<Found> Nearby => found.Values.Where(f => f.Id != DeviceId).OrderBy(f => f.Name).ToList();
    public event Action? Changed;

    private static string DeviceId => Settings.Current.SyncDeviceId ?? "";
    private static string DeviceName => Environment.MachineName;

    private readonly Dispatcher ui = Dispatcher.CurrentDispatcher;
    private readonly Dictionary<string, Found> found = new();
    private readonly Dictionary<string, string> watched = new();
    private readonly DispatcherTimer connector = new() { Interval = TimeSpan.FromSeconds(4) };
    private StreamSocketListener? listener;
    private DnssdServiceInstance? announcement;
    private DeviceWatcher? watcher;
    private byte[]? peerKey;
    private Session? session;
    private bool connecting;
    private DateTime waitingSince = DateTime.UtcNow;
    private TaskCompletionSource<bool>? decision;
    private CancellationTokenSource? pairing;
    /// What last arrived from the other device, and what last went to it:
    /// neither is sent again, so nothing can bounce between the two.
    private string? lastRemote;
    private string? lastSent;
    private int sent, received;

    private SyncController()
    {
        connector.Tick += (_, _) => Connect();
    }

    // MARK: - On and off

    public void Activate()
    {
        var settings = Settings.Current;
        if (settings.SyncDeviceId == null)
        {
            settings.SyncDeviceId = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
            settings.Save();
        }
        peerKey = Unprotect(settings.SyncPeerKey);
        IsEnabled = settings.SyncEnabled;
        if (IsEnabled) Start();
    }

    public void SetEnabled(bool on)
    {
        Settings.Current.SyncEnabled = on;
        Settings.Current.Save();
        IsEnabled = on;
        if (on) Start();
        else Stop();
        ClipboardController.Shared.Watch();
        Changed?.Invoke();
    }

    private async void Start()
    {
        waitingSince = DateTime.UtcNow;
        connector.Start();
        Browse();
        await Listen();
        Connect();
    }

    private void Stop()
    {
        connector.Stop();
        EndPairing();
        session?.Close();
        session = null;
        try { watcher?.Stop(); } catch { }
        watcher = null;
        found.Clear();
        watched.Clear();
        // Closing the listener takes its announcement off the network with it.
        listener?.Dispose();
        (listener, announcement) = (null, null);
    }

    // MARK: - Finding each other

    /// Answers on a port of its own, and says so on the local network.
    private async Task Listen()
    {
        if (listener != null) return;
        var made = new StreamSocketListener();
        made.ConnectionReceived += (_, e) => Task.Run(() => Serve(e.Socket));
        try
        {
            try
            {
                await made.BindServiceNameAsync(SyncProtocol.PreferredPort.ToString());
            }
            catch
            {
                // Taken: any free port will do, the announcement says which.
                await made.BindServiceNameAsync("");
            }
            var service = new DnssdServiceInstance($"{DeviceId}.{SyncProtocol.ServiceType}.local", null, ushort.Parse(made.Information.LocalPort));
            service.TextAttributes["name"] = DeviceName;
            service.TextAttributes["v"] = SyncProtocol.Version.ToString();
            await service.RegisterStreamSocketListenerAsync(made);
            if (!IsEnabled)
            {
                made.Dispose();
                return;
            }
            (listener, announcement) = (made, service);
        }
        catch
        {
            // No listening here — a firewall, a policy. This PC can still
            // reach the other device; it just cannot be reached first.
            made.Dispose();
        }
    }

    private void Browse()
    {
        if (watcher != null) return;
        try
        {
            const string dnssd = "{4526e8c1-8aac-4153-9b16-55e86ada0e54}";
            var query = $"System.Devices.AepService.ProtocolId:={dnssd} AND System.Devices.Dnssd.Domain:=\"local\" "
                      + $"AND System.Devices.Dnssd.ServiceName:=\"{SyncProtocol.ServiceType}\"";
            string[] wanted =
            [
                "System.Devices.Dnssd.InstanceName", "System.Devices.Dnssd.PortNumber",
                "System.Devices.Dnssd.TextAttributes", "System.Devices.IpAddress",
            ];
            var made = DeviceInformation.CreateWatcher(query, wanted, DeviceInformationKind.AssociationEndpointService);
            made.Added += (_, device) => ui.BeginInvoke(() => Saw(device.Id, device.Properties));
            made.Updated += (_, update) => ui.BeginInvoke(() => Saw(update.Id, update.Properties));
            made.Removed += (_, update) => ui.BeginInvoke(() =>
            {
                if (watched.Remove(update.Id, out var id) && found.Remove(id)) Changed?.Invoke();
            });
            made.Start();
            watcher = made;
        }
        catch
        {
            watcher = null;
        }
    }

    private void Saw(string handle, IReadOnlyDictionary<string, object> properties)
    {
        if (!IsEnabled) return;
        // An update only carries what changed: start from what was known.
        var known = watched.TryGetValue(handle, out var knownId) ? found.GetValueOrDefault(knownId) : null;
        var id = properties.GetValueOrDefault("System.Devices.Dnssd.InstanceName") as string ?? known?.Id;
        if (string.IsNullOrEmpty(id)) return;
        var port = properties.GetValueOrDefault("System.Devices.Dnssd.PortNumber") is ushort number ? number : known?.Port ?? 0;
        var addresses = properties.GetValueOrDefault("System.Devices.IpAddress") as string[] ?? known?.Addresses ?? [];
        var name = known?.Name ?? id;
        foreach (var attribute in properties.GetValueOrDefault("System.Devices.Dnssd.TextAttributes") as string[] ?? [])
        {
            if (attribute.StartsWith("name=")) name = attribute[5..];
        }
        if (port == 0) return;
        watched[handle] = id;
        found[id] = new Found(id, name, addresses, port);
        Changed?.Invoke();
        if (id == Settings.Current.SyncPeerId) Connect();
    }

    // MARK: - Staying connected

    /// Tries to reach the other device, when there is one and no connection.
    /// Both sides may: the device whose id sorts first tries at once, the
    /// other gives it a few seconds — one of them may sit behind a firewall
    /// that lets nothing in.
    private async void Connect()
    {
        var settings = Settings.Current;
        if (!IsEnabled || !IsPaired || session != null || connecting || Pending != null) return;
        var peer = settings.SyncPeerId!;
        var first = string.CompareOrdinal(DeviceId, peer) < 0;
        if (!first && (DateTime.UtcNow - waitingSince).TotalSeconds < 8) return;

        var targets = new List<(string Address, int Port)>();
        if (found.TryGetValue(peer, out var seen)) targets.AddRange(Order(seen.Addresses).Select(a => (a, seen.Port)));
        // Where it was last time, in case the announcement does not get through.
        if (settings.SyncPeerAddress is { } last && !targets.Any(t => t.Address == last)) targets.Add((last, SyncProtocol.PreferredPort));
        if (targets.Count == 0) return;

        connecting = true;
        try
        {
            foreach (var (address, port) in targets)
            {
                var stream = await Open(address, port);
                if (stream == null) continue;
                var made = await Task.Run(() => Session.AsClient(stream, DeviceId, peer, peerKey!));
                if (made == null) continue;
                settings.SyncPeerAddress = address;
                settings.Save();
                Adopt(made);
                break;
            }
        }
        finally
        {
            connecting = false;
        }
    }

    /// IPv4 first: it is what a home network is sure to route.
    private static IEnumerable<string> Order(IEnumerable<string> addresses) =>
        addresses.OrderBy(a => a.Contains(':') ? 1 : 0);

    private static async Task<Stream?> Open(string address, int port)
    {
        if (!IPAddress.TryParse(address, out var ip)) return null;
        var client = new TcpClient(ip.AddressFamily) { NoDelay = true };
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await client.ConnectAsync(ip, port, limit.Token);
            return client.GetStream();
        }
        catch
        {
            client.Dispose();
            return null;
        }
    }

    /// Keeps `made` as the connection to the other device. When each side
    /// reached the other at the same moment there are two: both sides keep the
    /// one opened by the device whose id sorts first, so both keep the same.
    private void Adopt(Session made)
    {
        if (!IsEnabled || made.PeerId != Settings.Current.SyncPeerId)
        {
            made.Close();
            return;
        }
        if (session is { } current)
        {
            var keepNew = string.CompareOrdinal(made.ClientId, current.ClientId) <= 0;
            if (!keepNew)
            {
                made.Close();
                return;
            }
            session = null;
            current.Close();
        }
        session = made;
        made.Received += (kind, payload) => ui.BeginInvoke(() => Receive(kind, payload));
        made.Closed += () => ui.BeginInvoke(() =>
        {
            if (session != made) return;
            session = null;
            waitingSince = DateTime.UtcNow;
            Changed?.Invoke();
        });
        made.Run();
        Changed?.Invoke();
    }

    // MARK: - Being reached

    private async Task Serve(StreamSocket socket)
    {
        var stream = new DuplexStream(socket);
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var first = SyncProtocol.Decode(await SyncProtocol.ReadFrame(stream, limit.Token));
            if (first?.Type == "hello" && first.Id != null)
            {
                var (peer, key) = await ui.InvokeAsync(() => (Settings.Current.SyncPeerId, peerKey));
                var made = first.Id == peer && key != null ? await Session.AsServer(stream, first, DeviceId, key) : null;
                if (made != null)
                {
                    _ = ui.BeginInvoke(() => Adopt(made));
                    return;
                }
            }
            else if (first?.Type == "pair1")
            {
                await AnswerPairing(stream, first);
            }
            else
            {
                await SyncProtocol.WriteFrame(stream, SyncProtocol.Encode(new() { Type = "no" }), limit.Token);
            }
        }
        catch
        {
        }
        stream.Dispose();
    }

    // MARK: - Sharing

    /// A text was copied on this PC.
    public void LocalCopy(string text)
    {
        if (session == null || text.Length == 0 || Encoding.UTF8.GetByteCount(text) > SyncProtocol.MaxText) return;
        var bytes = Encoding.UTF8.GetBytes(text);
        if (!IsNews(bytes)) return;
        session.Send(SyncProtocol.Kind.Text, bytes);
    }

    /// A picture was copied on this PC.
    public void LocalCopy(byte[] png)
    {
        if (session == null || png.LongLength > ClipboardHistory.MaxImageBytes || !IsNews(png)) return;
        session.Send(SyncProtocol.Kind.Image, png);
    }

    private bool IsNews(byte[] content)
    {
        var digest = Digest(content);
        if (digest == lastRemote || digest == lastSent) return false;
        lastSent = digest;
        sent++;
        return true;
    }

    private void Receive(SyncProtocol.Kind kind, byte[] payload)
    {
        // What this PC just sent, coming back: it has it already.
        if (!IsEnabled || Digest(payload) == lastSent) return;
        received++;
        var source = PeerName;
        switch (kind)
        {
            case SyncProtocol.Kind.Text when payload.Length <= SyncProtocol.MaxText:
                lastRemote = Digest(payload);
                ClipboardController.Shared.Write(Encoding.UTF8.GetString(payload), source);
                break;
            case SyncProtocol.Kind.Image when payload.LongLength <= ClipboardHistory.MaxImageBytes:
                lastRemote = Digest(payload);
                ClipboardController.Shared.WriteImage(payload, source);
                break;
        }
    }

    private static string Digest(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    /// For trying a build out under a profile of its own: what the panel
    /// would show, as text.
    public string Describe() =>
        $"enabled={IsEnabled} listening={listener != null} port={listener?.Information.LocalPort} paired={IsPaired} peer={PeerName} "
        + $"connected={IsConnected} sent={sent} received={received} pairing={IsPairing} code={Pending?.Code} confirmed={Pending?.Confirmed} "
        + $"nearby=[{string.Join("; ", Nearby.Select(f => $"{f.Name} {f.Id[..6]} {string.Join(",", f.Addresses)}:{f.Port}"))}]";

    // MARK: - Introducing two devices

    /// While the panel is asking, this PC answers a device that asks to be
    /// connected. The rest of the time it answers no one it does not know.
    public void BeginPairing()
    {
        if (!IsEnabled || IsPairing) return;
        IsPairing = true;
        Changed?.Invoke();
    }

    public void EndPairing()
    {
        if (!IsPairing && Pending == null) return;
        IsPairing = false;
        pairing?.Cancel();
        decision?.TrySetResult(false);
        Pending = null;
        Changed?.Invoke();
    }

    /// The user picked `device` in the panel: ask it.
    public async void Pair(Found device)
    {
        if (!IsPairing || Pending != null || pairing != null) return;
        using var cancel = pairing = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        var connected = false;
        try
        {
            foreach (var address in Order(device.Addresses))
            {
                using var stream = await Open(address, device.Port);
                if (stream == null) continue;
                connected = true;
                using var key = SyncProtocol.NewKey();
                var (mine, nonce) = (SyncProtocol.PublicBytes(key), SyncProtocol.RandomBytes(32));
                await SyncProtocol.WriteFrame(stream, SyncProtocol.Encode(new()
                {
                    Type = "pair1", Version = SyncProtocol.Version, Id = DeviceId, Name = DeviceName,
                    Commit = SyncProtocol.Base64(SyncProtocol.Commitment(mine, nonce)),
                }), cancel.Token);
                var answer = SyncProtocol.Decode(await SyncProtocol.ReadFrame(stream, cancel.Token));
                var (theirs, theirNonce) = (SyncProtocol.FromBase64(answer?.Public), SyncProtocol.FromBase64(answer?.Nonce));
                if (answer?.Type != "pair2" || answer.Id == null || theirs == null || theirNonce == null) break;
                await SyncProtocol.WriteFrame(stream, SyncProtocol.Encode(new()
                {
                    Type = "pair3", Public = SyncProtocol.Base64(mine), Nonce = SyncProtocol.Base64(nonce),
                }), cancel.Token);
                var (made, code) = SyncProtocol.Pairing(SyncProtocol.Agree(key, theirs), mine, theirs, nonce, theirNonce);
                await Agree(stream, answer.Id, answer.Name ?? device.Name, made, code, address, cancel.Token);
                return;
            }
            if (!cancel.IsCancellationRequested)
            {
                Toast.Show(connected ? $"{device.Name} is not asking to connect" : $"Couldn't reach {device.Name} — try from there", Glyph.Warning);
            }
        }
        catch
        {
        }
        finally
        {
            pairing = null;
            if (Pending != null)
            {
                Pending = null;
                Changed?.Invoke();
            }
        }
    }

    private async Task AnswerPairing(Stream stream, SyncProtocol.Message asked)
    {
        var free = await ui.InvokeAsync(() =>
        {
            if (!IsPairing || Pending != null || pairing != null) return false;
            pairing = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            return true;
        });
        var commit = SyncProtocol.FromBase64(asked.Commit);
        if (!free || asked.Id == null || commit == null)
        {
            await SyncProtocol.WriteFrame(stream, SyncProtocol.Encode(new() { Type = "no" }), CancellationToken.None);
            return;
        }
        var cancel = pairing!;
        try
        {
            using var key = SyncProtocol.NewKey();
            var (mine, nonce) = (SyncProtocol.PublicBytes(key), SyncProtocol.RandomBytes(32));
            await SyncProtocol.WriteFrame(stream, SyncProtocol.Encode(new()
            {
                Type = "pair2", Version = SyncProtocol.Version, Id = DeviceId, Name = DeviceName,
                Public = SyncProtocol.Base64(mine), Nonce = SyncProtocol.Base64(nonce),
            }), cancel.Token);
            var shown = SyncProtocol.Decode(await SyncProtocol.ReadFrame(stream, cancel.Token));
            var (theirs, theirNonce) = (SyncProtocol.FromBase64(shown?.Public), SyncProtocol.FromBase64(shown?.Nonce));
            if (shown?.Type != "pair3" || theirs == null || theirNonce == null) return;
            // The key it shows now must be the one it promised before seeing ours.
            if (!SyncProtocol.Commitment(theirs, theirNonce).AsSpan().SequenceEqual(commit)) return;
            var (made, code) = SyncProtocol.Pairing(SyncProtocol.Agree(key, theirs), theirs, mine, theirNonce, nonce);
            await ui.InvokeAsync(() => Agree(stream, asked.Id, asked.Name ?? "Device", made, code, null, cancel.Token)).Task.Unwrap();
        }
        catch
        {
        }
        finally
        {
            _ = ui.BeginInvoke(() =>
            {
                if (pairing == cancel) pairing = null;
                cancel.Dispose();
                if (Pending == null) return;
                Pending = null;
                Changed?.Invoke();
            });
        }
    }

    /// Both screens now show the same code — or someone is in the middle, and
    /// they do not. Each side says what its user decided; the devices are
    /// connected only when both said yes.
    private async Task Agree(Stream stream, string id, string name, byte[] key, string code, string? address, CancellationToken cancel)
    {
        decision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Pending = new Offer(name, code, Confirmed: false);
        Changed?.Invoke();

        var theirs = Task.Run(async () => SyncProtocol.Decode(await SyncProtocol.ReadFrame(stream, cancel))?.Ok == true, cancel);
        using var registration = cancel.Register(() => decision.TrySetResult(false));
        // Their no ends the question here too.
        _ = theirs.ContinueWith(t =>
        {
            if (t.IsFaulted || t.IsCanceled || !t.Result) decision.TrySetResult(false);
        }, TaskScheduler.Default);

        var mine = await decision.Task;
        try { await SyncProtocol.WriteFrame(stream, SyncProtocol.Encode(new() { Type = "pair4", Ok = mine }), CancellationToken.None); } catch { }
        var both = false;
        try { both = mine && await theirs; } catch { }

        Pending = null;
        if (both)
        {
            var settings = Settings.Current;
            session?.Close();
            session = null;
            (settings.SyncPeerId, settings.SyncPeerName, settings.SyncPeerKey, settings.SyncPeerAddress) = (id, name, Protect(key), address);
            settings.Save();
            peerKey = key;
            IsPairing = false;
            waitingSince = DateTime.UtcNow.AddSeconds(-30);
            Toast.Show($"Connected to {name}", Glyph.Link);
            _ = ui.BeginInvoke(Connect, DispatcherPriority.Background);
        }
        else if (mine)
        {
            Toast.Show($"{name} did not connect", Glyph.Warning);
        }
        Changed?.Invoke();
    }

    /// The user says the code is the same on both screens.
    public void Confirm()
    {
        if (Pending is not { Confirmed: false } offer) return;
        Pending = offer with { Confirmed = true };
        Changed?.Invoke();
        decision?.TrySetResult(true);
    }

    public void Decline() => decision?.TrySetResult(false);

    /// Forgets the other device and its key. It would have to be introduced again.
    public void Forget()
    {
        var settings = Settings.Current;
        (settings.SyncPeerId, settings.SyncPeerName, settings.SyncPeerKey, settings.SyncPeerAddress) = (null, null, null, null);
        settings.Save();
        peerKey = null;
        session?.Close();
        session = null;
        Changed?.Invoke();
    }

    // MARK: - The key at rest

    /// Kept under Windows' own protection for this account: the settings file
    /// alone, copied elsewhere, gives nothing away.
    private static string Protect(byte[] key) =>
        Convert.ToBase64String(ProtectedData.Protect(key, null, DataProtectionScope.CurrentUser));

    private static byte[]? Unprotect(string? stored)
    {
        try { return stored == null ? null : ProtectedData.Unprotect(Convert.FromBase64String(stored), null, DataProtectionScope.CurrentUser); }
        catch { return null; }
    }

    // MARK: - A connection

    /// The two halves of an accepted connection, as one stream.
    private sealed class DuplexStream(StreamSocket socket) : Stream
    {
        private readonly Stream input = socket.InputStream.AsStreamForRead(0);
        private readonly Stream output = socket.OutputStream.AsStreamForWrite(0);

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => output.Flush();
        public override Task FlushAsync(CancellationToken cancel) => output.FlushAsync(cancel);
        public override int Read(byte[] buffer, int offset, int count) => input.Read(buffer, offset, count);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancel = default) => input.ReadAsync(buffer, cancel);
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancel) => input.ReadAsync(buffer, offset, count, cancel);
        public override void Write(byte[] buffer, int offset, int count) => output.Write(buffer, offset, count);
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancel = default) => output.WriteAsync(buffer, cancel);
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancel) => output.WriteAsync(buffer, offset, count, cancel);
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try { input.Dispose(); } catch { }
                try { output.Dispose(); } catch { }
                try { socket.Dispose(); } catch { }
            }
            base.Dispose(disposing);
        }
    }

    /// A connection to the other device, once each side has shown it holds
    /// the key they share.
    internal sealed class Session
    {
        public string PeerId { get; }
        /// The id of the side that opened the connection.
        public string ClientId { get; }
        public event Action<SyncProtocol.Kind, byte[]>? Received;
        public event Action? Closed;

        private readonly Stream stream;
        private readonly SyncProtocol.Cipher sending;
        private readonly SyncProtocol.Cipher receiving;
        private readonly SemaphoreSlim turn = new(1, 1);
        private readonly CancellationTokenSource cancel = new();
        private DateTime heard = DateTime.UtcNow;
        private int closed;

        private Session(Stream stream, string peerId, string clientId, byte[] sendKey, byte[] receiveKey)
        {
            (this.stream, PeerId, ClientId) = (stream, peerId, clientId);
            (sending, receiving) = (new SyncProtocol.Cipher(sendKey), new SyncProtocol.Cipher(receiveKey));
        }

        public static async Task<Session?> AsClient(Stream stream, string ownId, string peerId, byte[] pairKey)
        {
            try
            {
                using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                using var key = SyncProtocol.NewKey();
                var nonce = SyncProtocol.RandomBytes(32);
                await SyncProtocol.WriteFrame(stream, SyncProtocol.Encode(new()
                {
                    Type = "hello", Version = SyncProtocol.Version, Id = ownId,
                    Public = SyncProtocol.Base64(SyncProtocol.PublicBytes(key)), Nonce = SyncProtocol.Base64(nonce),
                }), limit.Token);
                var answer = SyncProtocol.Decode(await SyncProtocol.ReadFrame(stream, limit.Token));
                var (theirs, theirNonce) = (SyncProtocol.FromBase64(answer?.Public), SyncProtocol.FromBase64(answer?.Nonce));
                if (answer?.Type != "hello" || answer.Id != peerId || theirs == null || theirNonce == null) throw new InvalidDataException();
                var (toServer, toClient) = SyncProtocol.SessionKeys(SyncProtocol.Agree(key, theirs), pairKey, nonce, theirNonce);
                var made = new Session(stream, peerId, ownId, toServer, toClient);
                await made.Greet(limit.Token);
                return made;
            }
            catch
            {
                stream.Dispose();
                return null;
            }
        }

        public static async Task<Session?> AsServer(Stream stream, SyncProtocol.Message hello, string ownId, byte[] pairKey)
        {
            try
            {
                using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                var (theirs, theirNonce) = (SyncProtocol.FromBase64(hello.Public), SyncProtocol.FromBase64(hello.Nonce));
                if (theirs == null || theirNonce == null) return null;
                using var key = SyncProtocol.NewKey();
                var nonce = SyncProtocol.RandomBytes(32);
                await SyncProtocol.WriteFrame(stream, SyncProtocol.Encode(new()
                {
                    Type = "hello", Version = SyncProtocol.Version, Id = ownId,
                    Public = SyncProtocol.Base64(SyncProtocol.PublicBytes(key)), Nonce = SyncProtocol.Base64(nonce),
                }), limit.Token);
                var (toServer, toClient) = SyncProtocol.SessionKeys(SyncProtocol.Agree(key, theirs), pairKey, theirNonce, nonce);
                var made = new Session(stream, hello.Id!, hello.Id!, toClient, toServer);
                await made.Greet(limit.Token);
                return made;
            }
            catch
            {
                return null;
            }
        }

        /// Each side seals one frame and opens the other's: whoever does not
        /// hold the key cannot do either.
        private async Task Greet(CancellationToken limit)
        {
            await SyncProtocol.WriteFrame(stream, sending.Seal(SyncProtocol.Kind.Ready, []), limit);
            var (kind, _) = receiving.Open(await SyncProtocol.ReadFrame(stream, limit));
            if (kind != SyncProtocol.Kind.Ready) throw new InvalidDataException();
        }

        public void Run()
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    while (!cancel.IsCancellationRequested)
                    {
                        var (kind, payload) = receiving.Open(await SyncProtocol.ReadFrame(stream, cancel.Token));
                        heard = DateTime.UtcNow;
                        if (kind is SyncProtocol.Kind.Text or SyncProtocol.Kind.Image) Received?.Invoke(kind, payload);
                    }
                }
                catch
                {
                }
                Close();
            });
            // A connection that went quiet is a laptop that closed its lid.
            _ = Task.Run(async () =>
            {
                try
                {
                    while (!cancel.IsCancellationRequested)
                    {
                        await Task.Delay(TimeSpan.FromSeconds(20), cancel.Token);
                        if ((DateTime.UtcNow - heard).TotalSeconds > 65) break;
                        Send(SyncProtocol.Kind.Ping, []);
                    }
                }
                catch
                {
                }
                Close();
            });
        }

        public void Send(SyncProtocol.Kind kind, byte[] payload)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    // One frame at a time, in the order they are numbered.
                    await turn.WaitAsync(cancel.Token);
                    try
                    {
                        await SyncProtocol.WriteFrame(stream, sending.Seal(kind, payload), cancel.Token);
                    }
                    finally
                    {
                        turn.Release();
                    }
                }
                catch
                {
                    Close();
                }
            });
        }

        public void Close()
        {
            if (Interlocked.Exchange(ref closed, 1) != 0) return;
            cancel.Cancel();
            try { stream.Dispose(); } catch { }
            Closed?.Invoke();
        }
    }
}
