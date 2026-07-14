using DemoTape.Domain.Models;
using DemoTape.Domain.Publishing;
using DemoTape.Domain.Rendering;

// A tiny headless harness so you can SEE DemoTape's ported engine running without the WinUI GUI
// (which needs the Windows SDK). It drives the real, unit-tested Domain logic.

Console.WriteLine("=== DemoTape engine demo (macOS -> Windows port) ===\n");

// 1) Build a synthetic recording timeline: cursor moves, a click, then Ctrl+C.
var meta = new RecordingMetadata
{
    StartedAt = DateTimeOffset.Now,
    Duration = 3,
    CapturedKeystrokes = true,
    Display = new DisplayInfo { PixelWidth = 1920, PixelHeight = 1080, PointWidth = 1920, PointHeight = 1080, Scale = 1 },
    Cursor =
    {
        new CursorSample { T = 0.0, X = 0.50, Y = 0.50 },
        new CursorSample { T = 0.5, X = 0.72, Y = 0.30 },
        new CursorSample { T = 1.0, X = 0.80, Y = 0.28 },
        new CursorSample { T = 2.0, X = 0.80, Y = 0.28 },
    },
    Clicks = { new ClickSample { T = 1.0, X = 0.80, Y = 0.28, Button = "left" } },
    Keys = { new KeySample { T = 1.4, KeyCode = 0x43, Chars = "c", Modifiers = { "ctrl" } } },
};

// 2) Run the auto-zoom camera (FocusTimeline + critically-damped SpringCamera) at 30 fps.
var focus = new FocusTimeline(meta, maxZoom: 2.0);
var camera = new SpringCamera();
var viewport = new CameraViewport(1920, 1080);

Console.WriteLine("Auto-zoom camera over time (spring-smoothed):");
Console.WriteLine("  t(s)   zoom   center(x,y)      badge");
double dt = 1.0 / 30;
double lastT = -1;
for (double t = 0; t <= 2.0 + 1e-9; t += dt)
{
    var target = focus.Target(t);
    camera.Step(target, lastT < 0 ? dt : dt);
    lastT = t;

    if (Math.Abs(t * 10 % 2.5) < 0.34) // print ~ every 0.25s
    {
        var badge = focus.ShortcutBadge(t) ?? "-";
        Console.WriteLine($"  {t,4:0.00}   {camera.Scale,4:0.00}x  ({camera.CenterX:0.00}, {camera.CenterY:0.00})     {badge}");
    }
}

// Show the viewport crop at peak zoom (what the renderer would sample from the source).
var peak = focus.Target(1.2);
var crop = viewport.ComputeViewport(peak.Scale, peak.CenterX, peak.CenterY);
Console.WriteLine($"\nAt t=1.20s the renderer samples source rect " +
    $"[x={crop.OffsetX:0}, y={crop.OffsetY:0}, w={crop.Width:0}, h={crop.Height:0}] and scales it to 1920x1080.\n");

// 3) Web Publish planning: size estimates + responsive embed.html + README.
var tiers = new[] { 540, 720 };
double durationSeconds = 42.0;
Console.WriteLine($"Web Publish estimate for a {durationSeconds:0}s demo:");
foreach (var h in WebPublishPlanner.Tiers)
{
    double mb = WebPublishPlanner.EstimatedBytes(durationSeconds, h) / 1_000_000.0;
    Console.WriteLine($"  {h,4}p  ~{mb,5:0.0} MB  ({WebPublishPlanner.BitrateKbps[h]} kbps)");
}
Console.WriteLine($"\n  {WebPublishPlanner.EstimateSummary(durationSeconds, tiers)}");

var outDir = Path.Combine(Path.GetTempPath(), "DemoTape-demo-web");
Directory.CreateDirectory(outDir);
File.WriteAllText(Path.Combine(outDir, "embed.html"), WebPublishPlanner.BuildEmbedHtml(tiers));
File.WriteAllText(Path.Combine(outDir, "README.txt"), WebPublishPlanner.BuildReadme(tiers));

Console.WriteLine($"\nGenerated a real responsive embed + README here:\n  {outDir}");
Console.WriteLine("\n--- embed.html ---");
Console.WriteLine(WebPublishPlanner.BuildEmbedHtml(tiers));
Console.WriteLine("\n=== done ===");
