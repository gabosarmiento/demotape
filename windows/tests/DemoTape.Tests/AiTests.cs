using DemoTape.Domain.Ai;
using Xunit;

namespace DemoTape.Tests;

public class AiTests
{
    [Fact]
    public void ParseVerboseJson_ReadsSegments()
    {
        var json = """
        { "text": "hello world",
          "segments": [
            { "start": 0.0, "end": 1.5, "text": " hello" },
            { "start": 1.5, "end": 3.0, "text": "world " },
            { "start": 3.0, "end": 3.2, "text": "   " }
          ] }
        """;
        var cues = CaptionFormats.ParseVerboseJson(json);
        Assert.Equal(2, cues.Count); // empty segment dropped
        Assert.Equal("hello", cues[0].Text);
        Assert.Equal(1.5, cues[1].Start);
    }

    [Fact]
    public void ParseVerboseJson_FallsBackToWholeText()
    {
        var cues = CaptionFormats.ParseVerboseJson("""{ "text": "just one line" }""");
        Assert.Single(cues);
        Assert.Equal("just one line", cues[0].Text);
    }

    [Fact]
    public void SrtRoundTrip_Parses()
    {
        var cues = new[] { new CaptionCue(0, 1.5, "one"), new CaptionCue(1.5, 3, "two") };
        var srt = CaptionFormats.ToSrt(cues);
        var parsed = CaptionFormats.ParseSrt(srt);
        Assert.Equal(2, parsed.Count);
        Assert.Equal("two", parsed[1].Text);
        Assert.Equal(1.5, parsed[1].Start, 3);
    }

    [Fact]
    public void ParseVoices_ReadsLabelsAndPreview()
    {
        var json = """
        { "voices": [
            { "voice_id": "v1", "name": "Rachel", "labels": {"gender":"female","accent":"american"}, "preview_url": "https://x/p.mp3" },
            { "voice_id": "v2", "name": "Josh" }
        ] }
        """;
        var voices = VoiceoverPlanner.ParseVoices(json);
        Assert.Equal(2, voices.Count);
        Assert.Equal("Rachel (american)", voices[0].Label);
        Assert.Equal("Josh", voices[1].Label);
        Assert.Equal("https://x/p.mp3", voices[0].PreviewUrl);
    }

    [Fact]
    public void VoiceoverPaths_StripStyledMarker()
    {
        var video = Path.Combine("C:", "vids", "Demo 1.styled.mp4");
        Assert.EndsWith("Demo 1.voiceover.mp4", VoiceoverPlanner.OutputPath(video));
        Assert.EndsWith("Demo 1.captioned.mp4", VoiceoverPlanner.CaptionedPath(video));
        Assert.EndsWith("Demo 1.transcript.json", VoiceoverPlanner.TranscriptPath(video));
    }

    [Fact]
    public void ScriptFromCues_JoinsNonEmpty()
    {
        var cues = new[] { new CaptionCue(0, 1, "Hello"), new CaptionCue(1, 2, "  "), new CaptionCue(2, 3, "there") };
        Assert.Equal("Hello there", VoiceoverPlanner.ScriptFromCues(cues));
    }

    [Fact]
    public void HeyGen_EncodeCreateBody_LibraryAvatar()
    {
        var req = new AvatarGenerationRequest(new AvatarSource.Library("av1"), "aud1", Engine: "avatar_iii");
        var json = HeyGenApi.EncodeCreateBody(req);
        Assert.Contains("\"type\":\"avatar\"", json);
        Assert.Contains("\"avatar_id\":\"av1\"", json);
        Assert.Contains("\"audio_asset_id\":\"aud1\"", json);
        Assert.Contains("avatar_iii", json);
    }

    [Fact]
    public void HeyGen_EncodeCreateBody_Photo()
    {
        var req = new AvatarGenerationRequest(new AvatarSource.Photo("img1"), "aud1", MotionPrompt: "wave");
        var json = HeyGenApi.EncodeCreateBody(req);
        Assert.Contains("\"type\":\"image\"", json);
        Assert.Contains("\"asset_id\":\"img1\"", json);
        Assert.Contains("wave", json);
    }

    [Fact]
    public void HeyGen_ParseAvatars_And_Status()
    {
        var avatars = HeyGenApi.ParseAvatars("""{ "data": { "avatars": [ { "avatar_id":"a1","avatar_name":"Rae","premium":false } ] } }""");
        Assert.Single(avatars);
        Assert.Equal("Rae", avatars[0].Name);

        Assert.IsType<AvatarJobStatus.Completed>(HeyGenApi.ParseStatus("""{ "data": { "status":"completed", "video_url":"https://x/v.mp4" } }"""));
        Assert.IsType<AvatarJobStatus.Pending>(HeyGenApi.ParseStatus("""{ "data": { "status":"pending" } }"""));
        Assert.IsType<AvatarJobStatus.Failed>(HeyGenApi.ParseStatus("""{ "data": { "status":"failed", "error": { "message":"nope" } } }"""));
        Assert.Equal("v99", HeyGenApi.ParseVideoId("""{ "data": { "video_id":"v99" } }"""));
    }
}
