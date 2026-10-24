import Foundation

// Test cases for CleanupGuard (Clean up and Tone's speaker labels and filler pass). Not part of
// any app target; run mac/tools/test-cleanup.sh.

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name)\n      got:  \(got.debugDescription)\n      want: \(want.debugDescription)") }
}
func check(_ name: String, _ ok: Bool) {
    if ok { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

let two = ["Tim", "Jonathan"]

// MARK: Real labels come off before the model and go back on after

let (l1, t1) = CleanupGuard.prepare("Tim: So the catalog covers the wagons.", speakers: two)
check("real label detached", l1 == "Tim" && t1 == "So the catalog covers the wagons.")
let (l2, t2) = CleanupGuard.prepare("Name: hello there friend", speakers: two)
check("'Name:' isn't a speaker here, so it stays in the text", l2 == nil && t2 == "Name: hello there friend")
let (l3, _) = CleanupGuard.prepare("Sam Lee: hi", speakers: ["Sam", "Sam Lee"])
check("longest speaker name wins", l3 == "Sam Lee")
check("one speaker: no labels at all", CleanupGuard.prepare("Tim: hi there", speakers: []).label == nil)
check("label back on", CleanupGuard.finish("So the catalog covers the wagons.", input: t1, label: "Tim", speakers: two, removeFillers: true),
      "Tim: So the catalog covers the wagons.")

// MARK: Invented labels are dropped

check("bare Name: dropped", CleanupGuard.dropInventedLabel("Name: Okay, so I want to talk it through.", input: "okay so I want to talk it through"),
      "Okay, so I want to talk it through.")
check("Name: then a line break dropped", CleanupGuard.dropInventedLabel("Name:\nThe basilisk story.", input: "the basilisk story"), "The basilisk story.")
check("bold **Name:** dropped", CleanupGuard.dropInventedLabel("**Name:** The two characters.", input: "the two characters"), "The two characters.")
check("Speaker 1: dropped", CleanupGuard.dropInventedLabel("Speaker 1: The two characters.", input: "the two characters"), "The two characters.")
check("[Name]: dropped", CleanupGuard.dropInventedLabel("[Name]: The two characters.", input: "the two characters"), "The two characters.")
check("Paragraph: dropped", CleanupGuard.dropInventedLabel("Paragraph: The two characters.", input: "the two characters"), "The two characters.")
check("Paragraph: Name: both dropped", CleanupGuard.dropInventedLabel("Paragraph: Name: The two characters.", input: "the two characters"), "The two characters.")
check("a speaker's name the input didn't have is dropped", CleanupGuard.dropInventedLabel("Tim: The two characters.", input: "the two characters", speakers: two),
      "The two characters.")
check("Name: on a later line dropped", CleanupGuard.dropInventedLabel("First part.\nName: second part.", input: "first part second part"), "First part.\nsecond part.")
check("the input's own label stays", CleanupGuard.dropInventedLabel("Note: buy milk.", input: "Note: buy milk"), "Note: buy milk.")
check("the input's first word kept, colon dropped", CleanupGuard.dropInventedLabel("Yeah: the two characters.", input: "Yeah the two characters"), "Yeah the two characters.")
check("an ordinary sentence is untouched", CleanupGuard.dropInventedLabel("Here's the thing: it works.", input: "here's the thing it works"), "Here's the thing: it works.")
check("a time isn't a label", CleanupGuard.dropInventedLabel("At 10:30 we start.", input: "at 10:30 we start"), "At 10:30 we start.")
check("a URL isn't a label", CleanupGuard.dropInventedLabel("Https://example.com is up.", input: "https://example.com is up"), "Https://example.com is up.")
check("no label: untouched", CleanupGuard.dropInventedLabel("Okay, so I just want to talk more.", input: "okay so"), "Okay, so I just want to talk more.")

// MARK: Fillers are guaranteed at levels that remove them

check("um and uh removed", CleanupGuard.removeFillers("Okay, so I just want to talk more through um the basilisk story. The uh, two guys."),
      "Okay, so I just want to talk more through the basilisk story. The two guys.")
check("trailing um removed", CleanupGuard.removeFillers("I'm balancing it on the names now. Um"), "I'm balancing it on the names now.")
check("filler-only paragraph becomes empty", CleanupGuard.removeFillers("Um."), "")
check("filler-only with commas becomes empty", CleanupGuard.removeFillers("Uh, um…"), "")
check("leading um removed, capitalized", CleanupGuard.removeFillers("um we should meet Friday."), "We should meet Friday.")
check("uh huh means yes and stays", CleanupGuard.removeFillers("Uh huh, that works."), "Uh huh, that works.")
check("finish: label dropped, fillers gone, real label back",
      CleanupGuard.finish("Name: Yeah, the two characters. Um", input: "yeah the two characters um", label: "Tim", speakers: two, removeFillers: true),
      "Tim: Yeah, the two characters.")
check("finish at None keeps fillers", CleanupGuard.finish("Yeah, um, the two characters.", input: "yeah um the two characters", label: nil, speakers: [], removeFillers: false),
      "Yeah, um, the two characters.")
check("finish: only fillers left gives empty, even with a label", CleanupGuard.finish("Um.", input: "Um", label: "Tim", speakers: two, removeFillers: true), "")

// MARK: Saved Cleaned text with "Name:" from builds up to 184

let saved = "Name: Okay, so I just want to talk.\n\nName:\nThe basilisk story.\n\nThere's at least four.\n\n**Name:** Yeah.\n\nName:"
check("saved Name: labels hidden", CleanupGuard.hidePlaceholderLabels(saved, speakers: ["Speaker 1"]),
      "Okay, so I just want to talk.\n\nThe basilisk story.\n\nThere's at least four.\n\nYeah.")
check("kept when a speaker is called Name", CleanupGuard.hidePlaceholderLabels(saved, speakers: ["Name", "Tim"]) == saved)
check("text without Name: unchanged", CleanupGuard.hidePlaceholderLabels("Tim: hi\n\nJonathan: hello", speakers: two) == "Tim: hi\n\nJonathan: hello")
check("Name: mid-paragraph unchanged", CleanupGuard.hidePlaceholderLabels("My Name: Tim", speakers: []) == "My Name: Tim")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("All cleanup tests passed.")
