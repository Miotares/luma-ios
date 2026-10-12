import Foundation
import Observation

/// Decides WHEN to ask the user for an App Store rating, and remembers that we asked.
///
/// We never *force* the prompt: `requestReview` / `SKStoreReviewController` is throttled by Apple
/// to at most 3 prompts per user per 365 days, and Apple alone decides whether the dialog actually
/// appears. Our only job is to pick a *good* moment so the (rare) prompt lands on an engaged, happy
/// user — for a music app that means after they've set up their library and genuinely listened.
///
/// Eligibility is therefore gated on three things:
///   1. **Qualified sessions** — app runs in which music actually played (not bare launches).
///   2. A **minimum age** since first launch, so a power user who opens the app many times on day
///      one isn't hit immediately.
///   3. Our own long **cooldown** after we've asked, so the logic never re-arms too soon.
///
/// The manager only flips `shouldRequestReview`; the SwiftUI layer observes that and fires the
/// official `requestReview` environment action (see `ReviewPromptPresenter` in `LumaApp`).
@Observable
final class ReviewPromptManager {

    // MARK: - Tuning (change these to make the prompt earlier / later)

    /// Ask after this many *qualified* sessions (a session in which a track was actually played).
    /// 10–15 is the sweet spot for a music app: late enough that the user has set up their library
    /// and formed a positive opinion, early enough that we don't miss committed users.
    static let qualifiedSessionThreshold = 12

    /// Never ask before the app is at least this old (days since first launch).
    static let minimumDaysSinceFirstLaunch = 3

    /// Once we've asked, don't re-arm our own logic for this long (days). Apple already caps the
    /// real dialog at 3/year; this just keeps us from re-triggering on every later session.
    static let reRequestCooldownDays = 120

    // MARK: - State

    /// Set to `true` once every condition is met. The UI observes this, presents the prompt, and
    /// calls `markReviewRequested()`. Kept as observable state (rather than calling StoreKit here)
    /// so the actual request happens via SwiftUI's official `requestReview` action.
    private(set) var shouldRequestReview = false

    /// Guards against counting more than one qualified session per foreground run.
    private var sessionCountedThisRun = false

    private let defaults: UserDefaults

    private enum Key {
        static let firstLaunch = "review.firstLaunchDate"
        static let qualifiedSessions = "review.qualifiedSessionCount"
        static let lastPrompt = "review.lastPromptDate"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Stamp the install date the very first time we run, so the age gate has a baseline.
        if defaults.object(forKey: Key.firstLaunch) == nil {
            defaults.set(Date.now.timeIntervalSince1970, forKey: Key.firstLaunch)
        }
    }

    // MARK: - Lifecycle hooks (called from AppContainer)

    /// Call when the app (re)enters the foreground — re-arms session counting so the next bout of
    /// playback is recorded as a fresh qualified session.
    func startNewForegroundSession() {
        sessionCountedThisRun = false
    }

    /// Call whenever the user genuinely plays a track. Counts at most one qualified session per
    /// foreground run, then re-evaluates whether it's time to ask for a review.
    func registerPlaybackActivity() {
        guard !sessionCountedThisRun else { return }
        sessionCountedThisRun = true
        qualifiedSessionCount += 1
        evaluate()
    }

    /// The UI has presented (or at least attempted) the review prompt — record the time and disarm
    /// so the cooldown starts. We record the *attempt*: Apple may silently suppress the dialog, but
    /// our own cooldown is what stops us from re-evaluating on every later session.
    func markReviewRequested() {
        defaults.set(Date.now.timeIntervalSince1970, forKey: Key.lastPrompt)
        shouldRequestReview = false
    }

    // MARK: - Eligibility

    private func evaluate() {
        guard !shouldRequestReview, isEligible else { return }
        shouldRequestReview = true
    }

    private var isEligible: Bool {
        guard qualifiedSessionCount >= Self.qualifiedSessionThreshold else { return false }
        guard let first = firstLaunchDate,
              Date.now.timeIntervalSince(first) >= Double(Self.minimumDaysSinceFirstLaunch) * 86_400
        else { return false }
        if let last = lastPromptDate,
           Date.now.timeIntervalSince(last) < Double(Self.reRequestCooldownDays) * 86_400 {
            return false
        }
        return true
    }

    // MARK: - Persisted counters

    private var qualifiedSessionCount: Int {
        get { defaults.integer(forKey: Key.qualifiedSessions) }
        set { defaults.set(newValue, forKey: Key.qualifiedSessions) }
    }

    private var firstLaunchDate: Date? {
        let t = defaults.double(forKey: Key.firstLaunch)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private var lastPromptDate: Date? {
        let t = defaults.double(forKey: Key.lastPrompt)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}
