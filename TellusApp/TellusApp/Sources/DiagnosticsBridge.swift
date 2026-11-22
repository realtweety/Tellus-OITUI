import CoreFoundation
import Foundation

@MainActor
enum DiagnosticsBridge {
    private static let domain = "com.wilburt.tellus.bridge"
    private static let requestNotification = "com.wilburt.oiti/TellusDiagnosticsRequest"

    enum BridgeError: LocalizedError {
        case couldNotSaveRequest
        case timedOut

        var errorDescription: String? {
            switch self {
            case .couldNotSaveRequest:
                return "Tellus could not send the request to SpringBoard."
            case .timedOut:
                return "SpringBoard did not respond. Make sure Insula is enabled and try again."
            }
        }
    }

    static func request(_ action: String) throws -> String {
        let requestID = UUID().uuidString
        let domainName = domain as CFString
        CFPreferencesSetAppValue("RequestID" as CFString, requestID as CFString, domainName)
        CFPreferencesSetAppValue("Action" as CFString, action as CFString, domainName)
        CFPreferencesSetAppValue("ResponseID" as CFString, nil, domainName)
        CFPreferencesSetAppValue("ResponsePayload" as CFString, nil, domainName)
        guard CFPreferencesAppSynchronize(domainName) else {
            throw BridgeError.couldNotSaveRequest
        }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(requestNotification as CFString),
            nil,
            nil,
            true
        )
        return requestID
    }

    static func waitForResponse(to requestID: String) async throws -> String {
        let domainName = domain as CFString
        for _ in 0..<100 {
            try Task.checkCancellation()
            CFPreferencesAppSynchronize(domainName)
            let responseID = CFPreferencesCopyAppValue("ResponseID" as CFString, domainName) as? String
            if responseID == requestID {
                return CFPreferencesCopyAppValue("ResponsePayload" as CFString, domainName) as? String ?? ""
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw BridgeError.timedOut
    }

    static func perform(_ action: String) async throws -> String {
        try await waitForResponse(to: request(action))
    }
}
