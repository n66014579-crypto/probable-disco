# WebKit frame-identity spoofing — real-WebKit reproduction (OE11044060622355)

## Why this package exists

Apple's reviewer (Nick, Product Security) closed report **OE11044060622355** with:

> The files we received are a standalone program that reimplements the WebKit classes rather than
> running in WebKit itself, so they don't show the issue in a real build. Please send a
> reproduction against a real WebKit build with Site Isolation enabled that shows a dialog
> attributed to a frame whose process did not send the message.

That critique of the original PoC is accurate — it embedded the five real function bodies
verbatim, but ran them against hand-written stand-in classes, not against compiled, linked
WebKit. This package replaces that with a real WebKit build and a real test. This environment has
no macOS/Xcode toolchain, so it's never been compiled or run here — it runs on your GitHub
Actions (macOS runner), the same way as your other WebKit finding's PoCs. **Real status as of the
third run (2026-11-09): the core WebKit build (phases 1-3) now finishes cleanly for real, twice in
a row. The final job (build TestWebKitAPI, run the test) has not yet finished — see "v3 third real
run" below for exactly why and what's changed for the next attempt.**

## What's actually being claimed (unchanged from the original report)

`WebPageProxy::runJavaScriptAlert`, `runJavaScriptConfirm`, `runJavaScriptPrompt`, and
`runOpenPanel` (`Source/WebKit/UIProcess/WebPageProxy.cpp`) resolve a `WebFrameProxy` from an
IPC-supplied `FrameIdentifier` via a global, connection-blind registry, and check only that the
resolved frame belongs to the current page. None of them checks that the IPC message's actual
sender (the real `IPC::Connection`/process it arrived on) owns that frame. The structurally
identical sibling `runBeforeUnloadConfirmPanel` is the one correct example — it additionally
checks `&frame->frameProcess().process() != webProcess.ptr()` and bails if the sender doesn't own
the named frame.

**Re-verified against WebKit `main` at commit `86af064084e1cfd66a11252d75c14808c1196a5c`
(2026-10-31) before writing this package** — the gap is still there, byte-for-byte consistent with
the original report. Citations: the four vulnerable handlers are at roughly
`WebPageProxy.cpp:12788-12873` (alert/confirm/prompt) and `:13139+` (openPanel); the one correct
sibling is at `:13059-13093`.

## What this package adds: a real build + a real test, scoped to one call site

Rather than try to prove all four handlers at once in a single multi-hour CI run, this follows the
same "start with one call site, prove the architecture works, then extend" discipline already
used successfully elsewhere in this engagement. It targets **`runJavaScriptAlert`** only, via Site
Isolation (so the alert really is raised by a different process than the one that owns the main
frame) plus one small, disclosed instrumentation patch.

### Why a patch is needed at all (and what it does / doesn't do)

There is no legitimate public API that lets a cross-origin iframe's JavaScript make its own
`alert()` claim to be a different frame — `WebChromeClient::runJavaScriptAlert`
(`Source/WebKit/WebProcess/WebCoreSupport/WebChromeClient.cpp:627-648`) always sends the frame's
own real `frameID()`/`info()`. Demonstrating the spoof therefore requires a stand-in for "the
cross-origin iframe's WebContent process has been compromised and sends this exact real IPC
message with a forged `frameID`" — which is what a genuine renderer memory-corruption exploit
would let a real attacker do. That's `patches/0001-sender-instrumentation-alert-frame-spoof.patch`:

- Gated entirely behind `#if ENABLE(IPC_TESTING_API)` (on by default for any Debug/ASan Cocoa
  build, confirmed at `Source/WTF/wtf/PlatformEnable.h:327-332` — no special build flags needed,
  and compiled out of any non-debug/shipping build).
- Only fires when the alert text starts with the literal marker `POC_FRAME_SPOOF:` — ordinary
  `alert()` calls are completely unaffected.
- When it fires, it substitutes `frame.mainFrame().frameID()` for `webFrame->frameID()` as the
  `FrameIdentifier` argument of the real `Messages::WebPageProxy::RunJavaScriptAlert` IPC message.
  `frame.mainFrame()` works whether the main frame is Local or Remote to this process
  (`WebCore::Frame::mainFrame()`/`::frameID()`, `Source/WebCore/page/Frame.h:88-94`, inherited
  unmodified by `RemoteFrame`); the identical accessor chain is already used in shipping code at
  `Source/WebKit/WebProcess/WebCoreSupport/WebSpeechRecognitionConnection.cpp:89`.
- **`frameInfo` (`webFrame->info()`) is deliberately left completely untouched** — only `frameID`
  is substituted. This isolates exactly this report's claimed bug (the receiving handler trusts
  `frameID` without checking who sent it) from any separate question of whether `frameInfo`'s own
  *contents* can be forged (a different, already-submitted finding from this same engagement).
- Everything downstream of the send — `WebPageProxy::runJavaScriptAlert`,
  `API::FrameInfo::create`/`stateSnapshot`, `WKFrameInfo` — is completely stock, unmodified WebKit.

### The test: `patches/0002-test-addition-frame-spoof.patch`

