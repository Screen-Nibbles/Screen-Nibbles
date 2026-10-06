# Screen Nibbles

Turn a scrolling iPhone or iPad screen capture into vertical panoramas and horizontal strips, then select and copy text from the original frames or stitched result.

## ReplayKit recording on iPhone/iPad

Direct capture is **ReplayKit-only**. The project does not use ScreenCaptureKit or `RPScreenRecorder` as an alternate path.

The easiest path is **Record Screen** inside Screen Nibbles. It presents Apple's `RPSystemBroadcastPickerView` already scoped to the embedded **Screen Nibbles Broadcast** extension. Confirm the system broadcast, switch to the content you want, scroll or swipe with brief settled moments, then stop with Apple's recording indicator. When you return, finalized recordings are detected and processed automatically.

The Control Center path is also supported:

1. Install the app **with the Screen Nibbles Broadcast extension** on a signed physical device.
2. Open Control Center and **touch and hold Screen Recording**.
3. Choose **Screen Nibbles**, then **Start Broadcast**.
4. Close Control Center and scroll vertically or swipe horizontally. Keep some overlap and pause briefly at useful positions.
5. Stop with Apple's red recording indicator or Screen Recording control, then return to Screen Nibbles.

The ordinary quick-tap Screen Recording action is Apple's normal Photos recording behavior; an app cannot replace that system action with its broadcast extension. Those videos can still be imported manually if desired.

## Signing setup

The app and broadcast extension use `group.com.tomaslin.Screen-Nibbles`. Both targets must be signed by the same team, with that App Group enabled in their provisioning profiles. The project already embeds the extension on iOS. If bundle identifiers or the signing team change, keep the App Group synchronized in both entitlement files, `SampleHandler.swift`, and `BroadcastRecordingInbox.swift`.

The extension records locally and ignores audio. It writes each live segment to a `.partial.mov` file inside a `.partial` session directory. A movie receives its final `.mov` name only after `AVAssetWriter` completes, and the whole session becomes `.capture` only when at least one finalized movie exists. The app ignores partial, empty, and nonregular files. Pauses, orientation changes, and dimension changes close the current segment instead of leaving timestamp gaps inside one movie.

Control Center broadcast capture requires a signed physical-device installation. The iOS Simulator cannot validate the actual ReplayKit broadcast-extension handoff.

## Results and text selection

The library is titled **Captures** and groups image thumbnails by day. Filter vertical or horizontal images, choose thumbnail size, and sort newest or oldest first from Gallery Options. Tap an image to inspect it; Previous and Next browse the current filter without returning to the grid. Touch and hold a thumbnail for selection, sharing, and deletion.

In the viewer, **Select Text** opens a frame-first OCR workspace. Browse the sharp source frames or switch to the stitched image. **Select Area** draws a rectangle around text. **Trim Edges** begins with the full frame and exposes independent top, bottom, left, and right handles so browser chrome, margins, recording controls, or a damaged edge can be excluded before OCR. Trim handles have 44-point hit regions and VoiceOver adjustable actions. Selections can be reset, cleared, or applied to all frames. The result is shown in an editable text view for normal iOS text selection and copying.

If an original recording has been moved or deleted, the stitched image remains available for text extraction instead of surfacing a missing-file error.

The stitcher is deliberately tolerant of imperfect captures: unreadable frames are skipped, isolated bogus-size frames are ignored, invalid registration shifts are rejected, and short runs of torn/incomplete middle frames can be bridged when the surrounding frames still register as one continuous scroll.

## iPhone/HIG notes

The main navigation uses a content title rather than the app name, primary actions use system buttons, custom crop handles expose at least 44×44-point hit regions, sheets use system navigation/Done placement, and narrow or large-text layouts can stack bottom actions rather than compressing them. The recording UI uses Apple's own ReplayKit broadcast picker instead of impersonating system recording controls.

## Validation

Run the static contract checks and Xcode build on a Mac with Xcode:

```sh
./Scripts/validate-ios-replaykit.sh
```

The script validates plist syntax, App Group consistency, the Broadcast Upload extension point, extension embedding, matching bundle identifiers, the iOS deployment target, and the absence of ScreenCaptureKit/`RPScreenRecorder`. When Xcode is available it also builds the app target, which includes the embedded ReplayKit extension.

The unit test target covers constant-rate extraction, scroll axes and reversals, orientation/mixed captures, fixed UI removal, normalized text crops, damaged middle frames, and finalized ReplayKit inbox discovery.

A final physical-iPhone pass is still mandatory because Simulator cannot reproduce Control Center broadcast selection or extension process limits. Test the in-app ReplayKit picker and the Control Center touch-and-hold flow, long portrait scrolling, horizontal swipes, rotation/interruption, stop/return auto-import, relaunch discovery, cancellation, and text selection at large Dynamic Type sizes with VoiceOver enabled.


## iPhone validation

See [`IPHONE_VALIDATION.md`](IPHONE_VALIDATION.md) for the ReplayKit-only capture contract, HIG/accessibility pass, robustness guarantees, and the physical-device release checklist.
