//
//  SleepTimerIntentTests.swift
//  Lutheran RadioTests
//
//  SetSleepTimerIntent and CancelSleepTimerIntent call the actor sleep-timer
//  methods. The four presets match SleepTimerPreset (the in-app menu). Cancel
//  with no armed countdown returns no dialog and does not throw. A second set
//  replaces the armed length. The schedule notification is what the in-app
//  moon observes.
//
//  The manual delay keeps a 15–60 minute countdown from sleeping on the wall
//  clock. Tear-down cancels the task before restoring that clock.
//
//  - SeeAlso: ``SetSleepTimerIntent``, ``CancelSleepTimerIntent``,
//    ``SleepTimerPreset``, ``SleepTimerNotification/countdownSeed(isActive:announcedRemaining:cachedRemaining:)``,
//    ``SharedPlayerManager/setSleepTimer(duration:)``,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//
//  Created by Jari Lammi on 10.11.2026.
//

import XCTest
import zlib
@testable import Lutheran_Radio

final class SleepTimerIntentTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    override func setUp() async throws {
        try await super.setUp()
        await prepareSharedPlayerManagerEventTestIsolation(manager: manager)
        await manager._test_resetSleepTimerTiming()
        // Off skips the ramp. The delay below never reaches the deadline during a test.
        await manager._test_setSleepTimerFadeDuration(SleepTimerFadePolicy.offDuration)
        await manager._test_setSleepTimerDelay { _ in
            try await Task.sleep(for: .seconds(86_400))
        }
    }

    override func tearDown() async throws {
        await manager.cancelSleepTimer(restorePlaybackIntent: false, notifyStateChange: false)
        await manager._test_resetSleepTimerTiming()
        await tearDownSharedPlayerManagerEventTestIsolation(manager: manager)
        try await super.tearDown()
    }

    func testEachPresetArmsThatManyMinutes() async throws {
        for preset in SleepTimerPresetAppEnum.allCases {
            let intent = SetSleepTimerIntent(duration: preset)
            _ = try await intent.perform()
            let remaining = await manager.sleepTimerRemainingSeconds
            XCTAssertEqual(
                remaining,
                preset.minutes * 60,
                "\(preset) should arm \(preset.minutes) minutes"
            )
            XCTAssertEqual(preset.minutes, preset.preset.rawValue)
            let armed = await manager.isSleepTimerArmed
            XCTAssertTrue(armed)
        }
    }

    func testAppEnumCasesMatchInAppPickerPresets() {
        XCTAssertEqual(SleepTimerPreset.pickerMinutes, [15, 30, 45, 60])
        XCTAssertEqual(SleepTimerPreset.allCases.count, 4)
        XCTAssertEqual(SleepTimerPresetAppEnum.allCases.count, 4)
        XCTAssertEqual(
            Set(SleepTimerPresetAppEnum.allCases.map(\.preset)),
            Set(SleepTimerPreset.allCases)
        )
        XCTAssertEqual(
            SleepTimerPresetAppEnum.allCases.map(\.minutes).sorted(),
            SleepTimerPreset.pickerMinutes.sorted()
        )
        for preset in SleepTimerPresetAppEnum.allCases {
            XCTAssertEqual(Int(preset.rawValue), preset.minutes)
            let shown = SleepTimerPresetAppEnum.caseDisplayRepresentations[preset]?.title
            XCTAssertEqual(
                shown,
                preset.preset.menuTitleResource,
                "Shortcuts label drifted from the in-app preset title"
            )
            XCTAssertFalse(preset.preset.menuTitle.isEmpty)
        }
        XCTAssertEqual(SetSleepTimerIntent().duration, .thirtyMinutes)
        XCTAssertEqual(SleepTimerPreset.thirty.rawValue, 30)
    }

    func testIntentsRunInTheBackground() {
        XCTAssertFalse(SetSleepTimerIntent.openAppWhenRun)
        XCTAssertFalse(CancelSleepTimerIntent.openAppWhenRun)
        XCTAssertTrue(SetSleepTimerIntent.supportedModes.contains(.background))
        XCTAssertTrue(CancelSleepTimerIntent.supportedModes.contains(.background))
    }

    /// Stopped playback still arms a timer and does not rewrite a user pause.
    ///
    /// ``setSleepTimer(duration:)`` moves `playbackIntent` to `.sleepTimer` only
    /// when the visual is `.playing` or the intent is already active. `.userPaused`
    /// stays `.userPaused`.
    func testSetIntentArmsTimerWhileUserPaused() async throws {
        await manager.updatePlaybackIntent(to: .userPaused)
        let visual = await manager.currentVisualState
        XCTAssertNotEqual(visual, .playing)

        let intent = SetSleepTimerIntent(duration: .fifteenMinutes)
        _ = try await intent.perform()

        let remaining = await manager.sleepTimerRemainingSeconds
        XCTAssertEqual(remaining, 15 * 60)
        let playback = await manager.currentPlaybackIntent
        XCTAssertEqual(playback, .userPaused)
    }

    func testSetIntentPostsCountdownForTheInAppMoon() async throws {
        let posted = expectation(
            forNotification: SleepTimerNotification.stateDidChange,
            object: nil
        ) { notification in
            let active = notification.userInfo?[SleepTimerNotification.Key.isActive] as? Bool
            let remaining = notification.userInfo?[SleepTimerNotification.Key.remainingSeconds] as? Int
            return active == true && remaining == 30 * 60
        }

        _ = try await SetSleepTimerIntent(duration: .thirtyMinutes).perform()
        await fulfillment(of: [posted], timeout: 2)
    }

    func testSettingANewTimerReplacesTheArmedOne() async throws {
        _ = try await SetSleepTimerIntent(duration: .fifteenMinutes).perform()
        let firstRemaining = await manager.sleepTimerRemainingSeconds
        XCTAssertEqual(firstRemaining, 15 * 60)

        _ = try await SetSleepTimerIntent(duration: .sixtyMinutes).perform()
        let replacedRemaining = await manager.sleepTimerRemainingSeconds
        XCTAssertEqual(replacedRemaining, 60 * 60)
        let stillArmed = await manager.isSleepTimerArmed
        XCTAssertTrue(stillArmed)
        XCTAssertEqual(
            SleepTimerNotification.countdownSeed(
                isActive: true,
                announcedRemaining: 60 * 60,
                cachedRemaining: 15 * 60
            ),
            60 * 60,
            "A different armed length must restart the in-app countdown"
        )
    }

    func testCancelIntentClearsAnArmedTimer() async throws {
        _ = try await SetSleepTimerIntent(duration: .fortyFiveMinutes).perform()
        let armedBeforeCancel = await manager.isSleepTimerArmed
        XCTAssertTrue(armedBeforeCancel)
        XCTAssertNotNil(SleepTimerCancelDialog.result(isArmed: true).dialog)
        XCTAssertEqual(
            SleepTimerCancelDialog.cancelledResource,
            LocalizedStringResource(
                "sleep_timer_cancel_timer",
                defaultValue: "Cancel timer",
                table: "Localizable"
            )
        )

        let cleared = expectation(
            forNotification: SleepTimerNotification.stateDidChange,
            object: nil
        ) { notification in
            let active = notification.userInfo?[SleepTimerNotification.Key.isActive] as? Bool
            return active == false
        }

        _ = try await CancelSleepTimerIntent().perform()
        await fulfillment(of: [cleared], timeout: 2)
        let armedAfterCancel = await manager.isSleepTimerArmed
        XCTAssertFalse(armedAfterCancel)
        let remainingAfterCancel = await manager.sleepTimerRemainingSeconds
        XCTAssertNil(remainingAfterCancel)
    }

    func testCancelIntentWithNoTimerLeavesTheSessionUnarmed() async throws {
        let armed = await manager.isSleepTimerArmed
        XCTAssertFalse(armed)
        XCTAssertNil(SleepTimerCancelDialog.result(isArmed: false).dialog)

        _ = try await CancelSleepTimerIntent().perform()
        let stillUnarmed = await manager.isSleepTimerArmed
        XCTAssertFalse(stillUnarmed)
        let remaining = await manager.sleepTimerRemainingSeconds
        XCTAssertNil(remaining)
    }

    func testCountdownSeedIgnoresDuplicatesAndInactivePosts() {
        XCTAssertEqual(
            SleepTimerNotification.countdownSeed(
                isActive: true,
                announcedRemaining: 900,
                cachedRemaining: nil
            ),
            900
        )
        XCTAssertNil(
            SleepTimerNotification.countdownSeed(
                isActive: true,
                announcedRemaining: 1800,
                cachedRemaining: 1800
            )
        )
        XCTAssertNil(
            SleepTimerNotification.countdownSeed(
                isActive: false,
                announcedRemaining: 1800,
                cachedRemaining: 900
            )
        )
    }

    /// Titles and dialogs reuse catalog keys that already exist. A new literal
    /// on `LocalizedStringResource` or `IntentDialog` would add a key.
    func testIntentChromeReusesExistingCatalogKeys() {
        let sheetTitle = LocalizedStringResource(
            "sleep_timer_sheet_title",
            defaultValue: "Sleep timer",
            table: "Localizable"
        )
        let cancelTitle = LocalizedStringResource(
            "sleep_timer_cancel_timer",
            defaultValue: "Cancel timer",
            table: "Localizable"
        )
        XCTAssertEqual(SetSleepTimerIntent.title, sheetTitle)
        XCTAssertEqual(CancelSleepTimerIntent.title, cancelTitle)
        XCTAssertEqual(SleepTimerPresetAppEnum.typeDisplayRepresentation.name, sheetTitle)
        XCTAssertEqual(SetSleepTimerIntent().$duration.title, sheetTitle)
        XCTAssertEqual(SleepTimerSetDialog.fullResource, sheetTitle)
        XCTAssertEqual(SleepTimerCancelDialog.cancelledResource, cancelTitle)
        for preset in SleepTimerPresetAppEnum.allCases {
            XCTAssertEqual(
                SleepTimerSetDialog.supportingResource(for: preset),
                preset.preset.menuTitleResource
            )
        }
    }

    /// Working-tree `Localizable.xcstrings` matches HEAD. Sleep-timer intent
    /// chrome must not add, remove, or edit a catalog key.
    func testLocalizableCatalogMatchesHEAD() throws {
        let working = try loadLocalizableCatalog()
        let head = try HeadStringCatalog.strings(
            repoRoot: repoRoot(),
            path: ["Lutheran Radio", "Localizable.xcstrings"]
        )
        let workingStrings = try XCTUnwrap(working["strings"] as? [String: Any])
        let added = Set(workingStrings.keys).subtracting(head.keys).sorted()
        let removed = Set(head.keys).subtracting(workingStrings.keys).sorted()
        XCTAssertTrue(added.isEmpty, "Localizable.xcstrings added keys: \(added)")
        XCTAssertTrue(removed.isEmpty, "Localizable.xcstrings removed keys: \(removed)")
        var edited: [String] = []
        for key in head.keys.sorted() {
            if !jsonObjectsEqual(workingStrings[key], head[key]) {
                edited.append(key)
            }
        }
        XCTAssertTrue(edited.isEmpty, "Localizable.xcstrings edited keys: \(edited)")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadLocalizableCatalog() throws -> [String: Any] {
        let catalogURL = repoRoot().appendingPathComponent("Lutheran Radio/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func jsonObjectsEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs as? NSObject, rhs as? NSObject) {
        case let (left?, right?):
            return left.isEqual(right)
        case (nil, nil):
            return true
        default:
            return false
        }
    }
}

