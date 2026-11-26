# Design direction

Reference points: Apple's own apps (Files, Photos, Notes), X, and small,
carefully made indie utilities like BasicClips. What they have in common is
restraint. The content is the color, the chrome gets out of the way, and
every element has a job.

## Principles

1. **Native first.** Use system navigation, lists, sheets, menus and SF
   Symbols. On iOS 26 these get Liquid Glass automatically. Following
   platform conventions closely is what makes an app feel finished.
2. **Glass is for navigation only.** Toolbars, tab bars and transient banners.
   Never on content and never on list rows. This is Apple's own guidance.
3. **One accent color, used rarely.** Deep evergreen (`AccentColor` in the
   asset catalog: #1D4B3C light, #6FBF9A dark), matching the app icon. It
   marks folders, the offline badge and primary buttons. The sidebar is
   the one place it's used as a surface: a light evergreen tint
   (`SidebarBackground`, #E3ECE6 / #18241E) with green-toned text and a
   solid evergreen selection (cream text, `OnAccent`). The file list stays
   neutral, so photo thumbnails carry the color. ("Tinted glass", chosen
   from four mockups in 2026-11; earlier: burnt orange, then teal.)
   Settings › Appearance offers more accents (Forest, Harbor Blue, Midnight,
   Graphite, Onyx, Rosewood, Espresso, and System, which follows the Mac's
   own accent with the plain sidebar), a Plain sidebar, and matching alternate app icons
   (`ThemeSettings.swift`, `App/AppIcon-*.icon`). Evergreen stays the default.

4. **Type does the work.** San Francisco at system sizes, with full Dynamic
   Type. Sizes, dates and paths use monospaced digits or SF Mono, which
   gives a precise, tool-like feel and makes columns line up.
5. **Dense, not cramped.** List rows are 40pt thumbnails with two lines of
   text, closer to Files and Mail than to a card-based dashboard.
6. **Motion that tells you something.** Thumbnails fade in, banners slide in,
   saving offline gives a light haptic. Nothing animates just for show.

## What we avoid (the generic "AI-generated" look)

- Purple/blue gradients, glowing accents on dark backgrounds, neon cyan
- Big rounded cards with an icon on top for every item
- Hero sections, "feature grids", decorative blobs
- Emoji as icons, invented icon styles. We use SF Symbols only.
- Placeholder copy. Every string says something specific, such as
  "Signs in directly to your NAS. Nothing passes through our servers."
- Gradient text, heavy drop shadows, glassmorphism on content
- Icon-plus-one-liner benefit lists (the "three feature bullets"), and an
  icon beside every heading. Icons appear only where they identify something
  (a folder, a file type, a connection), not as decoration.
- Tinted callout boxes and colored stripes on the side of boxes
- Slogan fragments ("Your cloud. Owned."), rhetorical triplets, em dashes in
  UI text, and words like seamless, effortless, unlock or powerful
- Sparkle icons, shimmering loading text, cream-and-terracotta palettes
- Bare empty states: an empty screen offers the next useful action (an empty
  folder offers Upload Files and New Folder)

## Platform notes

- **iPhone:** the sidebar is the first screen (shares + Offline), and
  folders push onto a stack. Swipe a row to keep it offline.
- **iPad:** two columns with the sidebar. Pointer, keyboard and Stage Manager
  work for free with SwiftUI.
- **Mac:** a real Mac window with a sidebar, toolbar, right-click menus and a
  Settings window (⌘,). Quick Look uses the Mac's own panel.

## Open design work

- App icon: done. `App/AppIcon.icon` (Icon Composer format); flat sources in
  `Design/AppIcon/`. The "oh" monogram: the h of *hold* sheltering the o of
  *own*, cream on deep evergreen with a mint dot.
- Decide whether the grid should switch to a justified "Photos" layout for
  image-heavy folders
- Empty-state illustrations: likely none, keep SF Symbols
