//
//  SettingsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import GoldLifeUI
import GoldLifeAI
import GoldLifeCloud
import GoldLifeMoney
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

enum AppBranding {
    static let useCompanyLogoKey = "mb.useCompanyLogo"
}

extension View {
    func glAppearance(_ scheme: ColorScheme) -> some View {
        preferredColorScheme(scheme)
    }
}

struct SettingsScreen: View {
    @State private var appearanceStore = AppearanceStore.shared
    @State private var localization = MBLocalization.shared
    @AppStorage(AppLockPrefs.key) private var requireLock = false
    @AppStorage("mb.hideWhenBackgrounded") private var hideWhenBackgrounded = true
    @State private var subscription = SubscriptionManager.shared

    private var settingsCategories: [GLSettingsCategory] {
        var rows: [GLSettingsCategory] = [
            GLSettingsCategory(
                id: "branding_documents",
                title: "Branding & Documents",
                systemImage: "doc.richtext",
                accessibilityIdentifier: "settings_category_branding_documents"
            ) {
                MBBrandingAndDocumentsSettingsScreen()
            },
            GLSettingsCategory(
                id: "scheduling_workdays",
                title: "Scheduling & Workdays",
                systemImage: "calendar.badge.clock",
                accessibilityIdentifier: "settings_category_scheduling_workdays"
            ) {
                MBSchedulingSettingsScreen()
            },
            // Owner ruling 2026-11-15: Money is a settings category of its own.
            MoneySettings.category {
                if subscription.isMoneyEntitled {
                    ConnectedBanksAndMoneyScreen(isSampleMode: DemoMode.isActive || UserDemoMode.shared.isDemoActive)
                        .mbMoneyHostEnvironment()
                } else {
                    MoneyLockedScreen(ownsStack: false)
                }
            }
        ]
        if MBFeatureFlags.assistantEnabled {
            rows.append(
                GLAISettings.category(
                    connectionStore: .shared,
                    soulStore: .shared
                ) {
                    MBAssistantSharingSettingsSection()
                }
            )
        }
        return rows
    }

    var body: some View {
        GLSettingsScreen(
            configuration: GLSettingsConfiguration(
                appearanceSelection: Binding(
                    get: { appearanceStore.pref.rawValue },
                    set: { AppSettingsService.setAppearance(AppearancePref(rawValue: $0) ?? .goldLife) }
                ),
                appearanceValueLabel: appearanceStore.pref.label,
                appearanceInfo: "Gold Life ID Setting follows the appearance saved to your Gold Life ID. Your choice here applies in this app only. System follows your device’s Light or Dark setting.",
                appearanceDestination: { AnyView(AppearanceScreen()) },
                languageSelection: Binding(
                    get: { localization.pref.rawValue },
                    set: { AppSettingsService.setLanguage(MBLanguagePref(rawValue: $0) ?? .goldLife) }
                ),
                languageValueLabel: localization.pref.pickerLabel,
                languageInfo: "Gold Life ID Setting follows the language saved to your Gold Life ID. Your choice here applies in this app only. Money and dates always use your region.",
                languageDestination: { AnyView(LanguageScreen()) },
                showsDefaultApps: true,
                requireBiometricLock: $requireLock,
                hideWhenBackgrounded: $hideWhenBackgrounded,
                securityInfo: "Require Face ID (or your device passcode) to open My Business, and again if you have been away for a minute. Hiding when switching apps covers your records in the app switcher, where your device stores the picture it takes — turn it off if you want to see this app beside another one. Your records are encrypted on this device either way, and your Gold Life backup can only be reached by signing in.",
                topSection: {
                    AnyView(
                        Group {
                            GLSyncPausedSection()
                            Section { GLSyncBackupRow() }
                                .modifier(GLSyncMessageAlert())
                        }
                    )
                },
                categories: settingsCategories,
                bannerInset: { AnyView(MBSystemBannerInset()) },
                isBannerActive: MBSystemBannerInset.isShowing
            )
        )
    }
}

private struct MBAssistantSharingSettingsSection: View {
    @State private var assistantSharingOn = MBAssistantSession.shared.consent.isGranted
    @State private var stoppingAssistantSharing = false

    var body: some View {
        Group {
            if MBFeatureFlags.assistantEnabled && assistantSharingOn {
                Section {
                    Button(role: .destructive) { stoppingAssistantSharing = true } label: {
                        Label("Stop sharing with Sentinel", systemImage: "sparkles")
                    }
                } header: {
                    InfoLabel("Sentinel", info: "Sentinel sends what you type and the records needed to answer when using a connected cloud AI. Turn this off and Sentinel will ask again before sending.", topic: "Sentinel")
                }
            }
        }
        .onAppear { assistantSharingOn = MBAssistantSession.shared.consent.isGranted }
        .alert("Stop sharing with Sentinel?", isPresented: $stoppingAssistantSharing) {
            Button("Stop Sharing", role: .destructive) {
                MBAssistantSession.shared.consent.reset()
                assistantSharingOn = false
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Sentinel will ask before sending to connected cloud AIs again.")
        }
    }
}

private struct MBBrandingAndDocumentsSettingsScreen: View {
    @AppStorage(AppBranding.useCompanyLogoKey) private var useCompanyLogo = true
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query private var userProfiles: [UserProfile]
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var domainError: DomainError?
    @FocusState private var signatureFieldFocused: Bool

