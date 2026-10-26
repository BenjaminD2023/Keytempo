---
name: Keytempo
description: Native typing statistics with engraved vector themes and menu icon choices.
colors:
  score-light: "#0A6B63"
  score-dark: "#7AE0C9"
  xp-light: "#945E12"
  xp-dark: "#F2C975"
  ocean-light: "#1461A6"
  ocean-dark: "#66B8FA"
  prism-light: "#6E52AD"
  prism-dark: "#C2A8FA"
  forest-light: "#296942"
  forest-dark: "#85D994"
  ember-light: "#A8471A"
  ember-dark: "#FAA35E"
  graphite-light: "#4D5966"
  graphite-dark: "#C4D1E0"
  rose-light: "#A3476E"
  rose-dark: "#F7A1BD"
  aurora-light: "#4A4DAB"
  aurora-dark: "#A8B8FC"
typography:
  number:
    fontFamily: "SF Pro"
    fontSize: "46pt"
    fontWeight: 600
    fontFeature: "tabular-nums"
  window-title:
    fontFamily: "SF Pro"
    fontSize: "26pt"
    fontWeight: 600
  body:
    fontFamily: "SF Pro"
    fontWeight: 400
  caption:
    fontFamily: "SF Pro"
    fontWeight: 400
  status:
    fontFamily: "SF Pro"
    fontSize: "12pt"
    fontWeight: 500
    fontFeature: "tabular-nums"
rounded:
  preview: "6pt"
  choice: "12pt"
  surface: "14pt"
spacing:
  tight: "6pt"
  small: "8pt"
  group: "12pt"
  row: "16pt"
  panel: "20pt"
  page: "24pt"
components:
  menu-icon:
    size: "18pt"
  theme-choice:
    rounded: "{rounded.choice}"
  reward-ledger:
    rounded: "{rounded.surface}"
    padding: "20pt"
---

# Design System: Keytempo

## Overview

**Creative North Star: "Engraved Spectra"**

Keytempo is a small native instrument that earns visual choices through use. Its numbers and controls stay quiet and familiar; authored linework, faceted seals and compact menu icons carry the personality. The nine themes have distinct geometry, not just different accent colors.

The app is used throughout the day in the macOS menu bar. It follows the user's system appearance or explicit light/dark choice. SwiftUI semantic foregrounds and native AppKit controls remain the foundation.

**Key Characteristics:**
- Crisp geometric vector theme artwork, with no raster theme assets or decorative blur.
- Tabular numerals, factual labels and compact native controls.
- Cosmetic progression unlocks nine themes and eight menu icons; standard motion is available at every level.
- Speed-responsive menu motion in finite leases and bounded committed settlements; static theme art.

## Colors

Theme colors are declared in `AppAppearanceStyle.accent`, `canvas` and `spectrum`. Dark and light accents are chosen independently for readable contrast. Secondary spectrum colors are decorative and never carry body text.

Filled native controls use `AppAppearanceStyle.filledControlTint`, the deeper light-appearance accent in either appearance. Selected segments and prominent buttons have white labels, so their fill stays separate from the brighter accent used for dark-mode text and artwork. All nine fills are checked against white at a minimum 4.5:1 contrast in both native appearances; the current palette ranges from 5.41:1 to 7.18:1.

Practice score keeps its teal identity; XP keeps its warm gold identity across themes. This preserves recognition when the user changes appearance. Ordinary text uses the platform's semantic primary and secondary foregrounds. Error and permission states retain their established orange or red meanings.

Menu icons and text use the native macOS system foreground color. Theme palettes remain inside the app's artwork and surfaces.

**The Quiet Field Rule.** Data rests on neutral or gently tinted opaque surfaces. Rich multi-color linework belongs to the rank, header, theme chooser and settlement composition.

## Typography

SF Pro is the native operating typeface. Important measured values use semibold tabular numerals. Body text and labels use semantic native styles; the platform resolves their sizes. Labels use native callout and caption styles; normal text is never monospaced. The menu uses the explicit `StatusItemPresentation.font` so measurement matches rendering.

Reward values share one size across the score and XP columns. Long values fit their actual available width; the underlying scores remain uncapped. Settlement numbers occupy fixed columns and the level announcement reserves its space before appearing.

## Layout

The menu popover stays 358 points wide with 18-point insets. Its header pairs identity/status with an actionable rank seal, followed by current/recent speed, daily totals, a compact score/XP ledger and native action rows.

The statistics window retains native segmented navigation. A single rank header pairs rank identity with the selected theme artwork. Activity is a 980-point maximum column; appearance is a 940-point maximum column. The appearance gallery uses adaptive columns with a 180-point minimum, so previews remain legible at the window's minimum width. Menu settings contain the icon picker, motion toggle and finite preview.

The menu item measures the real text plus its icon, spacing and insets. Hybrid mode reserves an ordinary two-digit WPM title; wider actual values expand the explicit width. It does not reserve an imaginary maximum count.

## Elevation & Depth

Depth comes from opaque tonal surfaces and a small number of precise outlines. Theme selection has a stronger outline; unselected previews have a subtle one. Rewards use one shared ledger surface and a dividing rule. Rank seals use geometric facets, translucent vector fills and hairlines, without a shadow or blurred halo.

## Shapes

