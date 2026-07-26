import Foundation

/// Adding another language to a demo that already works.
///
/// The mechanics live in `Voiceover` (synthesize each line, lay it at its moment, write a variant
/// file). This is the part around it: which languages are worth offering, what a run will cost in
/// credits, and — because translating well is a judgement call, not a lookup — the prompt a user hands
/// to their own coding agent so it does the translation, checks the fit, and tightens the lines that
/// run long. Same loop a person would do by hand, just delegated.
enum NarrationLocalization {

    struct Language: Equatable {
        let code: String       // used as the file tag: …voiceover.es.mp4
        let name: String       // shown in the picker
        let endonym: String    // what speakers call it, so the list reads naturally
    }

    /// Languages the multilingual speech models handle well. Deliberately a curated list rather than
    /// every locale: a picker of 90 entries is worse than one of 20, and a language the model speaks
    /// badly is not a feature.
    static let languages: [Language] = [
        Language(code: "es", name: "Spanish", endonym: "Español"),
        Language(code: "fr", name: "French", endonym: "Français"),
        Language(code: "de", name: "German", endonym: "Deutsch"),
        Language(code: "pt", name: "Portuguese", endonym: "Português"),
        Language(code: "it", name: "Italian", endonym: "Italiano"),
        Language(code: "nl", name: "Dutch", endonym: "Nederlands"),
        Language(code: "pl", name: "Polish", endonym: "Polski"),
        Language(code: "sv", name: "Swedish", endonym: "Svenska"),
        Language(code: "tr", name: "Turkish", endonym: "Türkçe"),
        Language(code: "ru", name: "Russian", endonym: "Русский"),
        Language(code: "uk", name: "Ukrainian", endonym: "Українська"),
        Language(code: "cs", name: "Czech", endonym: "Čeština"),
        Language(code: "ar", name: "Arabic", endonym: "العربية"),
        Language(code: "hi", name: "Hindi", endonym: "हिन्दी"),
        Language(code: "ja", name: "Japanese", endonym: "日本語"),
        Language(code: "ko", name: "Korean", endonym: "한국어"),
        Language(code: "zh", name: "Chinese", endonym: "中文"),
        Language(code: "id", name: "Indonesian", endonym: "Bahasa Indonesia"),
        Language(code: "en", name: "English", endonym: "English")
    ]