Adds `TEST(SiteIsolation, FrameIdentitySpoofingPoC_AlertAttributedToFrameWhoseProcessDidNotSendMessage)`
to `Tools/TestWebKitAPI/Tests/WebKit/WKWebView/SiteIsolation.mm`, modeled directly on that file's
own existing `IframeWithConfirm`/`IframeWithPrompt`/`MainFrameHeartbeatContinuesWhileCrossSiteIframeDialogShown`
tests (same `siteIsolatedViewAndDelegate(server)` helper, same `TestUIDelegate` pattern, same
`mainFrame.info._processIdentifier` idiom already used elsewhere in that file to confirm two real,
separate WebContent processes).

It loads `https://example.com/example` (main frame) with a cross-origin
`<iframe src='https://webkit.org/webkit'>`, which calls
`alert('POC_FRAME_SPOOF:forged alert')`. It then asserts, on the `WKFrameInfo` the app's
`WKUIDelegate` actually receives:

- `securityOrigin.host == "webkit.org"` — correct, because `frameInfo` was never touched. The
  dialog honestly still says it came from the real sender.
- `isMainFrame == true` and `_processIdentifier == <the main frame's real pid>` — **wrong**. These
  two fields are derived not from `frameInfo` but by `API::FrameInfo::stateSnapshot`
  (`Source/WebKit/UIProcess/API/APIFrameInfo.cpp:42-53`) **re-resolving the (forged) `frameID`**
  through `WebFrameProxy`'s global registry — i.e. exactly the trust gap this report describes,
  not anything the real sender legitimately controls.

So a successful run shows, with real compiled code: an alert honestly labeled as coming from
`webkit.org`'s own process, yet reported to the app as `isMainFrame = YES` with the *main frame's*
process identifier — a dialog attributed to a frame whose process did not send the message,
exactly as requested.

### Precedent this leans on

`Tools/TestWebKitAPI/Tests/WebKit/WKWebView/SiteIsolation.mm` already contains dozens of passing
tests exercising this exact Site Isolation / cross-process-frame infrastructure, including dialogs
specifically (`IframeWithAlert`-style tests, `MainFrameHeartbeatContinuesWhileCrossSiteIframeDialogShown`,
`SimultaneousDialogsFromMultipleCrossOriginFrames`) — so the only genuinely new code here is the
one-field patch and the one new test; the Site Isolation setup, multi-process confirmation, and
dialog-delegate plumbing are all WebKit's own, already-proven test machinery, not anything built
from scratch for this PoC.

## v2 (2026-11-01): the first version's single job couldn't fit build + TestWebKitAPI in ~6 hours

The first version of this package used one job running `Tools/Scripts/build-webkit --debug`
(no scope flag) followed by `run-api-tests --no-build`. That command builds Xcode's **"Everything
up to WebKit + Tools"** scheme — which does include `TestWebKitAPI`, but also drags in
MiniBrowser, MobileMiniBrowser, SwiftBrowser, and `gtest.framework`, none of which this PoC needs.
**The real run: the build step alone ran 5h49m, and the whole job was then cut off by GitHub's
own ~6-hour hard per-job cap before `TestWebKitAPI` was actually produced** — `run-api-tests`
failed immediately with `TestWebKitAPI was not found at .../WebKitBuild/Debug/TestWebKitAPI`.

**v2 splits the work across two jobs, along WebKit's own real Xcode scheme boundary** (confirmed
by reading `WebKit.xcworkspace`'s scheme files directly, not guessed):

- **Job `build-core`**: `Tools/Scripts/build-webkit --debug --only="Everything up to WebKit"` —
  this named scheme builds WTF, JavaScriptCore, ANGLE, WebGPU, WebInspectorUI, WebKitLegacy, and
  the core WebKit framework, including all code generation — and **excludes** TestWebKitAPI and
  the other tools entirely (confirmed: zero references to TestWebKitAPI in this scheme's `.xcscheme`
  file). It runs to its own natural completion — no artificial time-based kill — then the whole
  `WebKitBuild/Debug` product directory is tarred and uploaded as an artifact.
- **Job `build-tests-and-run`** (`needs: build-core`): re-fetches the identical pinned commit,
  re-applies the identical two patches, downloads and restores job 1's checkpoint into
  `WebKitBuild/Debug`, then runs `Tools/Scripts/build-api-tests --debug` — which builds only the
  much narrower `TestWebKitAPI` Xcode *project* scheme (confirmed via `Tools/Scripts/build-api-tests`'s
  own source) — before running the test.

This is deliberately **not** the old watchdog/checkpoint-at-an-arbitrary-time-limit chained
architecture (documented elsewhere in this research effort, which never completed one clean
end-to-end run across 16+ iterations, mostly from `SIGKILL`ing `xcodebuild` mid-write and
corrupting a partially-linked framework). Here, job 1's checkpoint always comes from a build that
finished **on its own**, never one cut off mid-link — so that specific corruption mode doesn't
apply. The one real, explicitly flagged, still-unverified assumption carried over from that
earlier work is whether Xcode's incremental build trusts a checkpoint restored on a different
VM/job at all; the mitigation (touching every restored file's mtime to "now", after the fresh
source checkout) is the same one used before. If it's wrong, the downside is just some wasted
incremental rebuild time in job 2, not a broken or corrupted build.