Theme paths have distinct grammars: Classic has five restrained cadence curves; Ocean has nine wave contours; Prism has seven triangular facets; Forest has eight tapered contours; Ember has nine rising arcs; Graphite has seven stacked planes; Stellar has four inclined orbits and eleven fixed stars; Rose has nine five-lobed contours; Aurora has twelve interleaved ribbons and seven cross glints.

Rank seals use one hexagonal outline with an inset hexagon and six radial cuts at every level. Theme symbols remain genuine SF Symbols. The eight tiny menu icons are hand-authored vector silhouettes inside the same 18-point extent. Five keep a fixed drawing. Rhythm changes bar heights; Ripple changes ring geometry and visibility; Comet changes trail length and visibility proportionally as WPM increases. Level never changes an icon's detail.

## Components

### Native controls

Use native segmented pickers, toggles, text fields, buttons and date pickers. Preserve their keyboard and accessibility behavior. Visible labels describe the action or value. Do not add decorative slogans.

Apply `filledControlTint` locally to segmented pickers and prominent buttons. Do not replace the global text/art accent with this darker fill. Ordinary bordered or text buttons retain their native foreground treatment.

### Theme gallery

Each preview shows the real theme geometry and palette, its name and unlock level. A checkmark and strong outline identify the selected theme. Locked choices keep their preview but are disabled and expose their required level through accessibility and help text. Hover only changes an available choice's outline.

The roadmap contains 16 milestones for nine themes and eight menu icons. These are the only cosmetic unlocks.

### Rank seal

The seal is decorative; actual level and XP remain adjacent semantic text. Its shape and detail stay constant across levels; its symbol and palette follow the relevant theme. Rank geometry never implies a second progress scale. Levels above 100 continue using the highest unlocked rank identity.

### Menu response

Rhythm, Ripple and Comet unlock at levels 15, 45 and 70. Their drawings respond to the percentage `clamp((WPM − lower) / (upper − lower), 0, 1)` through the saved WPM range. The default range is 20–120 WPM; finite endpoints must be within 0–1,000 WPM and at least 1 WPM apart. Missing, nonfinite or nonpositive WPM uses a separate idle drawing. Bar geometry, ring visibility and comet trails vary proportionally instead of selecting coarse speed tiers. Existing aggregate snapshots drive these patterns, including with the motion switch off, Reduce Motion or low power.

The 18-point template cache rounds only drawing precision to 1% and keys images by style and percentage, independent of levels or range settings. Its maximum is 311 images: five fixed drawings plus three icons with 101 active percentages and one idle drawing each. Menu text and icons keep the native system foreground color.

At every level, current WPM controls a contrasting sweep masked to the actual status icon, two short rotating cadence cuts and two sparks. The unrounded percentage through the same selected range increases cadence from 0.65 to 2.6 cycles per second and strengthens the highlight. The selected icon and neighboring number keep their existing layout.

Fresh aggregated snapshots renew a finite 2.2-second Core Animation lease at most once per second, preserving cadence phase as the icon drawing changes. A missing or stale snapshot expires the effect; absent or invalid current WPM stays static. The effect uses six layers including the root and alpha mask, plus one cancellable cleanup task. Every menu animation requests a 15–30 FPS range with 30 FPS preferred; the compositor owns actual scheduling. Normal monitoring reuses existing snapshot updates and adds no animation clock, display link, per-key renderer or ongoing timer.

Idle, pause, missing permissions, a disabled motion preference, hidden status window, sleep, screen sleep, session lock, Reduce Motion, Increase Contrast and low power remove the layers. Lifecycle suppression waits for a new idle-to-typing segment. User appearance changes, popover closure and statistics/settings-window closure also cancel the current presentation. A proportional icon change updates its mask without cancelling an explicit preview.

The appearance panel provides a saved motion toggle, lower/upper WPM settings and an explicit preview at every level. The six-second preview ramps through the selected range for five seconds, then holds the upper endpoint for one second. Its temporary sample updates are bounded to 10 Hz and end with the preview; normal monitoring does not adopt that update rate. The panel also shows static examples across the selected range, available under Reduce Motion or low power. Samples never change the menu title, typing records, history or XP. Visibility, permission, power and accessibility gates still apply to the animated preview.

### Settlement

The settlement represents an immutable committed receipt, retained while the menu popover hands presentation to the panel. Score and awarded XP sit in parallel columns beneath the rank artwork. Next, skip and close controls remain available during animation. Loading states provide Close and Escape; read errors expose Retry alongside Close.

Every level uses the same standard settlement animation in the selected theme. The XP interpolation lasts 1.15 seconds; the vector burst lasts 2.4 seconds, with ten streaks or twinkles and two rings. An actual level gain triggers the finite medal response and progress reset. Reduce Motion and low power show final values without playing. Sleep, dismissal or a new accessibility/power restriction latches the presentation into its final static state; no delayed task can restart it. Normal queue timing is unchanged.

## Do's and Don'ts

- **Do** keep count, rate, estimate and unavailable-state semantics unchanged.
- **Do** use native semantic text colors and hide decorative vectors from accessibility.
- **Do** let each theme's geometry carry its distinction in both light and dark appearances.
- **Do** cache fixed icons by style and responsive icons by their normalized percentage; let macOS supply the system foreground color.
- **Don't** add a background animation clock, unbounded animation, random particle field or decorative blur.
- **Don't** animate text reflow or change measurements to make the UI more dramatic.
- **Don't** turn the data screens into stacks of decorative tiles.
