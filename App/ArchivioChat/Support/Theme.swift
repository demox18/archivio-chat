import SwiftUI
import UIKit

/// Colori vicini a quelli di WhatsApp, in versione chiara e scura.
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let accent = dynamic(0x00A884, 0x00A884)
    static let bubbleMine = dynamic(0xD9FDD3, 0x005C4B)
    static let bubbleTheirs = dynamic(0xFFFFFF, 0x202C33)
    static let chatBackground = dynamic(0xEFEAE2, 0x0B141A)
    static let pill = dynamic(0xFFFFFF, 0x182229)
    static let secondaryText = dynamic(0x667781, 0x8696A0)
    static let star = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let missing = dynamic(0xE9EDEF, 0x111B21)

    /// Colore stabile ricavato da un nome, per avatar e nomi dei mittenti.
    static func color(for name: String) -> Color {
        let palette: [UInt32] = [0x1FA855, 0x53BDEB, 0xE542A3, 0xFF8A3D, 0x7F66FF, 0x02A698, 0xD4A017, 0xE0574F]
        var h: UInt32 = 5381
        for b in name.utf8 { h = (h &* 33) &+ UInt32(b) }
        return Color(UIColor(hex: palette[Int(h % UInt32(palette.count))]))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Date e orari. Gli istanti dell'archivio sono "secondi locali": si formattano
/// sempre in UTC per ritrovare esattamente l'ora scritta nel file.
enum Dates {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let locale = Locale(identifier: "it_IT")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = utc
        f.dateFormat = format
        return f
    }

    private static let timeF = formatter("HH:mm")
    private static let dayF = formatter("d MMMM yyyy")
    private static let shortF = formatter("dd/MM/yy")
    private static let weekdayF = formatter("EEEE")
    private static let fullF = formatter("EEEE d MMMM yyyy, HH:mm:ss")
    private static let monthF = formatter("MMMM yyyy")

    static func date(_ ts: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    /// L'adesso, espresso negli stessi "secondi locali" dell'archivio.
    static var now: Int64 {
        Int64(Date().timeIntervalSince1970) + Int64(TimeZone.current.secondsFromGMT())
    }

    static func dayStart(_ ts: Int64) -> Int64 { ts - ((ts % 86_400) + 86_400) % 86_400 }

    static func time(_ ts: Int64) -> String { timeF.string(from: date(ts)) }
    static func full(_ ts: Int64) -> String { fullF.string(from: date(ts)).capitalizedFirst }
    static func long(_ ts: Int64) -> String { dayF.string(from: date(ts)) }
    static func month(_ ts: Int64) -> String { monthF.string(from: date(ts)).capitalizedFirst }

    /// Etichetta del separatore di giornata.
    static func dayLabel(_ day: Int64) -> String {
        let today = dayStart(now)
        if day == today { return "Oggi" }
        if day == today - 86_400 { return "Ieri" }
        return dayF.string(from: date(day))
    }

    /// Etichetta compatta per l'elenco delle chat.
    static func listLabel(_ ts: Int64) -> String {
        let today = dayStart(now), day = dayStart(ts)
        if day == today { return time(ts) }
        if day == today - 86_400 { return "Ieri" }
        if day > today - 7 * 86_400 && day < today { return weekdayF.string(from: date(ts)).capitalizedFirst }
        return shortF.string(from: date(ts))
    }

    /// Converte una data scelta nel calendario nell'inizio di quella giornata.
    static func dayStart(of picked: Date) -> Int64 {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: picked)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let d = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? picked
        return Int64(d.timeIntervalSince1970)
    }

    /// L'inverso: un istante dell'archivio come data per il calendario.
    static func pickerDate(_ ts: Int64) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let c = cal.dateComponents([.year, .month, .day], from: date(ts))
        return Calendar.current.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) ?? Date()
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
