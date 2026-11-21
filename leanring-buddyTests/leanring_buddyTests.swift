//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @MainActor @Test func reminderDateParsingAcceptsTheModelFormat() async throws {
        let parsedDate = MacCalendarReminders.parseWhenText("2026-05-01 17:00")
        #expect(parsedDate != nil)
        if let parsedDate {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: parsedDate)
            #expect(components.year == 2026)
            #expect(components.month == 5)
            #expect(components.day == 1)
            #expect(components.hour == 17)
            #expect(components.minute == 0)
        }
    }

    @MainActor @Test func reminderDateParsingAcceptsISOAndDateOnly() async throws {
        #expect(MacCalendarReminders.parseWhenText("2026-05-01T17:30") != nil)
        let dateOnly = MacCalendarReminders.parseWhenText("2026-05-01")
        #expect(dateOnly != nil)
        if let dateOnly {
            let components = Calendar.current.dateComponents([.hour], from: dateOnly)
            #expect(components.hour == 9)
        }
    }

    @MainActor @Test func reminderDateParsingRejectsNonsense() async throws {
        #expect(MacCalendarReminders.parseWhenText("soon-ish") == nil)
        #expect(MacCalendarReminders.parseWhenText("") == nil)
    }

}