/// Reads one blob from the commit `HEAD` points at.
///
/// The test runs in the iOS simulator, which cannot launch `git`. Loose objects
/// under `.git/objects` are zlib streams, the same bytes `git cat-file` inflates.
/// A missing loose object (packed) fails the test instead of skipping the compare.
private enum HeadStringCatalog {
    static func strings(repoRoot: URL, path: [String]) throws -> [String: Any] {
        let blob = try blob(repoRoot: repoRoot, path: path)
        let object = try JSONSerialization.jsonObject(with: blob)
        let catalog = try XCTUnwrap(object as? [String: Any], "HEAD catalog is not a dictionary")
        return try XCTUnwrap(catalog["strings"] as? [String: Any], "HEAD catalog has no strings")
    }

    private static func blob(repoRoot: URL, path: [String]) throws -> Data {
        let headSHA = try resolveHEAD(repoRoot: repoRoot)
        let commitPayload = try objectPayload(repoRoot: repoRoot, sha: headSHA, expectedType: "commit")
        let commitText = String(decoding: commitPayload, as: UTF8.self)
        guard let treeLine = commitText.split(separator: "\n").first, treeLine.hasPrefix("tree ") else {
            throw failure("HEAD commit has no tree line")
        }
        var sha = String(treeLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        var payload = try objectPayload(repoRoot: repoRoot, sha: sha, expectedType: "tree")
        for (index, name) in path.enumerated() {
            guard let entry = try treeEntries(payload).first(where: { $0.name == name }) else {
                throw failure("HEAD tree is missing \(name)")
            }
            sha = entry.sha
            let isLast = index == path.index(before: path.endIndex)
            payload = try objectPayload(
                repoRoot: repoRoot,
                sha: sha,
                expectedType: isLast ? "blob" : "tree"
            )
        }
        return payload
    }

    private static func resolveHEAD(repoRoot: URL) throws -> String {
        let git = repoRoot.appendingPathComponent(".git")
        var text = try String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref: ") {
            let ref = String(text.dropFirst(5))
            text = try String(contentsOf: git.appendingPathComponent(ref), encoding: .utf8)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.count == 40 else { throw failure("HEAD did not resolve to a commit: \(text)") }
        return text
    }

    private static func objectPayload(repoRoot: URL, sha: String, expectedType: String) throws -> Data {
        let path = repoRoot
            .appendingPathComponent(".git/objects")
            .appendingPathComponent(String(sha.prefix(2)))
            .appendingPathComponent(String(sha.dropFirst(2)))
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw failure("Loose git object \(sha) is missing (packed objects are not read here)")
        }
        let compressed = try Data(contentsOf: path)
        let inflated = try inflateZlib(compressed)
        guard let nul = inflated.firstIndex(of: 0) else { throw failure("Git object \(sha) has no header") }
        let header = String(decoding: inflated[..<nul], as: UTF8.self)
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let size = Int(parts[1]) else {
            throw failure("Git object \(sha) has a bad header")
        }
        let type = String(parts[0])
        guard type == expectedType else {
            throw failure("Git object \(sha) is \(type), expected \(expectedType)")
        }
        let payload = inflated[inflated.index(after: nul)...]
        guard payload.count == size else {
            throw failure("Git object \(sha) size \(payload.count) != \(size)")
        }
        return Data(payload)
    }

