using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ScreenHere;

/// A copy that is a web link and nothing else — the text a browser's address
/// bar or "Copy link" puts on the clipboard.
internal sealed record CopiedLink
{
    /// Longer than any address a browser copies; spares parsing a pasted essay.
    private const int MaxBytes = 4_096;

    public string Address { get; }
    private readonly Uri url;

    private CopiedLink(string address, Uri url)
    {
        Address = address;
        this.url = url;
    }

    public static CopiedLink? From(string? text)
    {
        if (text == null || text.Length > MaxBytes) return null;
        var trimmed = text.Trim();
        if (!trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            && !trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) return null;
        if (trimmed.Any(char.IsWhiteSpace)) return null;
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var url) || url.Host.Length == 0) return null;
        return new CopiedLink(trimmed, url);
    }

    public bool Equals(CopiedLink? other) => other != null && other.Address == Address;
    public override int GetHashCode() => Address.GetHashCode();

    public Uri Url => url;

    /// "github.com", for the row's subtitle.
    public string Host
    {
        get
        {
            var host = url.Host.ToLowerInvariant();
            return host.StartsWith("www.") ? host[4..] : host;
        }
    }

    /// "github.com/adrbn/screenhere", for a row with no title.
    public string Display
    {
        get
        {
            var text = Uri.UnescapeDataString(Address);
            foreach (var prefix in new[] { "https://", "http://" })
            {
                if (text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) text = text[prefix.Length..];
            }
            if (text.StartsWith("www.", StringComparison.OrdinalIgnoreCase)) text = text[4..];
            return text.TrimEnd('/');
        }
    }

    /// Whether a preview may visit it at all.
    public bool MayVisit => LinkSafety.MayVisit(url);

    /// The address a visit asks for.
    public Uri VisitUrl => LinkSafety.VisitUrl(url);
}