    static func language(forCode code: String) -> Language? {
        languages.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    /// "Spanish (Español)" — the picker label.
    static func label(for language: Language) -> String {
        language.name == language.endonym ? language.name : "\(language.name) (\(language.endonym))"
    }

    // MARK: - Cost

    /// Characters a run will send to the speech provider. Hosted TTS bills per character, so this is
    /// the number that predicts the bill — shown BEFORE generating, because finding out afterwards
    /// that a 14-scene demo cost 3,000 credits is a bad way to learn it.
    static func characterCount(of lines: [Voiceover.TimedLine]) -> Int {
        lines.reduce(0) { $0 + $1.say.count }
    }

    /// A plain sentence about what this run costs against what's left. `remaining` nil = unknown.
    static func costSummary(characters: Int, remaining: Int?) -> String {
        let chars = characters.formatted
        guard let remaining = remaining else { return "About \(chars) characters of speech." }
        if characters > remaining {
            return "About \(chars) characters of speech — more than the \(remaining.formatted) credits left."
        }
        let after = remaining - characters
        return "About \(chars) characters of speech · \(remaining.formatted) credits now, \(after.formatted) after."
    }

    /// The language a file's own name declares, from the variant tag DemoTape writes
    /// (`…voiceover.fr.mp4` → French). Used to preselect the right language instead of asking the
    /// user to tell the app something it can already see.
    static func languageOfFile(_ url: URL) -> Language? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".")
        for part in parts.reversed() {
            if let match = language(forCode: String(part)) { return match }
        }
        return nil
    }

    // MARK: - The agent hand-off

    /// The prompt a user pastes into their coding agent to produce this language.
    ///
    /// It names the files, the command, and — the part people miss — the fit constraint: translated
    /// speech runs longer than the English it replaces, clips are never overlapped, so one long line
    /// pushes every later line late. The tool reports which lines overran; the loop is to shorten those
    /// and run it again. Written as instructions to an agent that can read files and run commands.
    static func agentPrompt(recordingDir: String, language: Language, driverPath: String = "tools/demo-driver/driver.mjs") -> String {
        """
        Add a \(language.name) narration to a finished DemoTape demo, keeping the existing one.

        The recording is at:
          \(recordingDir)

        1. Read timeline.json in that folder. It holds the narration scene by scene: each line and the
           moment it belongs to.
        2. Translate every line to \(language.name) (\(language.endonym)). Keep the tone of a person
           talking through their own product — first person, plain, no marketing. Keep product names,
           identifiers and UI labels exactly as they appear on screen; they are not translated in the
           video. Aim for each line to be no LONGER than the English it replaces.
        3. Write the translations to lines-\(language.code).json as:
           { "tag": "\(language.code)", "lines": ["…", "…"] }
           in the same order as timeline.json (one line per scene).
        4. Run:
           node \(driverPath) narrate "\(recordingDir)" lines-\(language.code).json
        5. It prints a fit report. Any line flagged as running past its scene pushes every later line
           out of sync with the picture, so shorten the flagged lines and run it again until the total
           drift is under about a second. Only the lines you changed are re-synthesized.

        The result is …voiceover.\(language.code).mp4 beside the original, which is left untouched.
        """
    }

    /// Where a translated subtitle file should go: the same name with `language`'s code, REPLACING any
    /// language already in it. Naively appending turned a French `Demo.fr.srt` into `Demo.fr.es.srt`,
    /// which then reads as neither.
    static func translatedSRTPath(_ srtPath: String, language: Language) -> String {
        let url = URL(fileURLWithPath: srtPath)
        var stem = url.deletingPathExtension().lastPathComponent
        if let dot = stem.lastIndex(of: "."),
           self.language(forCode: String(stem[stem.index(after: dot)...])) != nil {
            stem = String(stem[..<dot])
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(language.code).srt").path
    }

    /// The prompt for CAPTIONS in another language.
    ///
    /// Different job from the narration one, and the difference is the constraint: subtitles are read,
    /// not heard, so the timings are fixed and the text has to fit inside them and inside the frame.
    /// The app can transcribe what is spoken; turning that into another language is a translation
    /// task, which is what this hands over.
    /// - Parameter hasTranscript: when false the prompt starts by transcribing, so the hand-off works
    ///   on a video nobody has transcribed yet instead of being a dead end.
    static func captionAgentPrompt(video: URL, srtPath: String, language: Language,
                                   spokenLanguage: Language? = nil, hasTranscript: Bool = true,
                                   binPath: String = "/Applications/DemoTape.app/Contents/MacOS/DemoTape") -> String {
        let from = spokenLanguage.map { " The audio is in \($0.name)." } ?? ""
        let target = translatedSRTPath(srtPath, language: language)
        let transcribeStep = hasTranscript ? "" : """

        0. There is no transcript yet, so make one first (needs the captions key configured in the app):
           "\(binPath)" --captions "\(video.path)"
           That writes the .srt below.
        """
        return """
        Write \(language.name) subtitles for a DemoTape video, and burn them in.\(from)

        Video:      \(video.path)
        Transcript: \(srtPath)
        \(transcribeStep)
        1. Read that .srt. Each entry has a start time, an end time, and a line of text.
        2. Translate each entry's TEXT to \(language.name) (\(language.endonym)). Do not change a single
           timing, do not merge entries, and do not add or remove any — subtitles are read against the
           picture, so the cue boundaries are fixed.
        3. Keep product names, identifiers and UI labels exactly as they appear on screen; the interface
           in the video is not translated.
        4. Keep it readable: aim for under ~42 characters per line and at most two lines per entry. If a
           translation won't fit, shorten the wording rather than stretching the timing.
        5. Save it as:
           \(target)
        6. Burn it in:
           "\(binPath)" --burn "\(video.path)" clean --srt "\(target)"

        That writes a new …captioned.mp4 beside the video. The video and its audio are untouched.
        """
    }
}

private extension Int {
    /// Thousands-separated, using the user's locale.
    var formatted: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}