Both jobs are configured with `timeout-minutes: 358` (same backstop as before); confirmed
`productDir()` (`Tools/Scripts/webkitdirs.pm`) is the single shared function behind every build
step and `run-api-tests`, so job 1 and job 2 genuinely point at the same `WebKitBuild/Debug`
regardless of which scheme/script built into it.

**Honest status: this split is reasoned from reading WebKit's real build scripts and scheme
files, not yet proven by a run.** It should be more likely to fit within GitHub's per-job cap than
the single-job version (job 1 excludes several multi-GB targets the single-job version didn't
need), but neither job has actually executed yet in this form.

## v3 (2026-11-03): v2's job 1 ALSO didn't fit in ~6 hours — core build itself now split across
## 3 chained phases, 4 jobs total

The user ran v2 for real. `build-core` — the narrower "Everything up to WebKit" scheme, with
TestWebKitAPI/MiniBrowser/etc. already excluded — still didn't finish: it was cancelled at 5h58m,
annotated `The job has exceeded the maximum execution time of 5h58m0s`, build still in progress.
This is real, direct evidence that the core WebKit engine alone needs more than one GitHub Actions
job's ~6-hour hard cap on this hardware. (GitHub's hosted macOS arm64 runners have only 3 CPUs,
confirmed via GitHub's own `github-hosted-runners` docs — this is a genuinely CPU-bound build, not
unnecessary scope.)

**v3 splits the core build itself across three chained, checkpointed phases, then a fourth job
builds + runs the test on top of the finished core**:
`build-core-phase1` → `build-core-phase2` → `build-core-phase3` → `build-tests-and-run`.

