//
//  CodeSigningInfo.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation
import LightweightCodeRequirements
import Security
import XPC

nonisolated enum CodeSigningInfo {
    /// The team identifier of the current process, or `nil` when signed
    /// without one (ad-hoc), in which case a same-team peer requirement can't pass.
    static let processTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else {
            return nil
        }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Requires the exact built-in service for locally signed bundles.
    static func appToServiceRequirement(named service: String) throws -> XPCPeerRequirement {
        if processTeamIdentifier != nil {
            return .isFromSameTeam(andMatchesSigningIdentifier: service)
        }
        guard let fileName = service.split(separator: ".").last else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = Bundle.main.bundleURL.appending(path: "Contents/XPCServices/\(fileName).xpc")
        return try exactCodeRequirement(for: url, identifier: service)
    }

    /// Requires the actual containing app instead of accepting arbitrary callers.
    static func serviceToAppRequirement() throws -> XPCPeerRequirement {
        let identifier = "local.barfold.app"
        if processTeamIdentifier != nil {
            return .isFromSameTeam(andMatchesSigningIdentifier: identifier)
        }
        let url = Bundle.main.bundleURL
            .deletingLastPathComponent() // XPCServices
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Containing app
        return try exactCodeRequirement(for: url, identifier: identifier)
    }

    /// A missing or invalid signature prevents the connection.
    static func exactCodeRequirement(for url: URL, identifier: String) throws -> XPCPeerRequirement {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty,
              dictionary[kSecCodeInfoIdentifier as String] as? String == identifier
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        let requirement = try ProcessCodeRequirement.allOf {
            CodeDirectoryHash(hash)
            SigningIdentifier(identifier)
        }
        return .codeRequirement(requirement)
    }
}
