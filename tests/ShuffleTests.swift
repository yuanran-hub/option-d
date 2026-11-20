import Foundation

// Compile with book/BookData.swift. The test uses a disposable preferences domain.
@main
struct ShuffleTests {
    struct Card: Identifiable {
        let id: String
        init(_ n: Int) { id = String(format: "%03d", n) }
    }

    static func main() {
        let domain = "OptionD.shuffle.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var deck = BookShuffle("test", defaults: defaults)
        var cards = (0..<48).map(Card.init)
        var query = ""
        func order(_ newRound: Bool = false) -> [String] {
            BookOrder.random.arrange(cards, matching: { $0.id.hasPrefix(query) }, added: { _ in "" },
                                     shuffle: deck, newRound: newRound).map(\.id)
        }

        let ids = Set(cards.map(\.id))
        var previous = order()
        var seen: Set<[String]> = [previous]
        for i in 0..<1000 {
            if i.isMultiple(of: 2) { deck = BookShuffle("test", defaults: defaults) }
            let next = order(true)
            precondition(next.first != previous.first && Set(next) == ids && next.count == ids.count)
            precondition(order() == next)
            seen.insert(next)
            previous = next
        }

        query = "01"
        let filtered = order()
        precondition(filtered == previous.filter { $0.hasPrefix(query) })
        let next = order(true)
        precondition(next.first != filtered.first && Set(next) == Set(filtered))
        query = ""
        let unfiltered = order()
        precondition(unfiltered.filter { $0.hasPrefix("01") } == next)
        cards.append(Card(99))
        let extended = order()
        precondition(extended.filter { $0 != "099" } == unfiltered && extended.contains("099"))
        cards.removeAll { $0.id == unfiltered[0] }
        precondition(order() == extended.filter { $0 != unfiltered[0] })

        cards = []
        precondition(order(true).isEmpty)
        cards = [Card(1)]
        precondition(order(true) == ["001"] && order(true) == ["001"])
        cards.append(Card(2))
        let pair = order(true)
        precondition(order(true) == Array(pair.reversed()))
        precondition(order(true) == pair)
        print("Verified 1000 rounds, including 500 recreated decks. Distinct full orders observed: \(seen.count).")
    }
}