/// Which links a preview may visit. A visit is a GET to the link itself, with
/// no cookies: harmless for a page, but a link that signs in, resets a
/// password or confirms an address can be spent by it, and a local address
/// is nobody's business outside this network. Anything that looks like either
/// is left alone — a missed preview costs nothing, a spent link does. And only
/// over TLS: without it, a name could point at a public server for the check
/// and at this network for the visit, and a server here could answer for it.
internal static partial class LinkSafety
{
    public static bool MayVisit(Uri url)
    {
        if (!MayVisitHost(url) || url.UserInfo.Length > 0) return false;
        // "login.example.com": the site's own name, the last two labels, says nothing.
        var labels = url.Host.ToLowerInvariant().Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (labels.SkipLast(2).Any(LooksSingleUse)) return false;
        var segments = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Any(s => LooksSingleUse(s) || LooksRandom(s))) return false;
        foreach (var (name, value) in QueryItems(url))
        {
            if (IsTracking(name)) continue;
            if (LooksSecret(name)) return false;
            if (LooksRandom(value) || value.Contains("://")) return false;
        }
        return true;
    }

    /// Scheme, host and port only: what an icon on another server needs.
    public static bool MayVisitHost(Uri url)
    {
        if (url.Scheme != "https" || url.Host.Length == 0) return false;
        var host = url.Host.ToLowerInvariant().TrimEnd('.');
        if (!url.IsDefaultPort && url.Port != 443) return false;
        if (!host.Contains('.') || IsAddress(host)) return false;
        return !LocalSuffixes.Any(suffix => host == suffix || host.EndsWith("." + suffix));
    }

    /// Without the fragment, which never reaches the server, and without
    /// tracking parameters, which have no business going along.
    public static Uri VisitUrl(Uri url)
    {
        var builder = new UriBuilder(url) { Fragment = "" };
        var kept = url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Where(pair => !IsTracking(Unescape(pair.Split('=', 2)[0])));
        builder.Query = string.Join("&", kept);
        return builder.Uri;
    }

    /// Loopback, private, link-local, carrier-grade NAT (Tailscale) and
    /// unspecified addresses, in either family — including an IPv4 address
    /// carried inside an IPv6 one.
    public static bool IsPrivateAddress(IPAddress address)
    {
        var b = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork) return IsPrivateV4(b);
        if (address.AddressFamily != AddressFamily.InterNetworkV6) return true;
        if (EmbeddedV4(b) is { } v4) return IsPrivateV4(v4);
        return (b[0] & 0xfe) == 0xfc                                                    // fc00::/7
            || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)                                  // fe80::/10
            || b[0] == 0xff                                                             // multicast
            || b.AsSpan(0, 6).SequenceEqual<byte>([0x00, 0x64, 0xff, 0x9b, 0x00, 0x01]) // 64:ff9b:1::/48, local NAT64
            || b.AsSpan(0, 4).SequenceEqual<byte>([0x20, 0x01, 0x0d, 0xb8]);            // 2001:db8::/32, documentation
    }

    public static bool IsPrivateAddress(string text) =>
        !IPAddress.TryParse(text.Split('%')[0].Trim('[', ']'), out var address) || IsPrivateAddress(address);

    /// The IPv4 address an IPv6 one carries: compatible (::a.b.c.d, which
    /// takes in :: and ::1), mapped (::ffff:a.b.c.d), NAT64 (64:ff9b::a.b.c.d)
    /// or 6to4 (2002:aabb:ccdd::).
    private static byte[]? EmbeddedV4(byte[] b)
    {
        if (b.Take(10).All(x => x == 0) && ((b[10] == 0 && b[11] == 0) || (b[10] == 0xff && b[11] == 0xff))) return b[12..16];
        if (b.AsSpan(0, 12).SequenceEqual<byte>([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0])) return b[12..16];
        if (b[0] == 0x20 && b[1] == 0x02) return b[2..6];
        return null;
    }

    private static bool IsPrivateV4(byte[] b) =>
        b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224
        || (b[0] == 100 && (b[1] & 0xc0) == 64)
        || (b[0] == 169 && b[1] == 254)
        || (b[0] == 172 && (b[1] & 0xf0) == 16)
        || (b[0] == 192 && b[1] == 168);

    private static bool IsAddress(string host) => host.Contains(':') || host.All(c => char.IsDigit(c) || c == '.');

    private static readonly HashSet<string> LocalSuffixes =
    [
        "localhost", "local", "lan", "home", "home.arpa", "internal", "intranet", "corp",
        "test", "invalid", "ts.net",
    ];

    /// Words in a path that sign in, confirm or spend something.
    private static readonly HashSet<string> SingleUseWords =
    [
        "reset", "verify", "verification", "confirm", "confirmation", "magic", "login", "signin",
        "logout", "signout", "auth", "oauth", "oauth2", "sso", "saml", "callback", "invite",
        "invitation", "invitations", "unsubscribe", "activate", "activation", "token", "tokens", "otp",
        "onetime", "password", "passwords", "passwd", "recover", "recovery", "approve", "accept",
        "validate", "track", "tracking", "click", "clicks", "redirect", "redir",
    ];

    /// Query names that carry a secret. Matched as whole words…
    private static readonly HashSet<string> SecretWords =
    [
        "token", "code", "key", "secret", "sig", "signature", "auth", "otp", "password", "passwd",
        "pwd", "pass", "session", "sid", "ticket", "nonce", "state", "jwt", "hash", "credential",
        "credentials", "magic", "reset", "invite", "apikey", "accesskey",
    ];
    /// …and these anywhere in the name.
    private static readonly string[] SecretFragments = ["token", "secret", "passw", "signature", "session", "apikey", "credential"];

    private static readonly HashSet<string> TrackingNames =
    [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "mc_cid", "mc_eid", "igshid", "igsh", "si", "_ga", "_gl", "li_fat_id", "mkt_tok",
    ];

    private static IEnumerable<(string Name, string Value)> QueryItems(Uri url)
    {
        foreach (var pair in url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            yield return (Unescape(parts[0]), parts.Length > 1 ? Unescape(parts[1]) : "");
        }
    }

    private static string Unescape(string text)
    {
        try { return Uri.UnescapeDataString(text.Replace('+', ' ')); }
        catch { return text; }
    }

    private static bool IsTracking(string name)
    {
        name = name.ToLowerInvariant();
        return name.StartsWith("utm_") || TrackingNames.Contains(name);
    }

    private static bool LooksSecret(string name)
    {
        name = name.ToLowerInvariant();
        return SecretFragments.Any(name.Contains) || MatchesWord(name, SecretWords);
    }

    private static bool LooksSingleUse(string segment) => MatchesWord(Unescape(segment).ToLowerInvariant(), SingleUseWords);

    /// A word, or two neighbours written as one ("sign-in", "one-time").
    private static bool MatchesWord(string text, HashSet<string> words)
    {
        var parts = NotWord().Split(text).Where(p => p.Length > 0).ToList();
        if (parts.Any(words.Contains)) return true;
        return parts.Zip(parts.Skip(1)).Any(pair => words.Contains(pair.First + pair.Second));
    }

    /// A token rather than a word: a long run mixing letters and digits, or
    /// capitals and small letters in about equal measure, as identifiers,
    /// signatures and capability links are made — or a UUID. Readable slugs
    /// ("how-to-build-a-tray-app") are short words, and camel case
    /// ("LinkPreviewController") has few capitals.
    private static bool LooksRandom(string text)
    {
        text = Unescape(text);
        if (Uuid().IsMatch(text)) return true;
        return text.Split(['-', '_', '.', '~', '+', '/', '=', ',', ':', ';', ' ', '\t', '\n'], StringSplitOptions.RemoveEmptyEntries).Any(piece =>
        {
            if (piece.Length < 16) return false;
            var digits = piece.Count(char.IsDigit);
            var letters = piece.Count(char.IsLetter);
            var capitals = piece.Count(char.IsUpper);
            var small = piece.Count(char.IsLower);
            return (digits >= 2 && letters >= 2) || (capitals * 4 >= piece.Length && small * 4 >= piece.Length);
        });
    }

    [GeneratedRegex(@"[^\p{L}\p{N}]+")] private static partial Regex NotWord();
    [GeneratedRegex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")] private static partial Regex Uuid();
}

