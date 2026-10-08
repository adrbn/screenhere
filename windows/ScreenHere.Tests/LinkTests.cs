using System.Net;

namespace ScreenHere.Tests;

public class CopiedLinkTests
{
    [Theory]
    [InlineData("https://github.com/adrbn/screenhere")]
    [InlineData("  http://example.com/page?x=1  ")]
    [InlineData("HTTPS://Example.com")]
    public void AWebAddressAloneIsALink(string text)
    {
        Assert.NotNull(CopiedLink.From(text));
    }

    [Theory]
    [InlineData("see https://example.com")]
    [InlineData("https://example.com and more")]
    [InlineData("example.com")]
    [InlineData("file:///C:/a.txt")]
    [InlineData("https://")]
    [InlineData(null)]
    public void AnythingElseIsNot(string? text)
    {
        Assert.Null(CopiedLink.From(text));
    }

    [Fact]
    public void ItShowsWithoutSchemeOrWww()
    {
        var link = CopiedLink.From("https://www.github.com/adrbn/screenhere/")!;
        Assert.Equal("github.com", link.Host);
        Assert.Equal("github.com/adrbn/screenhere", link.Display);
    }

    [Fact]
    public void TheSameAddressIsTheSameLink()
    {
        Assert.Equal(CopiedLink.From("https://example.com/a"), CopiedLink.From(" https://example.com/a "));
        Assert.NotEqual(CopiedLink.From("https://example.com/a"), CopiedLink.From("https://example.com/b"));
    }
}

public class LinkSafetyTests
{
    private static bool MayVisit(string url) => LinkSafety.MayVisit(new Uri(url));

    [Theory]
    [InlineData("https://github.com/adrbn/screenhere")]
    [InlineData("https://example.com/blog/how-to-build-a-tray-app")]
    [InlineData("https://example.com/docs/LinkPreviewController")]
    [InlineData("https://www.youtube.com/watch?v=dQw4w9WgXcQ")]
    [InlineData("https://example.com/page?utm_source=newsletter&fbclid=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789")]
    [InlineData("https://example.com:443/")]
    public void OrdinaryPagesMayBeVisited(string url)
    {
        Assert.True(MayVisit(url));
    }

    [Theory]
    [InlineData("http://example.com/")]                        // not encrypted
    [InlineData("https://example.com:8443/")]                  // a port
    [InlineData("https://user:secret@example.com/")]           // a password
    [InlineData("https://localhost/")]
    [InlineData("https://printer.local/")]
    [InlineData("https://nas.home.arpa/")]
    [InlineData("https://machine.tailnet.ts.net/")]
    [InlineData("https://192.168.1.10/")]
    [InlineData("https://[::1]/")]
    [InlineData("https://intranet/")]
    public void LocalAndUnencryptedAddressesAreLeftAlone(string url)
    {
        Assert.False(MayVisit(url));
    }

    [Theory]
    [InlineData("https://login.example.com/")]
    [InlineData("https://example.com/reset-password")]
    [InlineData("https://example.com/sign-in")]
    [InlineData("https://example.com/users/confirmation")]
    [InlineData("https://example.com/unsubscribe/me")]
    [InlineData("https://example.com/invite/abc")]
    [InlineData("https://example.com/page?token=abc")]
    [InlineData("https://example.com/page?access_token=abc")]
    [InlineData("https://example.com/page?code=1234")]
    [InlineData("https://example.com/page?next=https://other.example.com/")]
    [InlineData("https://example.com/s/4f9a8b7c6d5e4f3a2b1c")]
    [InlineData("https://example.com/d/550e8400-e29b-41d4-a716-446655440000")]
    [InlineData("https://example.com/x/AbCdEfGhIjKlMnOpQr")]
    public void LinksThatLookPrivateOrSingleUseAreLeftAlone(string url)
    {
        Assert.False(MayVisit(url));
    }

