using System.IO;
using System.Text.Json;

namespace ScreenHere.Tests;

public class PowerToysTests
{
    private static HashSet<KeyShortcut> Module(string json)
    {
        var found = new HashSet<KeyShortcut>();
        PowerToys.Collect(JsonDocument.Parse(json).RootElement, found);
        return found;
    }

    [Fact]
    public void AModulesShortcutsAreFoundWhereverTheyAreNested()
    {
        var found = Module("""
            {"properties":{"ActivationShortcut":{"win":true,"ctrl":false,"alt":false,"shift":true,"code":67,"key":""},
             "nested":{"list":[{"hotkey":{"win":true,"ctrl":true,"alt":false,"shift":false,"code":84}}]},
             "unset":{"win":false,"ctrl":false,"alt":false,"shift":false,"code":0},
             "noModifier":{"win":false,"ctrl":false,"alt":false,"shift":false,"code":120}},
             "name":"ColorPicker","code":"not a shortcut"}
            """);
        Assert.Equal(2, found.Count);
        Assert.Contains(new KeyShortcut('C', Modifiers.Win | Modifiers.Shift), found);
        Assert.Contains(new KeyShortcut('T', Modifiers.Win | Modifiers.Control), found);
    }

    [Fact]
    public void KeyboardManagersShortcutRemapsAreFound()
    {
        var found = new HashSet<KeyShortcut>();
        PowerToys.CollectRemaps(JsonDocument.Parse("""
            {"remapKeys":{"inProcess":[{"originalKeys":"91","newRemapKeys":"162"}]},
             "remapShortcuts":{"global":[{"originalKeys":"162;160;76","newRemapKeys":"113"},{"originalKeys":"260;81","newRemapKeys":"164;115"},{"originalKeys":"17;114","newRemapKeys":"260;9"}],
                               "appSpecific":[{"originalKeys":"164;9","newRemapKeys":"17;9","targetApp":"chrome.exe"}]}}
            """).RootElement, found);
        Assert.Equal(4, found.Count);
        Assert.Contains(new KeyShortcut('L', Modifiers.Control | Modifiers.Shift), found);
        Assert.Contains(new KeyShortcut('Q', Modifiers.Win), found);
        Assert.Contains(new KeyShortcut(0x72, Modifiers.Control), found);
        Assert.Contains(new KeyShortcut(0x09, Modifiers.Alt), found);
    }

    [Fact]
    public void SettingsAreReadFromEveryModulesFolderAndABrokenOneIsSkipped()
    {
        var folder = Directory.CreateTempSubdirectory("screenhere-powertoys").FullName;
        Directory.CreateDirectory(Path.Combine(folder, "ColorPicker"));
        Directory.CreateDirectory(Path.Combine(folder, "Broken"));
        Directory.CreateDirectory(Path.Combine(folder, "Keyboard Manager"));
        File.WriteAllText(Path.Combine(folder, "ColorPicker", "settings.json"), """{"properties":{"ActivationShortcut":{"win":true,"ctrl":false,"alt":false,"shift":true,"code":67}}}""");
        File.WriteAllText(Path.Combine(folder, "Broken", "settings.json"), "{ not json");
        File.WriteAllText(Path.Combine(folder, "Keyboard Manager", "default.json"), """{"remapShortcuts":{"global":[{"originalKeys":"162;160;51","newRemapKeys":"113"}]}}""");
        var found = PowerToys.Read(folder);
        Assert.Equal(2, found.Count);
        Assert.Contains(new KeyShortcut('3', Modifiers.Control | Modifiers.Shift), found);
        Assert.Empty(PowerToys.Read(Path.Combine(folder, "missing")));
    }

    [Fact]
    public void AShortcutOfPowerToysIsRefusedAndSoIsOneWhoseClipboardVariantIsTheirs()
    {
        var theirs = new HashSet<KeyShortcut> { new('C', Modifiers.Win | Modifiers.Shift), new('X', Modifiers.Win | Modifiers.Control | Modifiers.Shift) };
        Assert.Equal("Used by PowerToys", new KeyShortcut('C', Modifiers.Win | Modifiers.Shift).Problem(Feature.Text, [], theirs));
        Assert.Equal("Used by PowerToys", new KeyShortcut('X', Modifiers.Win | Modifiers.Shift).Problem(Feature.Screen, [], theirs));
        Assert.Null(new KeyShortcut('3', Modifiers.Win | Modifiers.Shift).Problem(Feature.Screen, [], theirs));
    }
}