internal static class LinkExtensions
{
    /// The texts in it that are links, for their previews.
    public static HashSet<CopiedLink> Links(this ClipboardHistory history) =>
        history.Items.Select(i => CopiedLink.From(i.Text)).OfType<CopiedLink>().ToHashSet();
}

/// What a page says about itself in its head.
internal sealed record PageHead(string? Title, Uri? Icon);

internal static partial class PageHeadParser
{
    public static PageHead Parse(string html, Uri url)
    {
        // The head only: a title further down belongs to an inline picture.
        var end = html.IndexOf("</head", StringComparison.OrdinalIgnoreCase);
        var head = end > 0 ? html[..end] : html;

        string? social = null;
        Uri? icon = null;
        var iconRank = int.MinValue;
        foreach (Match tag in Tag().Matches(head))
        {
            var attributes = Attributes(tag.Groups[2].Value);
            if (tag.Groups[1].Value.Equals("meta", StringComparison.OrdinalIgnoreCase))
            {
                var name = (attributes.GetValueOrDefault("property") ?? attributes.GetValueOrDefault("name") ?? "").ToLowerInvariant();
                if (name is "og:title" or "twitter:title" && social == null) social = Clean(attributes.GetValueOrDefault("content"));
                continue;
            }
            var rel = (attributes.GetValueOrDefault("rel") ?? "").ToLowerInvariant();
            if (!rel.Split(' ').Contains("icon") && rel != "apple-touch-icon") continue;
            if (attributes.GetValueOrDefault("href") is not { Length: > 0 } href) continue;
            if (!Uri.TryCreate(url, WebUtility.HtmlDecode(href), out var candidate)) continue;
            // A real icon before Apple's, which is drawn for a home screen;
            // among equals, the one closest to what the row shows.
            var rank = (rel == "apple-touch-icon" ? 0 : 1_000) - Math.Abs(LargestSize(attributes.GetValueOrDefault("sizes")) - 64);
            if (candidate.AbsolutePath.EndsWith(".svg", StringComparison.OrdinalIgnoreCase)) rank -= 5_000;
            if (rank > iconRank) (icon, iconRank) = (candidate, rank);
        }

        var title = social ?? Clean(Title().Match(head) is { Success: true } match ? match.Groups[1].Value : null);
        return new PageHead(title, icon ?? new Uri(url, "/favicon.ico"));
    }

