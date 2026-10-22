import Foundation

/// One transcription, start to finish, shared by the Mac and the iPhone: engine, optional speakers,
/// Dictionary fixes, and the waveform. No UI and no Store access, so it runs off the main thread.
struct JobOutcome {
    var original: [Segment]
    var fixed: [Segment]
    var speakers: [Speaker]
    var corrections: [Correction]
    var wave: [Float]
    var engine: String
    var model: String
    var language: String?
}

/// How a job handles language and long recordings. The defaults run exactly as before (no language check, the
/// whole file at once).
struct JobOptions {
    /// Transcribe long recordings in sections, saving each finished one (the iPhone).
    var sectioned = false
    /// The recording's file name, for the saved sections.
    var audioName: String? = nil
    /// The language you picked (Transcribe again in…). Skips the check.
    var languageChoice: String? = nil
    /// Check the language from the first seconds (Settings › Detect the language).
    var detectLanguage = false
    /// Check it with Parakeet v3, downloading v3 first if it isn't here (you chose Download on the offer).
    var checkWithV3 = false
    /// The recording sounds like a language Parakeet v3 handles, and v3 isn't downloaded (nil: the language is
    /// unclear, but it isn't English). The job carries on with the model you picked.
    var offerV3: (@Sendable (String?) -> Void)? = nil
}

enum TranscriptionJob {
    static func run(url: URL, engineId: String, model: String, wantSpeakers: Bool, dictionary: [DictionaryEntry],
                    project: UUID?, needWave: Bool, options: JobOptions = JobOptions(),
                    progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> JobOutcome {
        var result = try await words(url: url, engineId: engineId, model: model, options: options, progress: progress)
        Log.note("transcribe done segments=\(result.segments.count)")
        var speakers: [Speaker] = []
        if wantSpeakers, result.segments.count > 1 {
            do {
                let found = try await FluidDiarizer.shared.diarizeDetailed(url: url, progress: progress)
                speakers = SpeakerAssigner.assign(found, to: &result.segments)
                Log.note("diarize done speakers=\(speakers.count)")
            } catch {
                Log.note("diarize failed (kept transcript): \(error)")
            }
        }
        let original = result.segments
        var fixed = result.segments
        var corrections: [Correction] = []
        if !dictionary.isEmpty || BuiltInVocabulary.isActive {
            progress(.applyingDictionary)
            corrections = DictionaryApplier.apply(dictionary, to: &fixed, project: project)
        }
        let wave = needWave ? Waveform.envelope(of: url) : []
        return JobOutcome(original: original, fixed: fixed, speakers: speakers, corrections: corrections, wave: wave,
                          engine: result.engine, model: result.model, language: result.language)
    }

    /// The words: picks the engine and model for the recording's language, then transcribes it whole or in sections.
    private static func words(url: URL, engineId: String, model requested: String, options: JobOptions,
                              progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> EngineResult {
        // Whisper identifies the language itself; the language check and sections are for Parakeet.
        guard engineId == "fluid" else {
            return try await Engines.engine(for: engineId).transcribe(url: url, model: requested, progress: progress)
        }
        var engine = "fluid"
        var model = Engines.fluidModel(requested)
        var language: String? = nil
        var firstPass: LanguageDetection.Outcome? = nil
        let frames = options.sectioned ? (try? SectionAudio(url: url))?.frames : nil

        // A job stopped part way (iOS needed the time back, or the app was closed) keeps the engine, model, and
        // language it started with, so its saved sections still fit.
        if options.sectioned, let name = options.audioName, let saved = SectionCheckpoint.savedHeader(audio: name),
           saved.frames == frames, options.languageChoice == nil || options.languageChoice == saved.language {
            engine = saved.engine; model = saved.model; language = saved.language
        } else {
            let guess: LanguageGuess?
            if let choice = options.languageChoice {
                guess = .known(choice, 1)
            } else if options.detectLanguage, let outcome = await LanguageDetection.check(url: url, model: model, forceV3: options.checkWithV3, progress: progress) {
                firstPass = outcome
                guess = outcome.guess
            } else {
                guess = nil
            }
            if let guess {
                let route = LanguageRoute.decide(guess, model: model, v3Downloaded: FluidEngine.isDownloaded("v3"),
                                                 appleSupports: AppleSpeech.isAvailable, explicit: options.languageChoice != nil)
                Log.note("language route: \(route)")
                switch route {
                case .keep(let l): language = l
                case .useV3(let l): model = "v3"; language = l
                case .offerV3(let l): language = l; options.offerV3?(l)
                case .apple(let l):
                    guard await AppleSpeech.ensureAuthorized() else {
                        throw LanguageJobError.message("Turn on Speech Recognition for Verbatim in Settings to transcribe \(LanguageDetection.name(l)).")
                    }
                    engine = "apple"; language = l
                case .unsupported(let l): throw LanguageJobError.message(LanguageRoute.unsupportedMessage(l))
                }
            }
        }

        let name = engine == "apple" ? "Apple speech recognition" : Engines.displayName(engine: "fluid", model: model)
        let joiner = LanguageRules.joiner(for: language)
        func segments(_ w: [SectionWord]) -> [Segment] {
            Engines.segments(fromWords: w.map { WordSpan(text: $0.text, start: $0.start, end: $0.end) }, separator: joiner)
        }

        // A short recording the check already heard whole, with the model the job uses: that's the transcript (unless
        // a language hint, which the check ran without, would change a multilingual model's output).
        let hintApplies = LanguageRules.isMultilingual(model) && language != nil && language != "en"
        if engine == "fluid", let pass = firstPass, pass.coveredWhole, pass.passModel == model, !hintApplies {
            return EngineResult(segments: segments(pass.words), language: language, engine: "fluid", model: name)
        }

        let plan: SectionPlan = engine == "apple" ? .apple : .parakeet
        let audio: SectionAudio? = try (engine == "apple" || options.sectioned) ? SectionAudio(url: url) : nil
        // Apple's recognizer always goes a section at a time; Parakeet does on the iPhone, for recordings past one section.
        if let audio, engine == "apple" || audio.totalSamples > plan.singleSectionLimit {
            var checkpoint: SectionCheckpoint? = nil
            if options.sectioned, let audioName = options.audioName {
                checkpoint = SectionCheckpoint.open(SectionCheckpoint.Header(audio: audioName, frames: audio.frames, engine: engine, model: model,
                                                                             language: language, window: plan.window, overlap: plan.overlap))
            }
            let lang = language, mdl = model
            let section: SectionedTranscriber.Engine
            if engine == "apple", let l = lang {
                section = SectionedTranscriber.Engine(id: "apple", plan: plan) { try await AppleSpeech.words(samples: $0, language: l) }
            } else {
                section = SectionedTranscriber.Engine(id: "fluid", plan: plan) {
                    try await FluidEngine.shared.sectionWords(samples: $0, model: mdl, language: lang, progress: progress)
                }
            }
            let words = try await SectionedTranscriber.run(url: url, audio: audio, engine: section, checkpoint: checkpoint, progress: progress)
            return EngineResult(segments: segments(words), language: language, engine: engine, model: name)
        }
        return try await FluidEngine.shared.transcribe(url: url, model: model, language: language, progress: progress)
    }
}

enum LanguageJobError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}
