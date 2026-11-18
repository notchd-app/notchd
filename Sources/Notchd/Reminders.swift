import EventKit
import SwiftUI

/// The to-do widget can mirror one Reminders list instead of keeping its own: tasks then sync to your iPhone.
@Observable
final class RemindersStore {
    static let shared = RemindersStore()
    private let store = EKEventStore()
    private(set) var lists: [EKCalendar] = []
    private(set) var reminders: [EKReminder] = []
    private(set) var denied = false
    private(set) var authorized = false
    private var requested = false

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reloadSoon()
        }
    }

    private var reloadWork: DispatchWorkItem?

    /// Changes arrive in bursts (and our own saves announce themselves too): reload once they settle.
    private func reloadSoon() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Asks for Reminders access the first time it's needed.
    func requestAccess() {
        guard !requested else { return reload() }
        requested = true
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
                self?.denied = !granted
                self?.reload()
            }
        }
    }

    private var list: EKCalendar? {
        Settings.shared.prefs.todoRemindersList.flatMap { store.calendar(withIdentifier: $0) }
    }

    func reload() {
        guard authorized else { return }
        lists = store.calendars(for: .reminder).sorted { $0.title < $1.title }
        guard let list else {
            reminders = []
            return
        }
        let prefs = Settings.shared.prefs
        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        store.fetchReminders(matching: open) { [weak self] incomplete in
            guard let self else { return }
            let keepDays = prefs.todoClearAfterDays > 0 ? prefs.todoClearAfterDays : 30
            let since = Date().addingTimeInterval(-keepDays * 86_400)
            let done = store.predicateForCompletedReminders(withCompletionDateStarting: since, ending: nil, calendars: [list])
            store.fetchReminders(matching: done) { completed in
                let all = (incomplete ?? []) + (prefs.todoShowCompleted ? completed ?? [] : [])
                // Sorted on the main thread: reading reminders here could race with edits made there.
                DispatchQueue.main.async {
                    var seen = Set<String>()
                    self.reminders = Self.sorted(all.filter { seen.insert($0.calendarItemIdentifier).inserted })
                }
            }
        }
    }

    /// Flagged (high priority) first, then due date, then newest.
    static func sorted(_ reminders: [EKReminder]) -> [EKReminder] {
        reminders.sorted { a, b in
            if a.isCompleted != b.isCompleted { return !a.isCompleted }
            if isStarred(a) != isStarred(b) { return isStarred(a) }
            let da = a.dueDateComponents?.date ?? .distantFuture, db = b.dueDateComponents?.date ?? .distantFuture
            if da != db { return da < db }
            return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
        }
    }

    /// High priority (1–4) reads as a star in the widget.
    static func isStarred(_ reminder: EKReminder) -> Bool { (1...4).contains(reminder.priority) }

    func add(_ title: String) {
        guard let list else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        save(reminder)
    }

    func toggleDone(_ reminder: EKReminder) {
        reminder.isCompleted.toggle()
        save(reminder)
    }

    func toggleStar(_ reminder: EKReminder) {
        reminder.priority = Self.isStarred(reminder) ? 0 : 1
        save(reminder)
    }

    func delete(_ reminder: EKReminder) {
        do { try store.remove(reminder, commit: true) } catch { NSLog("[Reminders] delete: \(error)") }
        reload()
    }

    private func save(_ reminder: EKReminder) {
        do { try store.save(reminder, commit: true) } catch { NSLog("[Reminders] save: \(error)") }
        reload()
    }
}