    [Fact]
    public void AVisitLeavesTrackingAndTheFragmentBehind()
    {
        var visited = LinkSafety.VisitUrl(new Uri("https://example.com/page?id=7&utm_source=x&gclid=y#section"));
        Assert.Equal("https://example.com/page?id=7", visited.AbsoluteUri);
        Assert.Equal("https://example.com/page", LinkSafety.VisitUrl(new Uri("https://example.com/page?utm_medium=mail")).AbsoluteUri);
    }

    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("10.1.2.3")]
    [InlineData("172.16.0.1")]
    [InlineData("172.31.255.255")]
    [InlineData("192.168.0.1")]
    [InlineData("169.254.10.10")]
    [InlineData("100.64.0.1")]       // carrier-grade NAT, Tailscale
    [InlineData("0.0.0.0")]
    [InlineData("224.0.0.1")]
    [InlineData("::1")]
    [InlineData("::")]
    [InlineData("fe80::1")]
    [InlineData("fd00::1")]
    [InlineData("::ffff:192.168.1.1")]
    [InlineData("64:ff9b::10.0.0.1")]
    [InlineData("2002:c0a8:0101::1")] // 6to4 of 192.168.1.1
    [InlineData("2001:db8::1")]
    [InlineData("not an address")]
    public void PrivateAddressesAreRecognised(string address)
    {
        Assert.True(LinkSafety.IsPrivateAddress(address));
    }

    [Theory]
    [InlineData("8.8.8.8")]
    [InlineData("140.82.121.4")]
    [InlineData("172.32.0.1")]
    [InlineData("100.128.0.1")]
    [InlineData("2606:4700:4700::1111")]
    [InlineData("::ffff:8.8.8.8")]
    public void PublicAddressesAreNot(string address)
    {
        Assert.False(LinkSafety.IsPrivateAddress(IPAddress.Parse(address)));
    }
}

public class PageHeadParserTests
{
    private static readonly Uri Page = new("https://example.com/blog/post");

    [Fact]
    public void TheSocialTitleWinsOverTheTitleElement()
    {
        var head = PageHeadParser.Parse("""
            <html><head><title>Post | Example</title>
            <meta property="og:title" content="A &amp; B &#8212; the post">
            </head><body><title>not this</title></body></html>
            """, Page);
        Assert.Equal("A & B — the post", head.Title);
    }

    [Fact]
    public void TheTitleElementIsCleanedToOneLine()
    {
        var head = PageHeadParser.Parse("<head><TITLE>\n  Hello\n   world \n</TITLE></head>", Page);
        Assert.Equal("Hello world", head.Title);
    }

    [Fact]
    public void ARealIconWinsOverApplesAndResolvesAgainstThePage()
    {
        var head = PageHeadParser.Parse("""
            <head>
            <link rel="apple-touch-icon" href="/apple.png" sizes="180x180">
            <link rel="shortcut icon" href='../favicon-32.png' sizes="32x32">
            <link rel="icon" href=/favicon-64.png sizes=64x64>
            <link rel="stylesheet" href="/style.css">
            </head>
            """, Page);
        Assert.Equal("https://example.com/favicon-64.png", head.Icon!.AbsoluteUri);
    }

    [Fact]
    public void WithNoIconDeclaredItIsTheSitesFavicon()
    {
        var head = PageHeadParser.Parse("<head><title>x</title></head>", Page);
        Assert.Equal("https://example.com/favicon.ico", head.Icon!.AbsoluteUri);
    }

    [Fact]
    public void APageWithNoTitleHasNone()
    {
        Assert.Null(PageHeadParser.Parse("<head><title>  </title></head>", Page).Title);
        Assert.Null(PageHeadParser.Parse("", Page).Title);
    }

    [Fact]
    public void TextIsReadInTheEncodingThePageDeclares()
    {
        System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
        var latin = System.Text.Encoding.Latin1.GetBytes("<meta charset=\"iso-8859-1\"><title>Déjà</title>");
        Assert.Contains("Déjà", LinkVisitor.Text(latin, null));
        Assert.Contains("Déjà", LinkVisitor.Text(System.Text.Encoding.UTF8.GetBytes("<title>Déjà</title>"), null));
        Assert.Contains("Déjà", LinkVisitor.Text(System.Text.Encoding.GetEncoding(1252).GetBytes("<title>Déjà</title>"), "windows-1252"));
    }
}
