import Foundation

/// The persisted disposition of a user's first-use onboarding experience.
///
/// Only In Progress, Deferred, or Completed disposition is persisted.
/// The specific next useful step is derived from current domain state rather than a stored page number.
public enum OnboardingDisposition: String, Codable, Sendable, Equatable {
    case inProgress = "in_progress"
    case deferred = "deferred"
    case completed = "completed"
}

/// The progressive sequence of steps in first-use onboarding.
///
/// Steps are derived dynamically from current domain state rather than persisted as a page number.
public enum OnboardingStep: String, Sendable, Equatable, CaseIterable {
    case contract
    case desiredTheme
    case targetOptIns
    case setupPlanReview
    case setupTransaction
    case setupResults
    case initialApply
    case overview
}
