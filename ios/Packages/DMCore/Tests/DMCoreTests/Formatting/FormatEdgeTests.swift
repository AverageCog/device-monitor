import Foundation
import Testing
@testable import DMCore

/// The edge cases worth reading. Every expected value here was printed by Node running the
/// dashboard's code (the same rows are in formatting-vectors.json); none is reasoned out.
@Suite struct FormatEdgeTests {
    private let enUS = Locale(identifier: "en_US")
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let dash = "\u{2013}"

    // MARK: JavaScript's arithmetic

    @Test func mathRoundSendsHalvesUp() {
        #expect(JS.round(0.5) == 1)
        #expect(JS.round(1.5) == 2)
        #expect(JS.round(2.5) == 3)
        #expect(JS.round(-0.5) == 0)
        #expect(JS.round(-1.5) == -1)
        #expect(JS.round(-2.5) == -2)        // Swift's rounded() says -3
        #expect(JS.round(-2.51) == -3)
        // The largest double below one half does not round up, as x + 0.5 would make it.
        #expect(JS.round(0.49999999999999994) == 0)
        #expect(JS.round(-0.2).sign == .minus && JS.round(-0.5).sign == .minus && JS.round(-0.0).sign == .minus)
        #expect(JS.round(9007199254740992) == 9007199254740992)
        #expect(JS.round(.nan).isNaN && JS.round(.infinity) == .infinity && JS.round(-.infinity) == -.infinity)
    }

    @Test func toFixedRoundsTheBinaryValueAndHalvesAwayFromZero() {
        #expect(JS.toFixed(0.5, 0) == "1")       // printf("%.0f") says 0
        #expect(JS.toFixed(1.5, 0) == "2")
        #expect(JS.toFixed(2.5, 0) == "3")       // printf says 2
        #expect(JS.toFixed(-2.5, 0) == "-3")
        #expect(JS.toFixed(0.125, 2) == "0.13")  // an exact half: printf says 0.12
        #expect(JS.toFixed(1.005, 2) == "1.00")  // not a half: the double is just under 1.005
        #expect(JS.toFixed(8.345, 2) == "8.35")  // and this one is just over
        #expect(JS.toFixed(99.95, 1) == "100.0")
        #expect(JS.toFixed(-0.0, 2) == "0.00")
        #expect(JS.toFixed(-1e-7, 2) == "-0.00")
        #expect(JS.toFixed(1e21, 2) == "1e+21")
        #expect(JS.toFixed(.nan, 2) == "NaN")
    }

    @Test func numbersPrintAsJavaScriptPrintsThem() {
        #expect(JS.string(100) == "100")
        #expect(JS.string(-0.0) == "0")
        #expect(JS.string(0.1 + 0.2) == "0.30000000000000004")
        #expect(JS.string(1e15) == "1000000000000000")
        #expect(JS.string(1e20) == "100000000000000000000")
        #expect(JS.string(1e21) == "1e+21")                    // Swift: "1e+21", but 1e20 is "1e+20"
        #expect(JS.string(1.5e21) == "1.5e+21")
        #expect(JS.string(1e-7) == "1e-7")                     // Swift: "1e-07"
        #expect(JS.string(1.5e-7) == "1.5e-7")
        #expect(JS.string(9.999999e-7) == "9.999999e-7")
        #expect(JS.string(5e-324) == "5e-324")
        #expect(JS.string(1.7976931348623157e308) == "1.7976931348623157e+308")
        #expect(JS.string(-12.5) == "-12.5")
        #expect(JS.string(.nan) == "NaN" && JS.string(.infinity) == "Infinity" && JS.string(-.infinity) == "-Infinity")
    }

    @Test func localeNumbersGroupAndRoundHalvesAway() {
        #expect(JS.toLocaleString(1234, locale: enUS) == "1,234")
        #expect(JS.toLocaleString(999.9999, locale: enUS) == "1,000")
        #expect(JS.toLocaleString(1e21, locale: enUS) == "1,000,000,000,000,000,000,000")
        #expect(JS.toLocaleString(1004.9, locale: enUS) == "1,004.9")
    }

