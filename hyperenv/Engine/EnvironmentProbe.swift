//
//  EnvironmentProbe.swift
//  hyperenv
//
//  Measures the environment the user's shell actually produces.
//

import Foundation

nonisolated struct ProbeResult: Sendable {
    /// What the shell reported.
    let observed: EnvSet
    /// The environment the probe was *given*, needed to subtract our own
    /// inheritance back out.
    let base: EnvSet
    /// Variables only an interactive shell sets (from `.zshrc` and `/etc/zshrc`).
    let interactiveOnly: Set<EnvKey>
}

nonisolated protocol EnvironmentProbe: Sendable {
    func probe(bypassHyperEnv: Bool) async throws -> ProbeResult
}

// MARK: - zsh implementation

nonisolated struct ZshLoginShellProbe: EnvironmentProbe {
    let runner: ProcessRunner
    var timeout: TimeInterval = 5

    /// A deliberately minimal, explicit base.
    ///
    /// `Process` *replaces* the environment rather than merging, which is what
    /// we want: inheriting the app's own launchd environment would import
    /// Xcode and XPC noise into the user's Default profile. But a bare `env -i`
    /// loses the variables only launchd provides, so the handful that matter
    /// are passed through explicitly.
    private var baseEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var base: [String: String] = [:]

        for name in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
                     "SSH_AUTH_SOCK", "LANG", "__CF_USER_TEXT_ENCODING"] {
            if let value = inherited[name] { base[name] = value }
        }

        base["HOME"] = base["HOME"] ?? Paths.home.path(percentEncoded: false)
        // Keeps prompt frameworks from emitting escape sequences or trying to
        // draw anything.
        base["TERM"] = "dumb"
        return base
    }

    func probe(bypassHyperEnv: Bool) async throws -> ProbeResult {
        guard Paths.isZshLoginShell else {
            // Writing zsh syntax into a fish or nushell config is a syntax
            // error in the user's login path — a broken shell on next login.
            throw HyperEnvError.unsupportedLoginShell(path: Paths.loginShell)
        }

        var environment = baseEnvironment
        if bypassHyperEnv {
            environment[SessionScriptRenderer.bypassVariable] = "1"
        }

        async let interactive = capture(interactive: true, environment: environment)
        async let login = capture(interactive: false, environment: environment)

        let interactiveEnv = try await interactive
        let loginEnv = try await login

        var base = EnvSet()
        for (name, value) in environment {
            if let key = EnvKey(name) { base[key] = EnvValue(value) }
        }

        let onlyInteractive = Set(interactiveEnv.keys).subtracting(loginEnv.keys)

        return ProbeResult(
            observed: interactiveEnv,
            base: base,
            interactiveOnly: onlyInteractive
        )
    }

    /// - Parameter interactive: `-lic` reflects what the human sees in Terminal;
    ///   `-lc` reflects what tooling and editors resolve. They differ, and the
    ///   difference is worth showing rather than hiding.
    private func capture(interactive: Bool, environment: [String: String]) async throws -> EnvSet {
        let flags = interactive ? "-lic" : "-lc"
        let script = "print -n '\(EnvOutputParser.sentinel)'; env -0"

        let result = try await runner.run(
            executable: Paths.loginShell,
            arguments: [flags, script],
            environment: environment,
            timeout: timeout)

        if result.timedOut {
            throw HyperEnvError.probeTimedOut(seconds: Int(timeout))
        }

        return try EnvOutputParser.parseNulSeparated(result.standardOutput)
    }
}
