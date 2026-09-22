// cove-reminders: macOS Reminders (EventKit) for the Cove's reminders widget.
//
//   cove-reminders fetch --start YYYY-MM-DD --end YYYY-MM-DD [--reminders-only]
//   cove-reminders done|undone|delete mac/<list>/<item>
//   cove-reminders add mac/<list> <title>
//
// Prints JSON in cove_calendar.py's shape. Ids are "mac/<calendarIdentifier>/
// <calendarItemIdentifier>". It re-launches itself disclaimed, so macOS asks
// for Reminders access on behalf of this helper (whose embedded Info.plist
// carries the usage string) rather than whatever app started it.
import EventKit
import Foundation

@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

func disclaimAndReexec() -> Never? {
    if ProcessInfo.processInfo.environment["COVE_REMINDERS_DISCLAIMED"] != nil { return nil }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    _ = responsibility_spawnattrs_setdisclaim(&attr, 1)
    let args = CommandLine.arguments
    var env = ProcessInfo.processInfo.environment
    env["COVE_REMINDERS_DISCLAIMED"] = "1"
    let cargs = args.map { strdup($0) } + [nil]
    let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var pid: pid_t = 0
    let exe = Bundle.main.executablePath ?? args[0]
    let rc = posix_spawn(&pid, exe, nil, &attr, cargs, cenv)
    if rc != 0 { return nil }   // fall back to running in-process
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    exit((status >> 8) & 0xff)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func emit(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func hex(_ c: CGColor?) -> String {
    guard let c = c, let rgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
          let comps = rgb.components, comps.count >= 3 else { return "" }
    return String(format: "#%02x%02x%02x", Int(comps[0] * 255), Int(comps[1] * 255), Int(comps[2] * 255))
}

let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
let isoFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

_ = disclaimAndReexec()

let store = EKEventStore()
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("usage: cove-reminders fetch|done|undone|delete|add ...") }

func access(_ type: EKEntityType) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    let done: (Bool, Error?) -> Void = { granted, _ in ok = granted; sem.signal() }
    if #available(macOS 14.0, *) {
        if type == .reminder { store.requestFullAccessToReminders(completion: done) }
        else { store.requestFullAccessToEvents(completion: done) }
    } else {
        store.requestAccess(to: type, completion: done)
    }
    sem.wait()
    return ok
}

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func findReminder(_ id: String) -> EKReminder {
    let parts = id.split(separator: "/", maxSplits: 2).map(String.init)
    guard parts.count == 3, let item = store.calendarItem(withIdentifier: parts[2]) as? EKReminder else {
        fail("reminder not found: \(id)")
    }
    return item
}

guard access(.reminder) else { fail("Reminders access denied (System Settings › Privacy & Security › Reminders)") }

switch cmd {
case "fetch":
    var cals: [[String: Any]] = []
    var tasks: [[String: Any]] = []
    var events: [[String: Any]] = []
    let lists = store.calendars(for: .reminder)
    for c in lists {
        cals.append(["id": "mac/\(c.calendarIdentifier)", "name": c.title, "color": hex(c.cgColor),
                     "events": false, "tasks": true])
    }
    let sem = DispatchSemaphore(value: 0)
    // Open ones plus anything finished in the last two weeks (so "show done" has something).
    let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
    var found: [EKReminder] = []
    store.fetchReminders(matching: open) { r in found += r ?? []; sem.signal() }
    sem.wait()
    let recent = store.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-14 * 86400),
                                                      ending: Date(), calendars: lists)
    store.fetchReminders(matching: recent) { r in found += r ?? []; sem.signal() }
    sem.wait()
    for r in found {
        var due = ""
        var allday = false
        if let dc = r.dueDateComponents, let d = Calendar.current.date(from: dc) {
            allday = dc.hour == nil
            due = allday ? dayFmt.string(from: d) : isoFmt.string(from: d)
        }
        tasks.append(["id": "mac/\(r.calendar.calendarIdentifier)/\(r.calendarItemIdentifier)",
                      "uid": r.calendarItemIdentifier, "cal": "mac/\(r.calendar.calendarIdentifier)",
                      "title": r.title ?? "", "due": due, "allday": allday, "done": r.isCompleted,
                      "priority": r.priority, "notes": r.notes ?? "",
                      "ext": r.calendarItemExternalIdentifier ?? ""])
    }
    if !args.contains("--reminders-only"), access(.event),
       let s = opt("--start").flatMap(dayFmt.date(from:)), let e = opt("--end").flatMap(dayFmt.date(from:)) {
        let ecals = store.calendars(for: .event)
        for c in ecals {
            cals.append(["id": "mac/\(c.calendarIdentifier)", "name": c.title, "color": hex(c.cgColor),
                         "events": true, "tasks": false])
        }
        for ev in store.events(matching: store.predicateForEvents(withStart: s, end: e, calendars: ecals)) {
            events.append(["id": "mac/\(ev.calendar.calendarIdentifier)/\(ev.calendarItemIdentifier)/\(isoFmt.string(from: ev.startDate))",
                           "uid": ev.calendarItemIdentifier, "cal": "mac/\(ev.calendar.calendarIdentifier)",
                           "title": ev.title ?? "", "allday": ev.isAllDay,
                           "start": ev.isAllDay ? dayFmt.string(from: ev.startDate) : isoFmt.string(from: ev.startDate),
                           "end": ev.isAllDay ? dayFmt.string(from: ev.endDate.addingTimeInterval(1)) : isoFmt.string(from: ev.endDate),
                           "location": ev.location ?? "", "recurring": ev.hasRecurrenceRules,
                           "ext": ev.calendarItemExternalIdentifier ?? ""])
        }
    }
    emit(["calendars": cals, "tasks": tasks, "events": events])
case "done", "undone":
    guard args.count > 1 else { fail("which reminder?") }
    let r = findReminder(args[1])
    r.isCompleted = cmd == "done"
    do { try store.save(r, commit: true) } catch { fail("save failed: \(error.localizedDescription)") }
    emit(["ok": true])
case "delete":
    guard args.count > 1 else { fail("which reminder?") }
    do { try store.remove(findReminder(args[1]), commit: true) } catch { fail("delete failed: \(error.localizedDescription)") }
    emit(["ok": true])
case "add":
    guard args.count > 2 else { fail("usage: add mac/<list> <title>") }
    let listId = args[1].split(separator: "/").dropFirst().first.map(String.init) ?? ""
    guard let cal = store.calendar(withIdentifier: listId) ?? store.defaultCalendarForNewReminders() else { fail("no such list") }
    let r = EKReminder(eventStore: store)
    r.title = args[2]
    r.calendar = cal
    do { try store.save(r, commit: true) } catch { fail("add failed: \(error.localizedDescription)") }
    emit(["ok": true, "uid": r.calendarItemIdentifier])
default:
    fail("unknown command \(cmd)")
}