    // MARK: The formatters

    @Test func percent() {
        #expect(Format.fmtPct(nil) == dash)
        #expect(Format.fmtPct(0) == "0%")
        #expect(Format.fmtPct(-0.4) == "0%")       // -0 prints as 0
        #expect(Format.fmtPct(49.5) == "50%")
        #expect(Format.fmtPct(99.5) == "100%")
        #expect(Format.fmtPct(-2.5) == "-2%")
        #expect(Format.fmtPct(.nan) == "NaN%")
    }

    @Test func bytesSwitchUnitsAt1024() {
        #expect(Format.fmtBytes(nil) == dash)
        #expect(Format.fmtBytes(.nan) == dash)
        #expect(Format.fmtBytes(0) == "0 B")
        #expect(Format.fmtBytes(1023) == "1023 B")
        #expect(Format.fmtBytes(1023.5) == "1024 B")
        #expect(Format.fmtBytes(1024) == "1 KB")
        #expect(Format.fmtBytes(1_048_575) == "1024 KB")   // no decimals below 1 MB, so it rounds up to 1024
        #expect(Format.fmtBytes(1_048_576) == "1.0 MB")
        #expect(Format.fmtBytes(1_048_576, 0) == "1 MB")
        #expect(Format.fmtBytes(1_073_741_823) == "1024.0 MB")
        #expect(Format.fmtBytes(1_073_741_824) == "1.0 GB")
        #expect(Format.fmtBytes(1_073_741_824, 2) == "1.00 GB")
        #expect(Format.fmtBytes(1e21) == "909494701.8 TB")   // nothing above TB
        #expect(Format.fmtRate(nil) == dash)
        #expect(Format.fmtRate(1_048_576) == "1.0 MB/s")
    }

    @Test func memoryPairWritesASharedUnitOnce() {
        #expect(Format.memPair(415_538_085_888, 827_854_946_304) == "387 / 771 GB")
        #expect(Format.memPair(24_403_509_248, 38_654_705_664) == "22.7 / 36 GB")   // one decimal below 100 GB
        #expect(Format.memPair(1023, 1024) == "1023 B / 1 KB")
        #expect(Format.memPair(nil, 1_073_741_824) == "\(dash) / 1 GB")
        #expect(Format.memPair(nil, nil) == "\(dash) / \(dash)")
    }

    @Test func temperatures() {
        #expect(Format.fmtTemp(nil, .celsius) == dash)
        #expect(Format.fmtTemp(0.5, .celsius) == "1\u{B0}C")
        #expect(Format.fmtTemp(-0.5, .celsius) == "0\u{B0}C")
        #expect(Format.fmtTemp(-40, .celsius) == "-40\u{B0}C")
        #expect(Format.fmtTemp(-40, .fahrenheit) == "-40\u{B0}F")
        #expect(Format.fmtTemp(-273.15, .fahrenheit) == "-460\u{B0}F")
        #expect(Format.fmtTemp(-17.77777777777778, .fahrenheit) == "0\u{B0}F")
        #expect(Format.fmtTemp(99.5, .fahrenheit) == "211\u{B0}F")
        #expect(Format.toF(100, .fahrenheit) == 212 && Format.toF(100, .celsius) == 100)

        #expect(Format.tempStatus(nil) == nil)
        #expect(Format.tempStatus(-40) == .normal)
        #expect(Format.tempStatus(69.999) == .normal)
        #expect(Format.tempStatus(70) == .warm)
        #expect(Format.tempStatus(84.999) == .warm)
        #expect(Format.tempStatus(85) == .hot)
        #expect(Format.tempStatus(.nan) == .hot)   // NaN fails both comparisons
        #expect(Format.TempStatus.allCases.map(\.label) == ["Normal", "Warm", "Hot"])
    }