    private struct TreeEntry {
        var name: String
        var sha: String
    }

    private static func treeEntries(_ payload: Data) throws -> [TreeEntry] {
        let bytes = [UInt8](payload)
        var offset = 0
        var entries: [TreeEntry] = []
        while offset < bytes.count {
            guard let space = bytes[offset...].firstIndex(of: 0x20) else {
                throw failure("Git tree entry is missing its mode")
            }
            let nameStart = space + 1
            guard let nul = bytes[nameStart...].firstIndex(of: 0) else {
                throw failure("Git tree entry is missing its name")
            }
            guard let name = String(bytes: bytes[nameStart..<nul], encoding: .utf8) else {
                throw failure("Git tree name is not UTF-8")
            }
            let shaStart = nul + 1
            guard shaStart + 20 <= bytes.count else { throw failure("Git tree entry is missing its SHA") }
            // Lowercase hex, matching loose-object filenames. Avoid `String(format:)`,
            // which is an unsafe C call under strict memory safety.
            let hex = [Character]("0123456789abcdef")
            let sha = bytes[shaStart..<(shaStart + 20)].reduce(into: "") { partial, byte in
                partial.append(hex[Int(byte >> 4)])
                partial.append(hex[Int(byte & 0x0F)])
            }
            entries.append(TreeEntry(name: name, sha: sha))
            offset = shaStart + 20
        }
        return entries
    }

