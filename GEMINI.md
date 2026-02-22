# GEMINI.md

This file provides a summary of the PingClaude project and outlines potential areas for improvement, as analyzed by Gemini.

## Project Summary

PingClaude is a native macOS menu bar application designed for developers who are heavy users of claude.ai. It helps manage the 5-hour rolling token limit by sending automated, periodic "pings" to a Claude model. This strategy allows the token usage from earlier, automated pings to expire from the rolling window, freeing up capacity during peak work hours.

The application is written entirely in Swift, using a modern stack with SwiftUI for the user interface and the Combine framework for reactive programming. It is architected as a set of distinct services that handle everything from pinging and scheduling to tracking API usage and calculating token "burn rate." It can operate in two modes: by invoking the `claude` command-line tool as a fallback, or by using the undocumented Claude web API. The latter method also enables a key feature: displaying live usage metrics directly in the menu bar and a dedicated info panel.

The project is built and managed via Swift Package Manager, with a `Makefile` providing convenient scripts for common tasks like building the app bundle, running, and installing. It also includes a custom-built code quality scanner to enforce coding standards, a solution created to work around the limitations of running on an older version of macOS.

## Areas for Improvement

Here are five suggested areas for improving the PingClaude codebase, focusing on security, maintainability, and robustness.

### 1. Introduce Automated Testing

**Observation:** The project currently lacks an automated test suite and relies on manual testing. This is risky for an application with complex stateful interactions involving scheduling, network requests, and system events like sleep/wake cycles.

**Suggestion:** Create a test target within the Swift Package. Begin by writing unit tests for the core services, particularly `PingService`, `SchedulerService`, and `UsageVelocityTracker`. Use mock objects to simulate network responses, file system interactions, and system events to ensure that the services behave correctly under a variety of conditions. This will significantly improve the project's reliability and make future refactoring safer.

### 2. Enhance Security with Keychain

**Observation:** API credentials (the `orgId` and `sessionKey`) are currently stored in `UserDefaults`, which is insecure as it's stored in a plaintext property list file.

**Suggestion:** Migrate the storage of these sensitive credentials to the macOS Keychain. The `Security` framework, which is available on all supported macOS versions (12+), provides a robust and secure way to store user data like passwords and API keys. This is a critical improvement to protect user credentials.

### 3. Streamline Build Process with Swift Package Manager

**Observation:** The project uses a `Makefile` to orchestrate the build process. While functional, this adds a layer of abstraction over the Swift Package Manager and introduces a non-standard build process for a Swift project.

**Suggestion:** Replace the `Makefile` with a simple shell script (e.g., `build.sh`) that directly uses Swift Package Manager commands (`swift build`, `swift test`, etc.) to build the application and create the `.app` bundle. This script would be responsible for tasks like creating the `Info.plist` and bundling resources. This change would make the project more idiomatic, easier for new contributors to understand, and more aligned with the Swift ecosystem's conventions.

### 4. Replace Custom Code Quality Scanner

**Observation:** The project includes a custom-built code quality scanner. While this was a clever solution to support an older development environment, it creates a maintenance burden and is not as comprehensive as community-standard tools.

**Suggestion:** Replace the custom scanner with a well-supported, third-party linter like SwiftLint. Even if this requires a newer version of macOS for the development environment, the application itself can still be built to target older macOS versions. The `.swiftlint.yml` configuration file is already present in the project, so the transition should be straightforward. This would provide a much richer set of linting rules, automatic correction capabilities, and the benefit of ongoing community support.

### 5. Decouple Services from AppDelegate

**Observation:** Currently, the `AppDelegate` is responsible for initializing and wiring up all the services, effectively acting as a dependency injection container. This is a common pattern, but it can lead to a bloated `AppDelegate` and makes services harder to test in isolation.

**Suggestion:** Introduce a simple, dedicated `DependencyContainer` class responsible for the life-cycle and injection of services. The `AppDelegate` would create and own an instance of this container, and the rest of the application would resolve dependencies from it. This would improve separation of concerns, make the relationships between services more explicit, and significantly improve the testability of the entire application.

## Developer Communication Guidelines

To ensure transparency and a high-quality developer experience, the agent (Gemini) should adhere to the following communication standards:

*   **Intent-First**: Before performing a task or a series of commands, provide a concise explanation of *what* is being attempted and *why*.
*   **Ongoing Status Updates**: Provide regular progress updates during the execution of a multi-step plan, especially after key milestones or tool calls, so the user is never left wondering about the current state.
*   **Proactive Status Updates**: When encountering errors or needing to pivot (e.g., from `XCTest` to a custom test runner), inform the user of the problem and the proposed solution *before* executing the fix.
*   **Comprehensive Test Reports**: After running tests, always report:
    *   The total number of tests written.
    *   A brief description of what each test verifies.
    *   Whether the tests were run and if they passed or failed.
*   **Contextual Summaries**: When finishing a multi-step task, provide a clear summary of the final state, including any new files created or architectural changes made.