    @Test func uptimeAndAge() {
        #expect(Format.fmtUptime(nil) == "" && Format.fmtUptime(0) == "" && Format.fmtUptime(.nan) == "")
        #expect(Format.fmtUptime(59) == "0m")
        #expect(Format.fmtUptime(3599) == "59m")
        #expect(Format.fmtUptime(3600) == "1h 0m")
        #expect(Format.fmtUptime(86_399) == "23h 59m")
        #expect(Format.fmtUptime(86_400) == "1d 0h")
        #expect(Format.fmtUptime(266_440) == "3d 2h")

        let now = 1_795_213_064_123.0
        #expect(Format.ago(now, now: now) == "0s ago")
        #expect(Format.ago(now - 499, now: now) == "0s ago")
        #expect(Format.ago(now - 500, now: now) == "1s ago")
        #expect(Format.ago(now - 59_499, now: now) == "59s ago")
        #expect(Format.ago(now - 59_500, now: now) == "1m ago")
        #expect(Format.ago(now - 3_569_499, now: now) == "59m ago")
        #expect(Format.ago(now - 3_569_500, now: now) == "60m ago")   // 59.5 minutes rounds up before the hour starts
        #expect(Format.ago(now - 3_599_500, now: now) == "1h ago")
        #expect(Format.ago(now - 86_399_500, now: now) == "1d ago")
        #expect(Format.ago(now + 5000, now: now) == "-5s ago")        // a clock running ahead is shown as is

        #expect(Format.hours(0) == "0.0 h")
        #expect(Format.hours(93) == "1.6 h")
        #expect(Format.hours(599.9) == "10.0 h")
        #expect(Format.hours(600) == "10 h")
        #expect(Format.hours(630) == "11 h")
    }

    @Test func hardwareNames() {
        #expect(Format.shortCpu("Intel(R) Core(TM) i7-9700K CPU @ 3.60GHz") == "Intel Core i7-9700K")
        #expect(Format.shortCpu("AMD Ryzen 9 7950X 16-Core Processor") == "AMD Ryzen 9 7950X 16-Core")
        #expect(Format.shortCpu("Apple M3 Pro") == "Apple M3 Pro")
        #expect(Format.shortCpu("cpu processor (r)(tm) PROCESSOR Cpu (Tm) (r)") == dash)
        #expect(Format.shortCpu("Foo @ bar @ baz") == "Foo")
        #expect(Format.shortCpu("line1\n@line2") == "line1")
        #expect(Format.shortCpu("a@b\nc") == "a@b c")           // `.` stops at a line break, `$` is the very end
        #expect(Format.shortCpu(nil) == dash && Format.shortCpu("") == dash && Format.shortCpu("   ") == dash)

        #expect(Format.shortGpu("NVIDIA GeForce RTX 4090") == "GeForce RTX 4090")
        #expect(Format.shortGpu("NVIDIA RTX PRO 6000 Blackwell Workstation Edition") == "RTX PRO 6000 Blackwell")
        #expect(Format.shortGpu("nvidia  geforce gtx 1080") == "geforce gtx 1080")
        #expect(Format.shortGpu("NVIDIA") == "NVIDIA")           // needs white space after it
        #expect(Format.shortGpu(" NVIDIA x") == "NVIDIA x")      // only at the very start
        #expect(Format.shortGpu("workstation edition WORKSTATION EDITION") == "WORKSTATION EDITION")   // first match only
        #expect(Format.shortGpu("AMD Radeon RX 6600") == "AMD Radeon RX 6600")
        #expect(Format.shortGpu(nil) == dash && Format.shortGpu("NVIDIA ") == dash)
    }

