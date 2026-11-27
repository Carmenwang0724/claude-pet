import AppKit

/// Holds everything the pet may say on her own, grouped by when it fits.
enum PetLines {
    static let affection = [
        "I missed you.",
        "I'm glad you're here.",
        "Just checking on you.",
        "You're my favorite human.",
        "I like it when you're around.",
        "Hi. That's all. Just hi.",
        "I saved you a spot on the desktop.",
        "Don't forget to drink some water.",
        "Have you eaten yet?",
        "Your posture. Just saying.",
    ]

    static let encouragement = [
        "You're doing great.",
        "One step at a time.",
        "You've figured out harder things than this.",
        "Small progress is still progress.",
        "I believe in you.",
        "Proud of you, by the way.",
        "Breathe. You've got this.",
        "It doesn't have to be perfect yet.",
        "Being stuck means you're learning.",
        "Keep going. I'm right here.",
        "You're smarter than this bug.",
        "Future you will thank you for this.",
    ]

    static let morning = [
        "Good morning! Let's make today a good one.",
        "Morning. Did you have breakfast?",
        "A fresh day. Let's go.",
    ]

    static let afternoon = [
        "Afternoon slump? Have a snack.",
        "Halfway through the day. Nice work so far.",
        "Maybe some fresh air soon?",
    ]

    static let evening = [
        "Good evening. You worked hard today.",
        "Evening already? You did a lot.",
        "Don't forget to rest tonight.",
    ]

    static let lateNight = [
        "Still up? Don't stay too late.",
        "The stars are out. So am I.",
        "Just a little more, then sleep. Promise?",
    ]

    static let welcomeBack = [
        "I missed you!",
        "You're back!",
        "There you are!",
        "Welcome back. I kept your desktop safe.",
        "Yay, you're here.",
    ]

    static let turnFinished = [
        "Claude's done. Nice teamwork!",
        "Done! Go take a look.",
        "Another one finished.",
        "That went well, I think.",
    ]

    static let turnFailed = [
        "Oops. Errors happen.",
        "It broke, but you can fix it.",
        "Don't worry. Try again.",
        "Bugs are just puzzles.",
    ]

    static let petting = [
        "Hehe",
        "That tickles!",
        "More, please.",
        "Hehe, thank you.",
    ]

    /// Gives the lines that suit the hour of the day, or nil when no hour fits.
    static func forHour(_ hour: Int) -> [String]? {
        switch hour {
        case 0..<5:
            return lateNight
        case 5..<11:
            return morning
        case 12..<16:
            return afternoon
        case 18..<24:
            return evening
        default:
            return nil
        }
    }
}

/// Lets the pet say something kind now and then, and when Claude or the user does something.
extension PetController {
    /// Says a random line every so often while the user is at the computer.
    func chatIfDue(idleTime: TimeInterval, now: TimeInterval) {
        guard isChatterEnabled, now >= nextChatTime else {
            return
        }

        // Wait for a quiet moment with the user around
        let isQuiet = bubbleText == nil && !holdsStage && errand == nil && motion.isAwakeOnLedge
        guard isQuiet, idleTime < PetConfig.chatterIdleLimit else {
            return
        }
        nextChatTime = now + randomChatGap()

        // Prefer a line for the time of day half of the time
        let hour = Calendar.current.component(.hour, from: Date())
        var pool = PetLines.affection + PetLines.encouragement
        if let hourLines = PetLines.forHour(hour), Double.random(in: 0..<1) < PetConfig.hourLineChance {
            pool = hourLines
        }
        say(from: pool, duration: PetConfig.chatterDuration, now: now)
        playOnce("waving")
    }

    /// Says a line now and then when a Claude turn ends.
    func chatAfterTurn(failed: Bool) {
        let chance = failed ? PetConfig.turnFailedLineChance : PetConfig.turnFinishedLineChance
        guard isChatterEnabled, bubbleText == nil, Double.random(in: 0..<1) < chance else {
            return
        }
        let pool = failed ? PetLines.turnFailed : PetLines.turnFinished
        say(from: pool, duration: PetConfig.reactionLineDuration, now: CACurrentMediaTime())
    }

    /// Shows one line from a pool, avoiding the lines said most recently.
    func say(from pool: [String], duration: TimeInterval, now: TimeInterval) {
        // Leave out recent lines while enough others remain
        let freshLines = pool.filter { !recentChatLines.contains($0) }
        let choices = freshLines.isEmpty ? pool : freshLines
        guard let line = choices.randomElement() else {
            return
        }

        // Remember the line and show it
        recentChatLines.append(line)
        if recentChatLines.count > PetConfig.recentLineMemory {
            recentChatLines.removeFirst()
        }
        lastChatLine = line
        showTransientBubble(line, duration: duration, now: now)
    }

    /// Picks the wait until the next unprompted line.
    func randomChatGap() -> TimeInterval {
        return TimeInterval.random(in: PetConfig.chatterMinimumGap...PetConfig.chatterMaximumGap)
    }
}