This is not a new, untested idea. It specifically ports over the fixes a separate, much longer
WebKit PoC effort in this same research engagement (targeting a different bug, `FrameInfoData`
content forgery rather than this report's `frameID`-identity bug) arrived at only after **16
iterations** of a chained/checkpointed build failing in different ways — wrong build command,
masked failures, disk-tarball retention, CodeSign corruption from killing a build mid-write,
CodeSign corruption from a *resumed* build re-linking an already-fine restored bundle, and a
watchdog-vs-hard-timeout margin gap specific to restore-heavy jobs. Every one of those fixes is
carried into this package's `scripts/`:

- **`scripts/watchdog_build.sh`** — runs a build command in its own process group with an internal
  time budget. If the budget is hit, sends `SIGTERM` to the whole group first (not `SIGKILL`),
  waits up to 90 seconds for a clean exit, and only escalates to `SIGKILL` if it's still alive —
  giving an in-flight compile/link/codesign step a real chance to finish instead of being caught
  mid-write. A genuine build failure (non-zero exit on its own, not from the watchdog) fails the
  step for real; a deliberate on-budget stop does not — this is the fix for a real "masked
  failures" bug where an earlier, cruder version's unconditional `exit 0` let a genuine build
  regression go unnoticed for a full round of CI runs.
- **`scripts/verify_and_repair.sh`** — after a phase's build stops, runs
  `codesign --verify --deep --strict=all` on every `.framework`/`.xpc`/`.app` and discards any that
  fail verification, so the next phase rebuilds just that one piece instead of trusting a file that
  was caught mid-write by *this* phase's own watchdog.
- **`scripts/clear_stale_products.sh`** — before *resuming* a build from a restored checkpoint,
  unconditionally discards every already-linked/signed `.framework`/`.xpc`/`.app`/executable sitting
  directly under `WebKitBuild/Debug`, while leaving the far more expensive compiled `.o` files and
  Xcode's own build-plan state completely untouched. This is the fix for a real failure, reproduced
  twice in the sibling engagement, where the resumed build itself — not the previous phase's stop —
  corrupted an already-fine restored bundle by re-linking/re-signing it.
- **`scripts/checkpoint.sh` / `scripts/restore_checkpoint.sh`** — checkpoint the **whole**
  `WebKitBuild/` directory, not just `WebKitBuild/Debug`. Confirmed by reading
  `Tools/Scripts/webkitdirs.pm` directly (the `$baseProductDir/XCBuildData/...` glob) that Xcode's
  own incremental-build state, `WebKitBuild/XCBuildData/`, lives as a **sibling** of
  `WebKitBuild/Debug`, not inside it. An earlier draft of this v3 package (and v1/v2 of this same
  PoC) only checkpointed `WebKitBuild/Debug` — caught and fixed locally, with a scripted round-trip
  test (fake build tree, real tar/extract/clear), before this package was ever sent; checkpointing
  only `Debug` would have silently discarded the compiled-object and build-plan state a multi-phase
  chain exists to preserve, so later phases would never have actually progressed past wherever
  phase 1 reached, no matter how many phases were chained.
- Restore-heavy phases get a smaller internal watchdog budget (270 minutes) than phase 1's
  from-scratch budget (300 minutes) — the 30 minutes held back is reserved specifically for the
  download+extract+clear overhead that only restore-heavy phases pay. This is the fix for a real
  "margin gap" failure in the sibling engagement where a restore-heavy phase was cancelled by
  GitHub's own hard timeout with zero checkpoint produced, because its watchdog was set to the same
  budget as a from-scratch phase without accounting for the extra overhead.
- Every restore/extract/clear operation is itself wrapped in `scripts/run_with_deadline.sh`, which
  fails loudly (`::error::` + non-zero exit) if it doesn't finish within its own bound — so if
  something stalls, the log says exactly what and how long, instead of just "the job got
  cancelled."

**Budget math**: phase 1 gets a 300-minute internal watchdog (the same number already proven safe,
twice, for an equivalent from-scratch phase in the sibling engagement); phase 2 and phase 3 each
get 270 minutes. Cumulative core-build budget across the three phases: ~14 hours — comfortably
above the ~11-12 hours you said the full build realistically needs. If phase 3 still hasn't
finished the core build on its own by the time its own watchdog fires, `build-tests-and-run`
doesn't silently run the test against a half-built WebKit — `build-api-tests` will fail to link
against the incomplete core, and the existing "Interpret results" step reports that as
`INCONCLUSIVE`, not a false `NOT_REPRODUCED`.

**Tested locally, for real, before shipping** (this environment still has no macOS/Xcode
toolchain, so none of this substitutes for an actual WebKit build, but the chaining *mechanism*
itself is no longer just reasoned-about):
- `watchdog_build.sh`: verified a fast-succeeding command reports `completed`/exit 0; a
  fast-failing command reports `failed`/exit 1 (this caught a real bug — an earlier draft's
  `tee`-pipeline swallowed the real command's exit code, exactly the "masked failure" pattern this
  script exists to prevent, fixed with `set -o pipefail` inside the backgrounded subshell before
  this was ever sent); and a genuinely slow command actually gets `SIGTERM`'d at its budget and
  reports `watchdog_stopped`/exit 0.
- `run_with_deadline.sh`: verified a genuinely slow operation actually gets killed and the script
  exits 1 with a loud `::error::`.
- `checkpoint.sh` → `restore_checkpoint.sh` → `clear_stale_products.sh`: verified end-to-end
  against a synthetic fake `WebKitBuild/` tree (a `.framework`, an `.app`, a loose executable under
  `Debug/`, plus sibling `XCBuildData/` and `*.build/` directories standing in for real Xcode
  build-plan/intermediate-object state) that the whole tree round-trips through tar/extract
  correctly, and that `clear_stale_products.sh` removes only the `Debug/`-level bundles/executable
  while leaving the `XCBuildData/`/`*.build/` siblings completely untouched.
- `verify_and_repair.sh`: verified against the same fake tree that unsigned/fake bundles are
  correctly detected and removed (not a meaningful signature-correctness test without real
  codesign-signed output, but confirms the detection-and-removal logic itself runs correctly).

None of this is a substitute for a real multi-phase run — only an actual CI run can show whether
~14 hours of chained budget is actually enough, and whether the carried-over fixes hold up against
a build this specific ("Everything up to WebKit" only, not "+ Tools") rather than the one they were
originally proven against. Still scoped to one of the four vulnerable call sites
(`runJavaScriptAlert`) only. No bounty category or amount is claimed.

## v3 real run (2026-11-06): phase1 succeeded, phase2 failed on a packaging bug — fixed

The user ran the v3 4-job chain for real. Two pieces of real evidence came back, one good, one a
genuine bug on my end:

- **`build-core-phase1` succeeded** in 5h22m — consistent with its 300-minute internal watchdog
  firing plus setup/clone/verify/checkpoint/upload overhead. Its "Verify & repair" step (the v11
  fix, carried over from the sibling engagement) fired as designed and did real, useful work: it
  caught 4 bundles that came out broken from the watchdog's SIGTERM/SIGKILL stop
  (`com.apple.WebKit.WebContent.EnhancedSecurity.xpc`, `JavaScriptCore.framework`,
  `com.apple.WebKit.GPU.xpc`, `_WebKit_SwiftUI.framework`) and removed them so phase2 would relink
  them cleanly instead of trusting a half-written file — exactly its job.
- **`build-core-phase2` failed immediately** (18m54s, almost all of it spent re-fetching the
  commit and downloading phase1's checkpoint) in the "Restore the checkpoint" step:
  `scripts/restore_checkpoint.sh: line 18: scripts/run_with_deadline.sh: Permission denied`.

**Root cause: a real packaging bug, not a logic bug.** `restore_checkpoint.sh` and
`clear_stale_products.sh` invoked `scripts/run_with_deadline.sh` directly (relying on its
executable bit) instead of via `bash scripts/run_with_deadline.sh` the way every top-level step in
`poc.yml` already correctly invokes every script. I never explicitly set the executable bit on the
scripts before zipping this package, and whatever happened in the zip → unzip → `git add` → GitHub
checkout round trip, the bit didn't survive onto `run_with_deadline.sh` by the time phase2 ran —
so the direct invocation failed with a permission error before anything build-related even started.
This cost the user a wasted phase1 run (phase2's own failure doesn't invalidate phase1's actual
build progress, but phase2 never got to use it).

**Fix**: changed both call sites to `bash scripts/run_with_deadline.sh ...`, which runs correctly
regardless of the file's permission bits — removing the dependency entirely rather than just
re-setting the bit and hoping it survives packaging again. Verified the fix by reproducing the
exact failure locally first (stripped the executable bit from every script in a fresh test copy,
confirmed `restore_checkpoint.sh` failed with the identical `Permission denied` error), then
confirmed both fixed scripts complete successfully under that same no-exec-bit condition —
`restore_checkpoint.sh` against a real tar/extract round trip, `clear_stale_products.sh` against a
synthetic build tree, confirming it still only clears `Debug/`-level bundles and leaves
`*.build/`-sibling `.o` files untouched. All scripts in this package also now ship with the
executable bit set directly, as defense in depth — but the code no longer depends on it.

## v3 second real run (2026-11-07): all 3 core phases succeeded for the first time — final job hit two real bugs, both fixed

The user ran the exec-bit-fixed chain for real a second time. This is the best result this
engagement has gotten in its entire multi-week history:

- **`build-core-phase1`, `build-core-phase2`, and `build-core-phase3` all succeeded** — 5h20m,
  4h47m, 5h4m respectively (~15h25m total). The checkpoint/restore/resume mechanism worked exactly
  as designed across all three legs. The full WebKit core (WTF/JSC/WebCore/WebKit) is now a
  genuinely finished, verified build sitting in `build-core-phase3`'s checkpoint artifact.
- **`build-tests-and-run` failed**, in 13m10s, but on real, instructive evidence rather than
  packaging mistakes — two separate bugs, both confirmed directly from the user's uploaded
  `build-tests.log`/`test.log` rather than guessed from screenshots:

**Bug 1 — a genuine compile error.** The old final job ran `Tools/Scripts/build-api-tests --debug`
(a standalone build of `TestWebKitAPI.xcodeproj` on its own, outside the main `WebKit.xcworkspace`
context). That failed for real:
```
.../Tools/TestWebKitAPI/config.h:69:10: error: 'JavaScriptCore/JSExportMacros.h' file not found
note: Did not find header 'JSExportMacros.h' in framework 'JavaScriptCore' (loaded from
  '.../MacOSX26.5.sdk/System/Library/Frameworks')
```
Built standalone, clang resolved `JavaScriptCore` against the SDK's system framework (no private
headers) instead of the one phases 1-3 had just built locally, so the private header TestWebKitAPI
needs was never found. **Fix**: switched the final job's build step to `Tools/Scripts/build-webkit
--debug` — the same full-workspace scheme that compiled this exact source tree cleanly with zero
errors in the very first (v1) run of this whole engagement. WTF/JSC/WebCore/WebKit are already
built by phases 1-3, so this relies on Xcode's own incremental build to do only the remaining
delta (TestWebKitAPI + MiniBrowser/SwiftBrowser/gtest, which that scheme also happens to include —
there's no narrower workspace scheme that builds TestWebKitAPI alone). Run through the same proven
`watchdog_build.sh` wrapper, 270-minute budget.

**Bug 2 — the test step ran despite the build having failed.** The job summary showed
`build_status=` (empty) and the "Run the PoC test" step ran anyway. Root cause: GitHub Actions runs
`run:` steps under `bash --noprofile --norc -eo pipefail {0}` by default — `-e` is already active
even with no explicit `set -e` in the script. The old build step's script died the instant its
pipeline failed, before it reached the line that writes `build_status` to `$GITHUB_OUTPUT` — so
that output was simply never set. The next step's gate, `steps.build_tests.outputs.build_status ==
'0'`, then spuriously evaluated **true**: GitHub Actions expressions coerce both sides of `==` to
numbers when types differ, and `null` (an unset output) coerces to `0`, same as the string `'0'` —
so `undefined == '0'` is true. **Fix**: the build step now goes through `watchdog_build.sh`, which
writes its `build_outcome`/`build_exit_code` outputs unconditionally near the end of the script
(immune to this failure mode), and the test step's gate now compares against the non-numeric
string `'completed'` instead of `'0'` — a string that coerces to `NaN`, not `0`, so an unset output
can never spuriously match it. Added `set +e`/`set -e` guards around the test step's own fallible
pipeline too, as defense against the same bug class recurring there.

**Status at the time: reasoned and evidenced, not yet itself run.** Both fixes were backed by
direct evidence (the real compile error; the real empty `build_status`) and by strong precedent
(v1's own run already proved `build-webkit --debug` compiles this exact tree cleanly). The
output-gating fix has since been confirmed correct by a real run (next section) — the
`build-webkit --debug` switch has not, for a different reason than expected.

## v3 third real run (2026-11-09): all 4 jobs went green for the first time ever — but the final
## job's own 270-minute watchdog ran out before finishing, because "Everything up to WebKit +
## Tools" turned out to be a much bigger scheme than its name suggests

User ran the fixed chain for real. This is the best result yet: **`build-core-phase1`,
`build-core-phase2`, `build-core-phase3`, and `build-tests-and-run` all finished green** — no
CodeSign failure, no spurious test run, no silent failure masking. The job summary correctly
printed `RESULT: INCONCLUSIVE — the build did not finish within its 270-minute watchdog budget`
rather than a false CONFIRMED or a crash — i.e. the control-flow fix from the previous round
(gating the test step on `build_outcome == 'completed'`, immune to GitHub's null-coercion bug) is
now confirmed correct by a real run, for the first time.

**But the build itself didn't finish, and reading the real 64MB `build-tests.log` the user
uploaded showed why, directly — not from a screenshot, from the actual `xcodebuild` invocation
line and the full list of targets it started touching.** The build step's own command-line
invocation line confirms it really did run `-scheme "Everything up to WebKit + Tools"` as
intended, but that scheme is dramatically bigger than its name suggests or than this package's
own earlier comments assumed. In the ~270 minutes available, the log shows real, started work on:
TestWebKitAPI itself (good, that's the target that was needed) but also MiniBrowser,
MobileMiniBrowser, SwiftBrowser.app, DumpRenderTree, WebKitTestRunner, lldbWebKitTester, over a
dozen separate libwebrtc codec/support libraries (`yuv`, `yasm`, `webm`, `vpx`, `srtp`, `opus`,
`boringssl`, `aom`, `absl`, `libwebrtc.dylib`, and more), `dav1d` (a video codec) and its fuzzer,
ANGLE's shader translator, WebGPU's `wgslfuzz` fuzzer, over ten standalone JavaScriptCore test
tools (`testapi`, `testb3`, `testmasm`, `testdfg`, `testair`, `testmem`, `testRegExp`,
`testwasmdebugger`, `dynbench`, `minidom`, `mya`), `gtest`'s own framework, and several WebKit
daemons (`webpushd`, `webpushtool`, `adattributiond`). None of these are needed for the one
`SiteIsolation` test this PoC runs. By the time the 270-minute watchdog fired, the build was still
mid-way through relinking/re-emitting the Swift module for the `WebKit` framework target itself —
it had not yet reached a finished `TestWebKitAPI` binary. (Checked directly: zero `error:` lines
anywhere in the 64MB log, so this was genuinely a time problem, not a second compile bug.)

**Fix: go back to the narrower `Tools/Scripts/build-api-tests` route from two rounds ago, but this
time fix the actual cause of its original failure directly, instead of routing around it with a
bigger scheme.** That route's `'JavaScriptCore/JSExportMacros.h' file not found` error happened
because building the `TestWebKitAPI` project/scheme on its own doesn't make Xcode aware that
`JavaScriptCore` should resolve to the just-built local framework in `WebKitBuild/Debug` rather
than the SDK's own copy — confirmed by reading `Tools/Scripts/webkitdirs.pm`'s `XcodeOptions()`
and `buildXcodeScheme()` directly: `-workspace` and the correct `SYMROOT`/`OBJROOT` are already
passed by default, but nothing automatically adds `WebKitBuild/Debug` to
`FRAMEWORK_SEARCH_PATHS` for a project-level scheme that doesn't list `JavaScriptCore.xcodeproj`
as one of its own build dependencies. The build step now passes that search path explicitly:
```
Tools/Scripts/build-api-tests --debug 'FRAMEWORK_SEARCH_PATHS=<workspace>/wk/WebKitBuild/Debug $(inherited)'
```
(`$(inherited)` keeps whatever search paths the project already had, so this only adds a path, it
doesn't replace any). Verified the shell/Perl argument plumbing locally (not just read): simulated
exactly how GitHub Actions' `${{ github.workspace }}` substitution interacts with the single-quoting
needed to stop bash from trying to execute `$(inherited)` as a command substitution, and confirmed
`buildXcodeScheme`'s `system "xcodebuild", "-scheme", $scheme, @extraOptions` call (Perl's list-form
`system`, which bypasses the shell entirely) passes the whole `KEY=value with spaces` override
through as a single argument, exactly as xcodebuild expects. Kept the same 270-minute watchdog
budget, same job structure, same gating logic — this is a one-line change to what gets built, not
a new design.

## v3 fourth real run (2026-11-10): the FRAMEWORK_SEARCH_PATHS fix worked for JavaScriptCore —
## then a fast, real compile error (not a timeout) exposed a second, different bug: this job's own
## "Clear stale final build products" step was deleting WebKit.framework before this job's build
## ever had a chance to use it

User ran the fixed chain. Phases 1-3 succeeded again (5h23m, 4h59m, 5h9m — third clean run of the
core build in a row). `build-tests-and-run` this time failed **fast** — 23m31s, a real compile
error, not a timeout — which is itself progress: reading the real 1.2MB `build-tests.log`
confirms the `JSExportMacros.h` error from two rounds ago is completely gone (zero mentions in the
log), and the xcodebuild invocation line confirms the `FRAMEWORK_SEARCH_PATHS` override was
applied exactly as intended. That part of the fix works.

But a new, structurally identical error appeared for a different framework:
```
PlatformUtilities.h:33:10: fatal error: 'WebKit/WKNativeEvent.h' file not found
note: did not find header 'WKNativeEvent.h' in framework 'WebKit' (loaded from
  '.../MacOSX26.5.sdk/System/Library/Frameworks')
```
Same pattern as before (resolving to the SDK's copy instead of the local one), but this time for
`WebKit.framework` itself, which the `FRAMEWORK_SEARCH_PATHS` override should also cover since it
points at the whole `WebKitBuild/Debug` directory. The real cause turned out to be a conflict
between two parts of this package added in different rounds, not a third search-path gap: this
job's own "Clear stale final build products before resuming" step (added back in the v15 round of
the sibling engagement, ported into this package's v3 design, and still correctly needed in
phases 2 and 3) unconditionally deletes every `.framework`/`.xpc`/`.app` bundle under
`WebKitBuild/Debug` right after the checkpoint restore — including `WebKit.framework` — on the
theory that the upcoming build step will cleanly relink everything it just removed. That's true
for phases 2 and 3, whose build command (`build-webkit --only="Everything up to WebKit"`) really
does relink the whole core. It is **not** true for this job, whose build command
(`build-api-tests`, scoped to just the `TestWebKitAPI` scheme) only *links against* the core
frameworks as pre-built dependencies — it never rebuilds them. So this step was deleting
`WebKit.framework` and then handing control to a build that has no way to put it back, guaranteeing
this exact failure every time, regardless of the search-path fix.

**Fix**: removed the "Clear stale final build products" step from this job only (phases 2 and 3
keep it unchanged, where it's correctly matched to their build command). This is safe, not just
convenient: phase 3 already runs its own verify-and-repair pass immediately before checkpointing,
so the checkpoint this job restores is already known to be free of anything phase 3's own watchdog
might have left broken — there is nothing left for this job to usefully clear, and the thing it
was clearing is exactly what this job's build needs and cannot replace.

## v3 fifth real run (2026-11-12): removing the stale-product-clearing step worked (WebKit.framework
## error gone) -- but the SAME JavaScriptCore header error from two rounds ago came back, for a
## single target (`WebProcessPlugIn`) that the first `FRAMEWORK_SEARCH_PATHS` fix didn't reach

User ran the fixed chain again. Phases 1-3 succeeded a third time in a row (5h24m, 5h5m, 3h48m).
`build-tests-and-run` failed again, fast (14m53s, a real compile error) -- and reading the real
1.2MB `build-tests.log` confirms real progress: the `WebKit/WKNativeEvent.h` error from last round
is completely gone, confirming the stale-product-clearing removal fixed exactly what it was meant
to. But the *original* `JavaScriptCore/JSExportMacros.h` error from two rounds ago reappeared --
this time only for one target, `WebProcessPlugIn` (an injected-bundle plugin that gets loaded into
the WebContent process, built as part of the same `TestWebKitAPI` scheme, sharing the same
`config.h`), while every other target built past that same header line cleanly.

Rather than guess why one target behaves differently, read that target's own
`Tools/TestWebKitAPI/Configurations/WebProcessPlugIn.xcconfig` and the shared
`Configurations/Base.xcconfig` directly. Neither sets `FRAMEWORK_SEARCH_PATHS` itself, so there's
no project-level setting directly fighting the override -- but `Base.xcconfig` showed the
project's own established pattern for "add another place to find frameworks" on macOS is a literal
`-iframework <path>` flag baked into `OTHER_CFLAGS[sdk=macosx*]`, not `FRAMEWORK_SEARCH_PATHS` at
all. Also confirmed, by grepping `config.h` and the `PlatformUtilities.h` header involved in the
*previous* round's error, that the only framework-style (`<Framework/Header.h>`) imports anywhere
in this shared code are `JavaScriptCore`, `WebKit`, `Foundation`, and `Cocoa` -- the last two are
genuine system frameworks that were never in question, so there is no third framework lurking.

**Fix**: add the same local path via `OTHER_CFLAGS` and `OTHER_CPLUSPLUSFLAGS` (as an explicit
`-F`/`-iframework` pair, mirroring the project's own pattern for this exact kind of override)
in addition to keeping `FRAMEWORK_SEARCH_PATHS` -- not instead of it. This is deliberately
redundant: two independently-mechanized ways to tell every target in the scheme where the
already-built frameworks are, so a target that for whatever reason doesn't fully pick up one of
them should still pick up the other. Verified the shell/GitHub-Actions quoting for the two new
multi-word, `$(inherited)`-containing overrides the same way as the first one (simulated the
exact post-substitution bash parse), confirmed each lands as a single, correct argument.

## What this does NOT (yet) claim

- **The `OTHER_CFLAGS`/`OTHER_CPLUSPLUSFLAGS` addition above has not itself been run in CI yet.**
  It's grounded directly in this project's own xcconfig pattern for the same problem (not a blind
  guess), and the stale-product-clearing fix from last round is now independently confirmed
  working by this same run -- but whether this specific target picks up the new override is only
  known after the next real run.
- Checked for a third framework that might surface the same way once this one is fixed, by reading
  every framework-style import in the shared headers involved so far (`config.h`,
  `PlatformUtilities.h`): only `JavaScriptCore` and `WebKit` appear, both now covered twice over.
  There's no specific reason to expect a third, but this has been wrong about "that's the last one"
  twice already, so this is a reasoned expectation, not a guarantee.
- Phases 1-3 (the core build) are proven to work end-to-end for real, three full runs in a row now
  (2026-11-07, 2026-11-09, 2026-11-12). The `RESULT:` line `poc.yml` prints is only meaningful once
  the final job's build genuinely reaches `build_outcome == 'completed'`.
- Only one of the four vulnerable call sites (`runJavaScriptAlert`) is covered. `runJavaScriptConfirm`,
  `runJavaScriptPrompt`, and `runOpenPanel` are structurally identical and would need their own
  small patches/tests (same technique, same `patches/0001-*.patch` approach) — a natural next step
  once this one is confirmed, not attempted here to keep the first CI run's scope and cost down.
- `runBeforeUnloadConfirmPanel` (the one correct sibling) is not exercised here as a negative
  control; its sender lives in different code (navigation/frame-loader client, not
  `WebChromeClient`) and would need separately-traced instrumentation.
- Per this engagement's standing rule, no bounty category or amount is claimed or predicted.

## How to run it

1. Push this repo (including `.github/workflows/poc.yml` and `scripts/`) to any GitHub repository
   you control.
2. Trigger the workflow manually (`workflow_dispatch` — it will never fire on a push, since this is
   a many-hour, 4-job chain).
3. The four jobs run one after another (`needs:`), not in parallel — `build-core-phase1` →
   `build-core-phase2` → `build-core-phase3` → `build-tests-and-run`. The real second run took
   5h20m + 4h47m + 5h4m (~15h25m) for the three core phases combined — in that range, budget the
   full ~15-16 hours. `build-tests-and-run` now also runs the full `build-webkit --debug` scheme
   (not just `TestWebKitAPI` standalone, see above), so give it real time too even though it should
   mostly be incremental — its own watchdog is budgeted at 270 minutes.
4. Each `build-core-phase*` job uploads its own checkpoint artifact
   (`webkitbuild-phase1-checkpoint`, etc.) plus its own build log, whether it succeeds or fails, so
   if something goes wrong partway through the chain there's still something to look at. The final
   job uploads `poc-logs-tests-and-run` (`build-tests.log` + `test.log`).
5. The job summary and the final "Interpret results" step (in `build-tests-and-run`) print one of
   `RESULT: CONFIRMED`, `RESULT: NOT_REPRODUCED`, or `RESULT: INCONCLUSIVE`. Please report back
   which one, plus — if you can get them, not just screenshots — the actual log files: all three
   `build-phase*.log` files (so if a phase's build genuinely failed partway through the chain,
   rather than just running out of its own watchdog budget, that's visible directly) and
   `build-tests.log`/`test.log` from the final job.

## Suggested reply to Apple once (and only once) this comes back CONFIRMED

Don't post anything to the portal until a real run actually says `RESULT: CONFIRMED` — this
package hasn't been run yet. Once it has, a short, honest reply along these lines (edit to match
the actual log output):

> Thank you — here's a reproduction against a real, compiled WebKit Debug build with Site
> Isolation enabled (GitHub Actions macOS runner, WebKit commit 86af064084e1cfd66a11252d75c14808c1196a5c).
> A new TestWebKitAPI test (`SiteIsolation.FrameIdentitySpoofingPoC_AlertAttributedToFrameWhoseProcessDidNotSendMessage`)
> loads a top-level page and a cross-origin iframe that genuinely land in two different WebContent
> processes (confirmed via `_processIdentifier`), then has the iframe's own process send the real
> `RunJavaScriptAlert` IPC message naming the main frame's `FrameIdentifier` instead of its own —
> the one field a compromised renderer process would need to forge; everything else, including the
> message's own origin info, is left real. The resulting `WKFrameInfo` the app receives correctly
> reports the dialog's origin as the iframe's (`webkit.org`), but incorrectly reports
> `isMainFrame = YES` and the main frame's own process identifier — i.e. the dialog is attributed
> to a frame whose process did not send the message, exactly as requested. The one line of
> instrumentation needed to forge the `frameID` (not `frameInfo`) is disclosed and commented in the
> attached patch; everything downstream is stock WebKit. Build and test logs attached.

## Files in this package

- `patches/0001-sender-instrumentation-alert-frame-spoof.patch` — the disclosed, `IPC_TESTING_API`-gated
  sender-side stand-in in `WebChromeClient::runJavaScriptAlert`.
- `patches/0002-test-addition-frame-spoof.patch` — the new `SiteIsolation` test.
- `.github/workflows/poc.yml` — the 4-job chain: 3 checkpointed core-build phases, then a job that
  builds `TestWebKitAPI` and runs the test.
- `scripts/select_xcode.sh`, `scripts/free_disk_space.sh`, `scripts/fetch_webkit.sh` — ordinary
  per-job setup (select the newest available Xcode; clean up unused preinstalled SDKs/simulators;
  shallow-clone WebKit at the pinned commit and apply both patches).
- `scripts/watchdog_build.sh` — runs a build command with an internal, graceful (`SIGTERM`-first)
  time budget; used by all three core-build phases.
- `scripts/verify_and_repair.sh` — discards any `.framework`/`.xpc`/`.app` that fails codesign
  verification after a phase's build stops.
- `scripts/clear_stale_products.sh` — discards already-linked/signed build products (keeping
  compiled `.o` files and Xcode's build-plan state) before a phase resumes from a restored
  checkpoint.
- `scripts/checkpoint.sh` / `scripts/restore_checkpoint.sh` — tar/untar the whole `WebKitBuild/`
  directory between jobs, via `actions/upload-artifact`/`download-artifact`.
- `scripts/run_with_deadline.sh` — a stricter version of the watchdog used for the restore/clear
  bookkeeping steps, where taking too long is itself a real problem.
- This `README.md`.