    @Test func powerAndEnergy() {
        #expect(Format.fmtW(nil) == dash)
        #expect(Format.fmtW(0) == "0 W")
        #expect(Format.fmtW(999.4) == "999 W")
        #expect(Format.fmtW(999.5) == "1000 W")
        #expect(Format.fmtW(1000) == "1.00 kW")
        #expect(Format.fmtW(1005) == "1.00 kW")

        #expect(Format.fmtKwh(nil, locale: enUS) == "\(dash) kWh")
        #expect(Format.fmtKwh(0, locale: enUS) == "0.00 kWh")
        #expect(Format.fmtKwh(9.995, locale: enUS) == "9.99 kWh")
        #expect(Format.fmtKwh(99.94, locale: enUS) == "99.9 kWh")
        #expect(Format.fmtKwh(99.95, locale: enUS) == "100.0 kWh")
        #expect(Format.fmtKwh(100, locale: enUS) == "100 kWh")
        #expect(Format.fmtKwh(1234.5, locale: enUS) == "1,235 kWh")
    }

    @Test func money() {
        #expect(Format.money(nil, "USD", locale: enUS) == dash)
        #expect(Format.money(.nan, "USD", locale: enUS) == dash)
        #expect(Format.money(0, "USD", locale: enUS) == "$0.00")
        #expect(Format.money(1.005, "USD", locale: enUS) == "$1.01")    // Intl rounds the decimal digits; toFixed would say 1.00
        #expect(Format.money(99.995, "USD", locale: enUS) == "$100.00")
        #expect(Format.money(100, "USD", locale: enUS) == "$100")       // no decimals from 100 up
        #expect(Format.money(100.5, "USD", locale: enUS) == "$101")
        #expect(Format.money(-1234.56, "USD", locale: enUS) == "-$1,235")
        #expect(Format.money(-0.001, "USD", locale: enUS) == "-$0.00")
        #expect(Format.money(12.345, "EUR", locale: enUS) == "\u{20AC}12.35")
        #expect(Format.money(12.345, "GBP", locale: enUS) == "\u{A3}12.35")
        #expect(Format.money(12.345, "JPY", locale: enUS) == "\u{A5}12.35")   // two decimals even for yen: the dashboard asks for them
        #expect(Format.money(12.345, "JPY", 0, locale: enUS) == "\u{A5}12")
        #expect(Format.money(12.345, "CAD", locale: enUS) == "CA$12.35")
        #expect(Format.money(12.345, "usd", locale: enUS) == "$12.35")
        // Not a currency code at all: the dashboard's fallback, which rounds like toFixed.
        #expect(Format.money(1.005, "US", locale: enUS) == "1.00 US")
        #expect(Format.money(1234.5, "DOLLARS", locale: enUS) == "1235 DOLLARS")

        #expect(Format.fmtKwhPrice(0.316, "USD", locale: enUS) == "$0.316")    // three decimals below 1
        #expect(Format.fmtKwhPrice(0.9995, "USD", locale: enUS) == "$1.000")
        #expect(Format.fmtKwhPrice(1.005, "USD", locale: enUS) == "$1.01")
        #expect(Format.fmtKwhPrice(31, "JPY", locale: enUS) == "\u{A5}31.00")
        #expect(Format.fmtKwhPrice(nil, "USD", locale: enUS) == dash)
    }

    @Test func hoursOfTheDay() {
        #expect(Format.fmtHour(0) == "12 am")
        #expect(Format.fmtHour(1) == "1 am")
        #expect(Format.fmtHour(11) == "11 am")
        #expect(Format.fmtHour(12) == "noon")
        #expect(Format.fmtHour(13) == "1 pm")
        #expect(Format.fmtHour(16) == "4 pm")
        #expect(Format.fmtHour(23) == "11 pm")
        #expect(Format.fmtHour(24) == "midnight")
        // The dashboard's editor offers whole hours only; this is what its code prints for a half.
        #expect(Format.fmtHour(6.5) == "6.5:30 am")
    }