    private static Dictionary<string, string> Attributes(string body)
    {
        var attributes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match match in Attribute().Matches(body))
        {
            var value = match.Groups[2].Success ? match.Groups[2].Value : match.Groups[3].Success ? match.Groups[3].Value : match.Groups[4].Value;
            attributes.TryAdd(match.Groups[1].Value, value);
        }
        return attributes;
    }

    private static int LargestSize(string? sizes) =>
        Number().Matches(sizes ?? "").Select(m => int.Parse(m.Value)).DefaultIfEmpty(32).Max();

    /// One line, entities decoded, nothing invisible, never a paragraph.
    internal static string? Clean(string? raw)
    {
        if (raw == null) return null;
        var text = new string(WebUtility.HtmlDecode(raw).Where(c => !char.IsControl(c) || char.IsWhiteSpace(c)).ToArray());
        text = string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (text.Length > 200) text = text[..199].TrimEnd() + "…";
        return text.Length == 0 ? null : text;
    }

    [GeneratedRegex(@"<(meta|link)\b([^>]*)>", RegexOptions.IgnoreCase)] private static partial Regex Tag();
    [GeneratedRegex(@"<title\b[^>]*>(.*?)</title", RegexOptions.IgnoreCase | RegexOptions.Singleline)] private static partial Regex Title();
    [GeneratedRegex(@"([\w:-]+)\s*=\s*(?:""([^""]*)""|'([^']*)'|([^\s""'>]+))")] private static partial Regex Attribute();
    [GeneratedRegex(@"\d+")] private static partial Regex Number();
}

