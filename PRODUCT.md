# Keytempo

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS 13 and later, built with AppKit and SwiftUI using Swift Package Manager.

## Users and purpose

Keytempo is a personal menu bar utility for understanding everyday typing rhythm across applications, including Chinese input methods. It combines input metadata into estimated WPM, keystroke counts and measured typing duration, with local history, sessions and optional application breakdowns.

## Operating context

The menu bar is the frequent, glanceable surface. Its popover exposes recent and daily activity. Separate native windows provide detailed activity, history, settings, a validation editor and levels/appearance controls. The user evaluates new builds locally before approving public releases.

## Capabilities and constraints

- Combine recorded input languages into estimated WPM; retain KPM as a secondary metric. Global estimates do not claim committed Chinese-character output.
- Default to live WPM while typing and today's keystroke count when idle, preserving any saved menu display selection on upgrade.
- Preserve context filtering, shortcut and repeat exclusions, privacy permissions, input boundaries and observed-interval timing. Never store input text, complete key sequences, clipboard contents or window titles.
- Show daily Typing Score and daily XP separately. Credit completed reward days at 00:00 in the persisted reward timezone without waiting for sleep. Catch up after wake or launch when midnight was missed. On the next menu/app opening, process any overdue settlement and present committed unseen receipts in order; skipping changes no earnings.
- Unlock only themes and menu icons using committed lifetime XP. Cosmetic selection does not alter scores, XP, input filtering or level thresholds. Levels continue beyond the highest cosmetic unlock at 100.
- Keep nine differentiated themes, eight menu icons, system/light/dark appearance and a 16-milestone level roadmap. Rhythm, Ripple and Comet unlock at levels 15, 45 and 70 and change their static patterns proportionally with current WPM across a user-selected range (20–120 WPM by default). The same range controls the standard animation response for every icon. Menu icons and text use the native system foreground color. Standard speed-responsive menu motion and settlement animations are available at every level; actual level gains retain their announcement.
- Keep background CPU, memory, wakeups and battery cost low. Use existing event-driven updates; speed-responsive menu motion renews finite leases only with fresh active snapshots, stops when idle or hidden, and provides an off switch. Static speed-dependent icon patterns use those snapshots and remain available under Reduce Motion or low power without continuous animation. The explicit six-second preview ramps through the selected range and does not create typing records.
- Preserve native accessibility, keyboard navigation, Reduce Motion and Increase Contrast. Keep English and Simplified Chinese interfaces complete.

## Brand commitments

The application is named Keytempo. The user wants more polished and expressive high-level appearances, especially in the menu bar, with animation and effects where performance permits. Interface copy stays concise, factual and free of decorative slogans. Reward visuals should make the tool enjoyable while keeping metrics readable.

## Evidence and delivery

Production Swift sources, native self-checks and the installed app are the implementation authority. The stable release is 0.5.3, build 25, with global keyboard compatibility across input languages, input-source handoff and Caps Lock recovery fixes. Midnight XP credit without a sleep prerequisite and settlement playback on the next menu/app opening remain available, along with proportional menu-icon response, the configurable animation range and the typing/count default. Use synthetic fixtures for testing settlement states and preserve real local typing history. Publish releases after local verification and user authorization.

## Product principles

1. Make the menu bar useful at a glance.
2. Distinguish measured evidence, estimates and unavailable data.
3. Give progression visible cosmetic value without changing measurement.
4. Keep all typing records local and minimize background work.