    @Test func chartHelpers() {
        #expect(Format.niceMax(0) == 1 && Format.niceMax(-1) == 1 && Format.niceMax(.nan) == 1)
        #expect(Format.niceMax(1) == 1)
        #expect(Format.niceMax(1.1) == 2)
        #expect(Format.niceMax(2.5) == 2.5)
        #expect(Format.niceMax(2.51) == 5)
        #expect(Format.niceMax(5.01) == 10)
        #expect(Format.niceMax(110) == 200)
        #expect(Format.niceMax(1234) == 2000)
        #expect(Format.niceMax(0.0011) == 0.002)

        #expect(Format.historyResolutionSuffix(2000) == "")
        #expect(Format.historyResolutionSuffix(2500) == "")
        #expect(Format.historyResolutionSuffix(60_000) == " \u{B7} 1 min avg")
        #expect(Format.historyResolutionSuffix(300_000) == " \u{B7} 5 min avg")
        #expect(Format.historyResolutionSuffix(3_599_999) == " \u{B7} 60 min avg")
        #expect(Format.historyResolutionSuffix(3_600_000) == " \u{B7} 1 h avg")
        #expect(Format.historyResolutionSuffix(21_600_000) == " \u{B7} 6 h avg")
    }

    @Test func times() {
        let t = 1_795_213_064_123.0   // Friday 20 November 2026, 2:17:44 pm in Los Angeles
        let fold = FormatVectors.foldSpaces
        #expect(fold(Format.clock(t, locale: enUS, timeZone: losAngeles)) == "2:17 PM")
        #expect(fold(Format.clock(1_795_161_909_000, locale: enUS, timeZone: losAngeles)) == "12:05 AM")
        #expect(Format.clock(.nan, locale: enUS, timeZone: losAngeles) == "Invalid Date")
        #expect(Format.clock(8.64e15 + 1, locale: enUS, timeZone: losAngeles) == "Invalid Date")

        #expect(fold(Format.timeLabel(t, 36 * 3600e3, locale: enUS, timeZone: losAngeles)) == "2:17 PM")
        #expect(fold(Format.timeLabel(t, 36 * 3600e3 + 1, locale: enUS, timeZone: losAngeles)) == "Fri, Nov 20 2:17 PM")
        #expect(fold(Format.timeLabel(t, 8 * 86400e3, locale: enUS, timeZone: losAngeles)) == "Fri, Nov 20 2:17 PM")
        #expect(Format.timeLabel(t, 8 * 86400e3 + 1, locale: enUS, timeZone: losAngeles) == "Fri, Nov 20")
        #expect(Format.timeLabel(t, 30 * 86400e3, locale: enUS, timeZone: TimeZone(identifier: "Asia/Kolkata")!) == "Sat, Nov 21")

        #expect(fold(Format.historyTooltipTime(t, resolution: 2000, locale: enUS, timeZone: losAngeles)) == "Fri 2:17:44 PM")
        #expect(fold(Format.historyTooltipTime(t, resolution: 2501, locale: enUS, timeZone: losAngeles)) == "Fri 2:17 PM")

        #expect(Format.cardTooltipTime(t - 4499, live: true, now: t) == "now")
        #expect(Format.cardTooltipTime(t - 4500, live: true, now: t) == "5s ago")
        #expect(Format.cardTooltipTime(t - 59_499, live: true, now: t) == "59s ago")
        #expect(Format.cardTooltipTime(t - 59_500, live: true, now: t) == "1m 0s ago")
        #expect(Format.cardTooltipTime(t - 125_000, live: true, now: t) == "2m 5s ago")
        #expect(fold(Format.cardTooltipTime(t - 3_600_000, live: false, now: t, locale: enUS, timeZone: losAngeles)) == "1:17 PM")
    }

    @Test func defaultsAreTheDevicesOwn() {
        // Locale, time zone and "now" are injectable but default to the current ones.
        let fiveSecondsAgo = Date().addingTimeInterval(-5).hubTime
        #expect(["5s ago", "6s ago"].contains(Format.ago(fiveSecondsAgo)))
        #expect(Format.cardTooltipTime(Date().hubTime, live: true) == "now")
        #expect(Format.clock(0) == Format.clock(0, locale: .current, timeZone: .current))
        #expect(Format.fmtKwh(1234.5) == Format.fmtKwh(1234.5, locale: .current))
        #expect(Format.money(5, "USD") == Format.money(5, "USD", nil, locale: .current))
        #expect(Format.dash == "\u{2013}")
    }
}
