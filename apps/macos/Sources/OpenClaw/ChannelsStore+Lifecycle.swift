import Foundation
import OpenClawProtocol

extension ChannelsStore {
    private func resolvedWhatsAppAccountId() -> String {
        self.snapshot?.channelDefaultAccountId["whatsapp"] ?? "default"
    }
    func start() {
        guard !self.isPreview else { return }
        guard self.pollTask == nil else { return }
        self.pollTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.refresh(probe: true)
            await self.loadConfigSchema()
            await self.loadConfig()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                await self.refresh(probe: false)
            }
        }
    }

    func stop() {
        self.pollTask?.cancel()
        self.pollTask = nil
    }

    func refresh(probe: Bool) async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        do {
            let params: [String: AnyCodable] = [
                "probe": AnyCodable(probe),
                "timeoutMs": AnyCodable(8000),
            ]
            let snap: ChannelsStatusSnapshot = try await GatewayConnection.shared.requestDecoded(
                method: .channelsStatus,
                params: params,
                timeoutMs: 12000)
            self.snapshot = snap
            self.lastSuccess = Date()
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func startWhatsAppLogin(force: Bool, autoWait: Bool = true) async {
        guard !self.whatsappBusy else { return }
        if force && self.whatsappLoginInProgress {
            self.whatsappLoginMessage = "Relink already in progress. Please scan the current QR or wait for timeout."
            return
        }

        self.whatsappBusy = true
        defer { self.whatsappBusy = false }

        let accountId = self.resolvedWhatsAppAccountId()
        var shouldAutoWait = false
        do {
            if force {
                // UX hardening: when relinking from UI, explicitly clear channel auth first
                // (equivalent to `openclaw channels logout --channel whatsapp --account <id>`)
                // before requesting a fresh QR.
                self.whatsappLoginWaitTask?.cancel()
                self.whatsappLoginWaitTask = nil
                self.whatsappLoginInProgress = false

                let logoutParams: [String: AnyCodable] = [
                    "channel": AnyCodable("whatsapp"),
                    "account": AnyCodable(accountId),
                ]
                _ = try? await GatewayConnection.shared.requestDecoded(
                    method: .channelsLogout,
                    params: logoutParams,
                    timeoutMs: 15000) as ChannelLogoutResult
            }

            let params: [String: AnyCodable] = [
                "force": AnyCodable(force),
                "timeoutMs": AnyCodable(30000),
                "accountId": AnyCodable(accountId),
            ]
            let result: WhatsAppLoginStartResult = try await GatewayConnection.shared.requestDecoded(
                method: .webLoginStart,
                params: params,
                timeoutMs: 35000)
            self.whatsappLoginMessage = result.message
            self.whatsappLoginQrDataUrl = result.qrDataUrl
            self.whatsappLoginConnected = nil
            shouldAutoWait = autoWait && result.qrDataUrl != nil
            self.whatsappLoginInProgress = shouldAutoWait
        } catch {
            self.whatsappLoginMessage = error.localizedDescription
            self.whatsappLoginQrDataUrl = nil
            self.whatsappLoginConnected = nil
            self.whatsappLoginInProgress = false
        }
        await self.refresh(probe: true)
        if shouldAutoWait {
            self.whatsappLoginWaitTask?.cancel()
            self.whatsappLoginWaitTask = Task { await self.waitWhatsAppLogin(accountId: accountId) }
        }
    }

    func waitWhatsAppLogin(timeoutMs: Int = 120_000, accountId: String? = nil) async {
        guard !self.whatsappBusy else { return }
        self.whatsappBusy = true
        defer {
            self.whatsappBusy = false
            self.whatsappLoginInProgress = false
            self.whatsappLoginWaitTask = nil
        }
        do {
            let params: [String: AnyCodable] = [
                "timeoutMs": AnyCodable(timeoutMs),
                "accountId": AnyCodable(accountId ?? self.resolvedWhatsAppAccountId()),
            ]
            let result: WhatsAppLoginWaitResult = try await GatewayConnection.shared.requestDecoded(
                method: .webLoginWait,
                params: params,
                timeoutMs: Double(timeoutMs) + 5000)
            self.whatsappLoginMessage = result.message
            self.whatsappLoginConnected = result.connected
            if result.connected {
                self.whatsappLoginQrDataUrl = nil
            }
        } catch {
            self.whatsappLoginMessage = error.localizedDescription
        }
        await self.refresh(probe: true)
    }

    func logoutWhatsApp() async {
        guard !self.whatsappBusy else { return }
        self.whatsappBusy = true
        defer { self.whatsappBusy = false }
        do {
            self.whatsappLoginWaitTask?.cancel()
            self.whatsappLoginWaitTask = nil
            self.whatsappLoginInProgress = false

            let params: [String: AnyCodable] = [
                "channel": AnyCodable("whatsapp"),
                "account": AnyCodable(self.resolvedWhatsAppAccountId()),
            ]
            let result: ChannelLogoutResult = try await GatewayConnection.shared.requestDecoded(
                method: .channelsLogout,
                params: params,
                timeoutMs: 15000)
            self.whatsappLoginMessage = result.cleared
                ? "Logged out and cleared credentials."
                : "No WhatsApp session found."
            self.whatsappLoginQrDataUrl = nil
        } catch {
            self.whatsappLoginMessage = error.localizedDescription
        }
        await self.refresh(probe: true)
    }

    func logoutTelegram() async {
        guard !self.telegramBusy else { return }
        self.telegramBusy = true
        defer { self.telegramBusy = false }
        do {
            let params: [String: AnyCodable] = [
                "channel": AnyCodable("telegram"),
            ]
            let result: ChannelLogoutResult = try await GatewayConnection.shared.requestDecoded(
                method: .channelsLogout,
                params: params,
                timeoutMs: 15000)
            if result.envToken == true {
                self.configStatus = "Telegram token still set via env; config cleared."
            } else {
                self.configStatus = result.cleared
                    ? "Telegram token cleared."
                    : "No Telegram token configured."
            }
            await self.loadConfig()
        } catch {
            self.configStatus = error.localizedDescription
        }
        await self.refresh(probe: true)
    }
}

private struct WhatsAppLoginStartResult: Codable {
    let qrDataUrl: String?
    let message: String
}

private struct WhatsAppLoginWaitResult: Codable {
    let connected: Bool
    let message: String
}

private struct ChannelLogoutResult: Codable {
    let channel: String?
    let accountId: String?
    let cleared: Bool
    let envToken: Bool?
}