/// Visits a link the way a careful stranger would: no cookies, no saved
/// passwords, tracking parameters left behind, the top megabyte of the page
/// at most.
internal static class LinkVisitor
{
    private const int MaxPage = 1024 * 1024;
    private const int MaxIcon = 512 * 1024;
    private const int MaxHops = 5;

    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        UseCookies = false,
        AllowAutoRedirect = false,
        // A proxy would do the looking-up, and the check below with it.
        UseProxy = false,
        AutomaticDecompression = DecompressionMethods.All,
        ConnectTimeout = TimeSpan.FromSeconds(5),
        // The name is looked up here and the visit goes to the address that
        // was checked — so a name cannot point outside for the check and at
        // this network for the visit.
        ConnectCallback = async (context, cancel) =>
        {
            var addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, cancel);
            if (addresses.Length == 0 || addresses.Any(LinkSafety.IsPrivateAddress)) throw new IOException("Not a public address");
            var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
            try
            {
                await socket.ConnectAsync(addresses, context.DnsEndPoint.Port, cancel);
                return new NetworkStream(socket, ownsSocket: true);
            }
            catch
            {
                socket.Dispose();
                throw;
            }
        },
    })
    { Timeout = TimeSpan.FromSeconds(8) };

    private const string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

    /// The page's title and icon, or null when the visit was refused or failed.
    public static async Task<(string? Title, byte[]? Icon)?> Visit(CopiedLink link)
    {
        try
        {
            if (!link.MayVisit || IsMetered()) return null;
            var url = link.VisitUrl;
            for (var hop = 0; hop < MaxHops; hop++)
            {
                // A redirect is a new link, and is held to the same rules.
                if (!LinkSafety.MayVisit(url)) return null;
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
                request.Headers.TryAddWithoutValidation("Accept", "text/html,application/xhtml+xml");
                request.Headers.TryAddWithoutValidation("Accept-Language", "en-US,en;q=0.8");
                using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
                if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } location)
                {
                    url = LinkSafety.VisitUrl(new Uri(url, location));
                    continue;
                }
                if (!response.IsSuccessStatusCode || !IsHtml(response.Content.Headers.ContentType?.MediaType)) return null;

                var bytes = await ReadTop(response, MaxPage);
                var head = PageHeadParser.Parse(Text(bytes, response.Content.Headers.ContentType?.CharSet), url);
                var icon = head.Icon is { } address ? await Icon(address) : null;
                return (head.Title, icon);
            }
        }
        catch
        {
            // No preview: the row keeps its address.
        }
        return null;
    }

    private static async Task<byte[]?> Icon(Uri url)
    {
        try
        {
            for (var hop = 0; hop < MaxHops; hop++)
            {
                if (!LinkSafety.MayVisitHost(url)) return null;
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
                using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
                if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } location)
                {
                    url = new Uri(url, location);
                    continue;
                }
                if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength > MaxIcon) return null;
                var bytes = await ReadTop(response, MaxIcon + 1);
                return bytes.Length > MaxIcon ? null : bytes;
            }
        }
        catch
        {
        }
        return null;
    }

    private static async Task<byte[]> ReadTop(HttpResponseMessage response, int limit)
    {
        await using var stream = await response.Content.ReadAsStreamAsync();
        using var kept = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (kept.Length < limit)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, limit - kept.Length)));
            if (read == 0) break;
            kept.Write(buffer, 0, read);
        }
        return kept.ToArray();
    }

    internal static bool IsHtml(string? contentType) =>
        contentType != null && (contentType.Contains("html", StringComparison.OrdinalIgnoreCase)
                                || contentType.Contains("xml", StringComparison.OrdinalIgnoreCase));

    /// The page in the encoding it declares — in its header, else in its own
    /// first lines — and UTF-8 when it declares none.
    internal static string Text(byte[] bytes, string? charset)
    {
        charset ??= Regex.Match(Encoding.ASCII.GetString(bytes, 0, Math.Min(bytes.Length, 2048)),
                                @"charset\s*=\s*[""']?([\w-]+)", RegexOptions.IgnoreCase) is { Success: true } m ? m.Groups[1].Value : null;
        try
        {
            if (charset != null) return Encoding.GetEncoding(charset.Trim('"', '\'')).GetString(bytes);
        }
        catch (ArgumentException)
        {
        }
        return Encoding.UTF8.GetString(bytes);
    }

    /// On a connection that counts its data, nothing is fetched at all.
    private static bool IsMetered()
    {
        try
        {
            var cost = Windows.Networking.Connectivity.NetworkInformation.GetInternetConnectionProfile()?.GetConnectionCost();
            return cost != null && cost.NetworkCostType != Windows.Networking.Connectivity.NetworkCostType.Unrestricted;
        }
        catch
        {
            return false;
        }
    }
}

/// Link previews (beta, off by default): a copied link shown as its page's
/// title and its site's icon. Previews are kept next to the history, leave
/// with the links they belong to, and are all deleted when the setting is
/// turned off or the history cleared.
internal sealed class LinkPreviews
{
    public static LinkPreviews Shared { get; } = new();

    public sealed record Shown(string? Title, BitmapSource? Icon);
    private sealed record Stored(string? Title, bool HasIcon);

    private readonly string folder = Path.Combine(Settings.Folder, "links");
    private readonly Dictionary<string, Shown> shown = new();
    private Dictionary<string, Stored> stored = new();
    private readonly HashSet<string> wanted = [];
    private bool loaded;
    private bool posed;
    public event Action? Changed;

    public bool IsEnabled { get; private set; }

    public void Activate() => IsEnabled = Settings.Current.LinkPreviews;

    public void SetEnabled(bool on)
    {
        Settings.Current.LinkPreviews = on;
        Settings.Current.Save();
        IsEnabled = on;
        if (!on) Clear();
        Changed?.Invoke();
    }

    public Shown? Preview(CopiedLink link)
    {
        Load();
        return shown.GetValueOrDefault(link.Address);
    }

