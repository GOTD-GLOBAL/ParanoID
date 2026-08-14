# ParanoID mobile design system

> Status: experimental UX direction. This file describes the mobile prototype,
> not accepted product behavior or a production security claim.

## Direction: Private Orbit

ParanoID should feel calm under pressure: private without looking secretive,
technical without exposing infrastructure jargon, and distinctive without
imitating the black-and-neon visual shorthand of security products.

The signature element is the **trust orbit**: a thin route line and small server
node that connect a person, device, and selected server. It appears in account,
conversation, offline, and call contexts where trust or routing matters. It is
not decorative on routine controls.

## Product voice

- **Direct:** name the action and its result.
- **Transparent:** disclose what is local, public, offline, or unresolved.
- **Calm:** recovery and error copy is serious without alarmism.
- **Human:** expose server detail only when it helps a decision.

Never claim that a chat or call is end-to-end encrypted until a protocol and
verification evidence exist. Use “connection”, “server”, and “available offline”
only for states the interface can actually explain.

## Color

Author colors in OKLCH and use semantic roles. The hexadecimal values are
documented approximations for design handoff, not parallel component tokens.

| Role | Light | Dark | Approximate intent |
| --- | --- | --- | --- |
| Canvas | `oklch(0.978 0.008 260)` | `oklch(0.155 0.025 265)` | `#F4F6FB` / `#0B1020` |
| Surface | `oklch(1 0 0)` | `oklch(0.205 0.032 265)` | white / deep navy |
| Surface raised | `oklch(0.955 0.012 260)` | `oklch(0.255 0.04 262)` | trays and sheets |
| Text primary | `oklch(0.215 0.04 260)` | `oklch(0.965 0.008 260)` | ink / frost |
| Text secondary | `oklch(0.43 0.03 260)` | `oklch(0.77 0.03 260)` | metadata |
| Border | `oklch(0.89 0.018 260)` | `oklch(0.34 0.04 260)` | structure |
| Action | `oklch(0.545 0.215 276)` | `oklch(0.73 0.16 276)` | electric indigo |
| On action | `oklch(0.99 0 0)` | `oklch(0.18 0.035 265)` | action labels |
| Signal | `oklch(0.55 0.135 166)` | `oklch(0.78 0.12 166)` | available/connected |
| Warning | `oklch(0.67 0.145 75)` | `oklch(0.82 0.12 82)` | stale/degraded |
| Danger | `oklch(0.54 0.195 22)` | `oklch(0.72 0.17 22)` | destructive/end call |

Color has one meaning. Indigo means interactive or selected; mint means a
positive reachability signal only when runtime evidence supports it. In this
prototype, mint is paired with explicit simulation copy. Amber means degraded or
stale; red is reserved for destructive actions and failures. Every status also
has text or an icon.

## Typography

- Brand and large onboarding titles: `Avenir Next`, `Manrope`, system sans;
  30–34 px, 700, line-height 1.08, tracking -0.03 em.
- iOS UI: `-apple-system`, `BlinkMacSystemFont`, system sans.
- Android UI: `Roboto`, `Noto Sans`, system sans.
- Server names, public identifiers, and call timers: `ui-monospace`, `SFMono-Regular`,
  `Roboto Mono`, monospace with tabular numerals.
- Body: 16 px / 1.45. Supporting text: 14 px / 1.4. Captions: 12–13 px / 1.35.
- Inputs remain 16 px on mobile. Text must survive 130% scaling without hiding
  primary actions.

## Shape, spacing, and elevation

- Base spacing: 4 px. Primary rhythm: 8, 12, 16, 24, 32, 48.
- iOS surface radius: 18–26 pt; controls use capsules where native.
- Android surface radius: 16–28 dp; selected navigation uses a tonal pill.
- Message bubbles: 17 px with one 6 px conversation-side corner.
- Use borders and tonal separation before shadows. Modal sheets use one soft
  shadow level and a scrim; blur is reserved for iOS chrome and call controls.
- Touch targets: at least 44×44 pt on iOS and 48×48 dp on Android.

## Navigation and platform adaptation

Four top-level destinations: Chats, Calls, Contacts, Settings. iOS uses a
floating translucent tab bar; Android uses a Material 3 tonal navigation bar.
The route hierarchy and labels are identical, while top bars, back treatment,
buttons, switches, sheets, pressed feedback, and system permission prompts adapt.

Full-screen calls hide top-level navigation. Conversation and setup flows keep a
predictable back action. Large layouts may use a list/detail split, but compact
phone layouts remain the prototype baseline.

## Motion

- Fast feedback: 120 ms. Content/state change: 200 ms. Screen enter: 280 ms.
- Animate transform and opacity only. Navigation maintains direction and spatial
  continuity; sheets rise from the trigger edge.
- The trust orbit may pulse once when a server reconnects. It never loops.
- `prefers-reduced-motion` removes translation, pulsing, and staged entrances.

## Accessibility floor

- Visible focus, descriptive names for icon controls, logical reading order.
- Text contrast targets WCAG 2 AA and APCA guidance; dark mode is checked
  independently.
- Color never carries status alone. Swipe and long-press actions have visible
  button alternatives in the message action sheet.
- Lists remain usable by keyboard; dialogs and sheets have an explicit close or
  cancel route; live network changes use one contextual status announcement.

## Prototype signature

The memorable moment is the server-selection card: a fingerprint mark sits at
the center of an incomplete orbit whose node resolves from “local” to the chosen
server. The same orbit becomes a small trust rail in chat headers and a quiet
connection indicator during calls. Everything else stays restrained.