    /// Inflates a git loose object (zlib wrapper).
    ///
    /// - Parameter source: The bytes stored under `.git/objects`.
    private static func inflateZlib(_ source: Data) throws -> Data {
        // SAFETY: zlib borrows `source` until inflateEnd. withUnsafeBytes keeps those bytes alive.
        try unsafe source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = unsafe raw.bindMemory(to: UInt8.self).baseAddress else {
                throw failure("Git object is empty")
            }
            var stream = unsafe z_stream()
            let streamSize = unsafe Int32(MemoryLayout<z_stream>.size)
            let initStatus = unsafe inflateInit2_(&stream, 15, ZLIB_VERSION, streamSize)
            guard initStatus == Z_OK else { throw failure("inflateInit2_ failed (\(initStatus))") }
            defer { unsafe inflateEnd(&stream) }
            unsafe stream.next_in = UnsafeMutablePointer(mutating: base)
            unsafe stream.avail_in = uInt(source.count)
            var output = Data()
            let chunk = 16_384
            var status = Z_OK
            while status != Z_STREAM_END {
                var buffer = [UInt8](repeating: 0, count: chunk)
                status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    unsafe stream.next_out = out.baseAddress
                    unsafe stream.avail_out = uInt(chunk)
                    return unsafe inflate(&stream, Z_NO_FLUSH)
                }
                let remainingOut = unsafe stream.avail_out
                let produced = chunk - Int(remainingOut)
                if produced > 0 {
                    unsafe output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK { throw failure("inflate failed (\(status))") }
            }
            return output
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HeadStringCatalog", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