    private var emailSignatureTextBinding: Binding<String> {
        Binding(
            get: { profiles.first?.emailSignatureText ?? "" },
            set: { newValue in
                guard ReadOnlyGate.allows(.saveAppSettings, into: $readOnlyRefusal) else { return }
                perform {
                    try BusinessProfileService.setEmailSignatureText(newValue, saveNow: false, in: modelContext)
                }
            }
        )
    }

    private func saveEmailSignatureText() {
        modelContext.saveChanges()
    }

    private func perform(_ write: () throws -> Void) {
        do { try write() } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    private var emailNameBinding: Binding<Bool> {
        Binding(
            get: { userProfiles.first?.useMyNameInEmails ?? false },
            set: { newValue in
                guard ReadOnlyGate.allows(.saveAppSettings, into: $readOnlyRefusal) else { return }
                UserProfile.setUseMyNameInEmails(newValue, in: modelContext)
            }
        )
    }

    private func profileBinding(_ setting: BusinessDisplaySetting) -> Binding<Bool> {
        Binding(
            get: { profiles.first?[keyPath: setting.keyPath] ?? true },
            set: { newValue in
                guard ReadOnlyGate.allows(.saveAppSettings, into: $readOnlyRefusal) else { return }
                perform { try BusinessProfileService.setDisplay(setting, newValue, in: modelContext) }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                if let profile = profiles.first {
                    NavigationLink {
                        MyCompanyFormScreen(profile: profile)
                    } label: {
                        HStack(spacing: 12) {
                            MenuButtonLabel()
                                .frame(width: 34, height: 34)
                            Text("Your logo")
                            Spacer()
                        }
                    }
                }
                Toggle(isOn: profileBinding(.logoOnDocuments)) {
                    InfoLabel("Logo on documents and texts",
                              info: "Puts your logo on estimates, invoices, change orders, payment receipts and completion packages, and on the logo picture sent with a text message. Your logo in emails is the next switch.",
                              topic: "Logo on documents and texts")
                }
                Toggle(isOn: profileBinding(.emailSignature)) {
                    InfoLabel("Logo and signature in emails",
                              info: "Adds your logo, business name and contact details at the bottom of every email you send — estimates, invoices, change orders, receipts and contractor packages. Turn it off and emails go out with no logo.",
                              topic: "Logo and signature in emails")
                }
                if profiles.first?.emailSignatureEnabled ?? true {
                    TextField("Extra line in emails (optional)", text: emailSignatureTextBinding, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($signatureFieldFocused)
                        .onChange(of: signatureFieldFocused) { _, focused in
                            if !focused { saveEmailSignatureText() }
                        }
                    Picker("Name in emails", selection: emailNameBinding) {
                        Text("Owner’s name").tag(false)
                        Text("My name").tag(true)
                    }
                }
                Toggle("Show address on documents", isOn: profileBinding(.addressOnDocuments))
                NavigationLink {
                    DocumentSettingsScreen()
                } label: {
                    Label("Document Messages", systemImage: "text.bubble")
                }
            } header: {
                InfoLabel("What customers see", info: "Everything that shows up on the estimates, invoices, receipts and emails you send. Your logo in emails uses the light version — email backgrounds are white.", topic: "What customers see")
            }

            Section {
                Toggle("Use logo in the app", isOn: Binding(get: { useCompanyLogo },
                                                            set: { AppSettingsService.setUseCompanyLogo($0) }))
            } header: {
                InfoLabel("In the app", info: "Personalizes the Menu button and the faint background watermark. This device only — it changes nothing your customers see.", topic: "In the app")
            }
        }
        .glSettingsScreenStyle(paddedTitle: GLScript.padded(mbLoc("Branding & Documents")), bannerShown: MBSystemBannerInset.isShowing)
        .safeAreaInset(edge: .top, spacing: 0) { MBSystemBannerInset() }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .onDisappear { saveEmailSignatureText() }
    }
}

private struct MBSchedulingSettingsScreen: View {
    @AppStorage(SchedulingPrefs.oneJobAtATimeKey) private var oneJobAtATime = true

    var body: some View {
        Form {
            Section {
                Toggle("Book one job at a time", isOn: Binding(get: { oneJobAtATime },
                                                               set: { AppSettingsService.setOneJobAtATime($0) }))
            } header: {
                InfoLabel("Scheduling", info: "Warns you before you double-book a day.", topic: "Scheduling")
            }

            Section {
                NavigationLink {
                    WorkScheduleScreen()
                } label: {
                    Label("Work schedule", systemImage: "calendar.badge.clock")
                }
            } header: {
                InfoLabel("Workdays", info: "Set your workdays and hours, the holidays you take off, and any time off — these drive your next available date and the gaps between jobs.", topic: "Workdays")
            }
        }
        .glSettingsScreenStyle(paddedTitle: GLScript.padded(mbLoc("Scheduling & Workdays")), bannerShown: MBSystemBannerInset.isShowing)
        .safeAreaInset(edge: .top, spacing: 0) { MBSystemBannerInset() }
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
}
