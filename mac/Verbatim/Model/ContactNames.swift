import Foundation
import Contacts

/// Names from your contacts for the Dictionary, after you ask for them. Only names are read (first, last, and
/// company), they're compared on this device, and only the ones you pick are added. Nothing leaves the device.
enum ContactNames {
    struct Candidate: Identifiable, Hashable {
        let name: String
        /// Not a common name or word, so speech engines are likely to misspell it. These start selected.
        let unusual: Bool
        var id: String { name.lowercased() }
    }

    struct Person { var given: String; var family: String; var company: String }

    static var isAllowed: Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        return s != .notDetermined && s != .denied && s != .restricted
    }

    /// Asks for Contacts access (the system shows its prompt once).
    static func requestAccess() async -> Bool {
        if isAllowed { return true }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            CNContactStore().requestAccess(for: .contacts) { ok, _ in c.resume(returning: ok) }
        }
    }

    /// Reads names only. Runs off the main thread (Contacts blocks while it reads).
    static func people() async -> [Person] {
        await Task.detached(priority: .userInitiated) { () -> [Person] in
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var out: [Person] = []
            do {
                try CNContactStore().enumerateContacts(with: request) { c, _ in
                    out.append(Person(given: c.givenName, family: c.familyName, company: c.organizationName))
                }
            } catch {
                Log.note("contacts: read failed (\(error))")
            }
            return out
        }.value
    }

    /// A contact's name as Contacts shows it: first and last, else the company.
    private static func displayName(_ c: CNContact) -> String? {
        let full = [c.givenName, c.familyName].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        let company = c.organizationName.trimmingCharacters(in: .whitespaces)
        return company.isEmpty ? nil : company
    }

    private static let nameKeys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]

    /// The names of contacts Contacts' own search finds for `name` (at most 5), for a name a call window showed
    /// (CallWindowNames.preferContact). Only with access already allowed; it never asks. Blocks while Contacts reads, so
    /// call it off the main thread.
    static func fullNames(matching name: String) -> [String] {
        guard isAllowed, !name.isEmpty else { return [] }
        let found = (try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: nameKeys)) ?? []
        return Array(found.prefix(5).compactMap(displayName))
    }

    /// The one contact with this phone number or email, by name, for a call window that showed a number instead of a
    /// name. Nil without access (it never asks), with no match, or with more than one. Only names are read. Blocks while
    /// Contacts reads, so call it off the main thread.
    static func name(forHandle handle: String) -> String? {
        guard isAllowed, !handle.isEmpty else { return nil }
        let predicate = handle.contains("@") ? CNContact.predicateForContacts(matchingEmailAddress: handle)
            : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
        let found = (try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: nameKeys)) ?? []
        let names = Set(found.compactMap(displayName))
        return names.count == 1 ? names.first : nil
    }

    /// Every contact's name (first and last, else the company), each once, for "Who was this with?" as you type. Only
    /// with access already allowed; it never asks. Runs off the main thread.
    static func allNames() async -> [String] {
        guard isAllowed else { return [] }
        let people = await people()
        var seen = Set<String>(), out: [String] = []
        for p in people {
            let full = [p.given, p.family].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            let n = full.isEmpty ? p.company.trimmingCharacters(in: .whitespaces) : full
            guard n.count >= 2, seen.insert(n.lowercased()).inserted else { continue }
            out.append(n)
        }
        return out
    }

    /// Full names, plus single names and companies that aren't ordinary words, minus anything already in the
    /// Dictionary or the built-in vocabulary. Sorted by name.
    static func candidates(_ people: [Person], dictionary: [DictionaryEntry]) -> [Candidate] {
        let known = Set(dictionary.map { $0.preferred.lowercased() })
        var seen = Set<String>()
        var out: [Candidate] = []
        func add(_ raw: String, unusual: Bool) {
            let name = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let k = name.lowercased()
            guard name.count >= 2, name.count <= 40, !name.contains("@"), name.rangeOfCharacter(from: .decimalDigits) == nil,
                  !known.contains(k), !BuiltInVocabulary.contains(name), seen.insert(k).inserted else { return }
            out.append(Candidate(name: name, unusual: unusual))
        }
        for p in people {
            let given = p.given.trimmingCharacters(in: .whitespaces), family = p.family.trimmingCharacters(in: .whitespaces)
            if !given.isEmpty, !family.isEmpty {
                add("\(given) \(family)", unusual: isUnusual(given) || isUnusual(family))
            } else if let single = [given, family].first(where: { !$0.isEmpty }), isUnusual(single) {
                add(single, unusual: true)
            }
            let company = p.company.trimmingCharacters(in: .whitespaces)
            if !company.isEmpty, !CommonWords.isOrdinary(company) { add(company, unusual: company.split(separator: " ").contains { isUnusual(String($0)) }) }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Not a common English word or a common first or last name.
    static func isUnusual(_ word: String) -> Bool {
        let w = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard w.count >= 2 else { return false }
        if w.contains(where: { !$0.isASCII }) { return true }   // Siobhán, Zoë
        return !CommonWords.set.contains(w) && !commonNames.contains(w)
    }

    /// Names speech engines already spell well.
    static let commonNames: Set<String> = [
        "james", "john", "robert", "michael", "william", "david", "richard", "joseph", "thomas", "charles", "chris",
        "christopher", "daniel", "matthew", "matt", "anthony", "mark", "donald", "steven", "steve", "paul", "andrew",
        "andy", "joshua", "josh", "kenneth", "kevin", "brian", "george", "timothy", "tim", "ronald", "jason", "edward",
        "jeffrey", "jeff", "ryan", "jacob", "gary", "nicholas", "nick", "eric", "jonathan", "stephen", "larry",
        "justin", "scott", "brandon", "benjamin", "ben", "samuel", "sam", "frank", "gregory", "greg", "raymond",
        "alexander", "alex", "patrick", "jack", "dennis", "jerry", "tyler", "aaron", "jose", "adam", "henry", "nathan",
        "douglas", "zachary", "peter", "kyle", "walter", "ethan", "jeremy", "harold", "keith", "christian", "roger",
        "noah", "gerald", "carl", "terry", "sean", "austin", "arthur", "lawrence", "jesse", "dylan", "bryan", "joe",
        "jordan", "billy", "bruce", "albert", "willie", "gabriel", "logan", "alan", "juan", "wayne", "roy", "ralph",
        "randy", "eugene", "vincent", "russell", "elijah", "louis", "bobby", "philip", "johnny", "mary", "patricia",
        "jennifer", "linda", "elizabeth", "barbara", "susan", "jessica", "sarah", "karen", "nancy", "lisa", "betty",
        "margaret", "sandra", "ashley", "kimberly", "emily", "donna", "michelle", "dorothy", "carol", "amanda",
        "melissa", "deborah", "stephanie", "rebecca", "sharon", "laura", "cynthia", "kathleen", "amy", "shirley",
        "angela", "helen", "anna", "brenda", "pamela", "nicole", "emma", "samantha", "katherine", "kate", "christine",
        "debra", "rachel", "catherine", "carolyn", "janet", "ruth", "maria", "heather", "diane", "virginia", "julie",
        "joyce", "victoria", "olivia", "kelly", "christina", "lauren", "joan", "evelyn", "judith", "megan", "cheryl",
        "andrea", "hannah", "martha", "jacqueline", "frances", "gloria", "ann", "teresa", "kathryn", "sara", "janice",
        "jean", "alice", "madison", "doris", "abigail", "julia", "judy", "grace", "denise", "amber", "marilyn",
        "beverly", "danielle", "theresa", "sophia", "marie", "diana", "brittany", "natalie", "isabella", "charlotte",
        "rose", "alexis", "kayla", "mom", "dad",
        "smith", "johnson", "williams", "brown", "jones", "garcia", "miller", "davis", "rodriguez", "martinez",
        "hernandez", "lopez", "gonzalez", "wilson", "anderson", "taylor", "moore", "jackson", "martin", "lee",
        "perez", "thompson", "white", "harris", "sanchez", "clark", "ramirez", "lewis", "robinson", "walker", "young",
        "allen", "king", "wright", "torres", "nguyen", "hill", "flores", "green", "adams", "nelson", "baker",
        "hall", "rivera", "campbell", "mitchell", "carter", "roberts", "phillips", "evans", "turner", "parker",
        "collins", "edwards", "stewart", "morris", "murphy", "cook", "rogers", "morgan", "cooper", "peterson", "reed",
        "bailey", "bell", "howard", "ward", "cox", "richardson", "wood", "watson", "brooks", "bennett", "gray",
        "hughes", "price", "myers", "long", "foster", "sanders", "ross", "powell", "sullivan",
        "fisher", "hamilton", "graham", "wallace", "west", "cole", "hayes", "ford", "ellis", "stone", "hunt", "black",
    ]
}
