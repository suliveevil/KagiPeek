#!/usr/bin/env bash
#
# Regression guard for the background statistics write.
#
# UsageStore writes usage.json from the utility queue `com.voltline.kagipeek.usage-write`.
# Under the app target's default MainActor isolation, an unannotated JsonFileStore, and a
# DispatchWorkItem formed in a MainActor context, are main-actor isolated; running them on the
# background queue failed Swift's runtime executor check and trapped (EXC_BREAKPOINT).
#
# This check compiles the real JsonFileStore with the same `-default-isolation MainActor`
# flags as the app, then actually runs its save on a background queue. A regression shows up
# either as a compiler warning (treated as an error) or a runtime "data race detected" line.
#
# Usage: ./scripts/verify_usage_store_isolation.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

X="${KAGIPEEK_XCODE:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -d "$X" ]; then X="${KAGIPEEK_XCODE:-/Applications/Xcode-beta.app/Contents/Developer}"; fi
TC="$X/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SDK="$X/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [ ! -x "$TC/swiftc" ]; then
    echo "error: no swiftc under $X" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRATCH="$WORK/data"

cp "$ROOT/KagiPeek/Core/Storage/DataDirectory.swift" "$WORK/DataDirectory.swift"
cp "$ROOT/KagiPeek/Core/Pure/DiagModel.swift" "$WORK/DiagModel.swift"

cat > "$WORK/stub-diag.swift" <<'SWIFT'
import Foundation

// Stand-in for Services/Diag.swift so the file store compiles without AppKit, the file log
// and the action recorder. The real Diag is nonisolated; this keeps the same contract.
nonisolated enum Diag {
    static func error(_ tag: DiagTag, _ message: @autoclosure () -> String) {}
    static func info(_ tag: DiagTag, _ message: @autoclosure () -> String) {}
}
SWIFT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

nonisolated struct SamplePayload: Codable, Equatable, Sendable {
    var name: String
    var value: Int
    var tags: [String]
}

let targetDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

let store = JsonFileStore(fileName: "isolation-test.json", directory: targetDir)
let payload = SamplePayload(name: "usage", value: 42, tags: ["a", "b"])

let semaphore = DispatchSemaphore(value: 0)
let writeQueue = DispatchQueue(label: "com.voltline.kagipeek.usage-write", qos: .utility)
// Form the work item in a nonisolated context, mirroring UsageStore.makeWriteItem, so the GCD
// block is not MainActor-isolated from the surrounding main-actor entry point.
let item = makeWorkItem(store: store, payload: payload) { semaphore.signal() }
writeQueue.asyncAfter(deadline: .now() + 0.05, execute: item)

guard semaphore.wait(timeout: .now() + 5) == .success else {
    fatalError("timed out waiting for the background write")
}
guard let loaded = store.load(SamplePayload.self), loaded == payload else {
    fatalError("the background-written payload did not read back correctly")
}
print("ok: JsonFileStore saved and reloaded safely off the main actor")

nonisolated func makeWorkItem(
    store: JsonFileStore,
    payload: SamplePayload,
    onDone: @escaping @Sendable () -> Void
) -> DispatchWorkItem {
    DispatchWorkItem {
        store.save(payload)
        onDone()
    }
}
SWIFT

echo "==> Compiling the real JsonFileStore with the app's MainActor default isolation"
"$TC/swiftc" -O -warnings-as-errors -o "$WORK/verify" -sdk "$SDK" \
    -target arm64-apple-macos14.0 -swift-version 6 -default-isolation MainActor \
    -Xfrontend -strict-concurrency=complete \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    "$WORK"/*.swift

echo "==> Running the background write (it must not trap or report a data race)"
output="$("$WORK/verify" "$SCRATCH" 2>&1)"
echo "$output"
if echo "$output" | grep -q "data race detected"; then
    echo "error: a main-actor-isolated call ran off the main thread" >&2
    exit 1
fi
if ! echo "$output" | grep -q "^ok:"; then
    echo "error: the background file-store verification did not succeed" >&2
    exit 1
fi
echo "==> Usage store isolation check passed"