    /// Asked by the list when it shows the link — never when it is copied.
    public void Want(CopiedLink link)
    {
        Load();
        if (posed || !IsEnabled || !link.MayVisit || shown.ContainsKey(link.Address) || !wanted.Add(link.Address)) return;
        var dispatcher = Dispatcher.CurrentDispatcher;
        Task.Run(async () =>
        {
            var visit = await LinkVisitor.Visit(link);
            var icon = visit?.Icon is { } bytes ? DecodeIcon(bytes) : null;
            await dispatcher.BeginInvoke(() =>
            {
                // Turned off or forgotten while the visit was under way.
                if (!IsEnabled || !wanted.Contains(link.Address) || visit == null) return;
                shown[link.Address] = new Shown(visit.Value.Title, icon);
                stored[link.Address] = new Stored(visit.Value.Title, icon != null);
                Save(link.Address, icon);
                Changed?.Invoke();
            });
        });
    }

    public void Forget(IReadOnlyCollection<CopiedLink> links)
    {
        if (links.Count == 0 || posed) return;
        Load();
        foreach (var link in links)
        {
            shown.Remove(link.Address);
            wanted.Remove(link.Address);
            if (stored.Remove(link.Address)) Delete(IconPath(link.Address));
        }
        SaveIndex();
    }

    public void Prune(HashSet<CopiedLink> keeping)
    {
        if (posed) return;
        Load();
        var addresses = keeping.Select(l => l.Address).ToHashSet();
        Forget(stored.Keys.Where(a => !addresses.Contains(a)).Select(CopiedLink.From).OfType<CopiedLink>().ToList());
    }

    public void Clear()
    {
        shown.Clear();
        stored.Clear();
        wanted.Clear();
        if (posed) return;
        try { Directory.Delete(folder, recursive: true); } catch { }
    }

    public void Pose(bool enabled, Dictionary<string, Shown> previews)
    {
        posed = loaded = true;
        IsEnabled = enabled;
        foreach (var (address, preview) in previews) shown[address] = preview;
    }

    // MARK: - Disk

    private void Load()
    {
        if (loaded) return;
        loaded = true;
        try
        {
            stored = JsonSerializer.Deserialize<Dictionary<string, Stored>>(File.ReadAllBytes(Path.Combine(folder, "index.json"))) ?? new();
            foreach (var (address, entry) in stored)
            {
                BitmapSource? icon = null;
                if (entry.HasIcon && File.Exists(IconPath(address))) icon = ClipboardAccess.Decode(File.ReadAllBytes(IconPath(address)));
                shown[address] = new Shown(entry.Title, icon);
            }
        }
        catch
        {
            stored = new();
        }
    }

    private void Save(string address, BitmapSource? icon)
    {
        try
        {
            Directory.CreateDirectory(folder);
            SaveIndex();
            // After the title: an icon that will not save costs the icon only.
            if (icon != null) File.WriteAllBytes(IconPath(address), ClipboardAccess.Png(icon));
        }
        catch
        {
        }
    }

    private void SaveIndex()
    {
        try
        {
            if (!Directory.Exists(folder)) return;
            Atomic.Write(Path.Combine(folder, "index.json"), JsonSerializer.SerializeToUtf8Bytes(stored));
        }
        catch
        {
        }
    }

    private string IconPath(string address) =>
        Path.Combine(folder, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(address)))[..32].ToLowerInvariant() + ".png");

    private static void Delete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    /// The frame closest to what the row shows, out of the several an .ico holds.
    private static BitmapSource? DecodeIcon(byte[] bytes)
    {
        try
        {
            using var stream = new MemoryStream(bytes);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            var frame = decoder.Frames.OrderBy(f => f.PixelWidth >= 36 ? f.PixelWidth : 10_000 - f.PixelWidth).First();
            // Copied out of the decoder: a frame of an .ico still leans on it,
            // and cannot be saved again once the decoder is gone.
            var icon = new System.Windows.Media.Imaging.WriteableBitmap(
                new FormatConvertedBitmap(frame, System.Windows.Media.PixelFormats.Pbgra32, null, 0));
            icon.Freeze();
            return icon;
        }
        catch
        {
            return null;
        }
    }
}
