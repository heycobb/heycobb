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
3. **One accent color, used rarely.** A burnt orange (`AccentColor` in the
   asset catalog: #C65530 light, #E87951 dark). It marks folders, selection,
   the offline badge and primary buttons. Everything else is neutral, so
   photo thumbnails carry the color.
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

## Platform notes

- **iPhone:** the sidebar is the first screen (shares + Offline), and
  folders push onto a stack. Swipe a row to keep it offline.
- **iPad:** two columns with the sidebar. Pointer, keyboard and Stage Manager
  work for free with SwiftUI.
- **Mac:** a real Mac window with a sidebar, toolbar, right-click menus and a
  Settings window (⌘,). Quick Look uses the Mac's own panel.

## Open design work

- App icon (Icon Composer, layered for Liquid Glass)
- Decide whether the grid should switch to a justified "Photos" layout for
  image-heavy folders
- Empty-state illustrations: likely none, keep SF Symbols
