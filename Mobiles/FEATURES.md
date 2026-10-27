# QuickPizza Mobile Apps — Required Screens & Workflows

The screens and workflows every QuickPizza mobile app (Flutter, React Native,
native iOS, native Android) must implement, so the four can be compared
side by side. Known gaps are listed under
[Current implementation differences](#current-implementation-differences).
What each app emits is in
[MOBILE_OBSERVABILITY_OVERVIEW.md](./docs/MOBILE_OBSERVABILITY_OVERVIEW.md).

## Screens

### 1. Home Screen
The default screen shown on launch.

**Must display:**
- App bar with "QuickPizza" title and profile avatar button
- "Pizza, Please!" / "Get Pizza Recommendation" button
- Expandable "Customize Your Pizza" section
- Pizza recommendation card (after a successful request)
- Rating buttons on the pizza card ("Love it!" / "Pass")
- "Rated!" confirmation text after a rating is submitted

**Customize section must include:**
- Max calories per slice (slider or number input, min: 500)
- Min/max number of toppings
- Vegetarian only toggle
- Exclude tools (checkboxes or chips, loaded from API)
- Custom pizza name (optional text field)

**Pizza card must display:**
- Pizza name
- Dough type
- Tool used
- Calories per slice
- Ingredients list
- Vegetarian badge (if applicable)

### 2. Login Screen
Reached by tapping the profile avatar when unauthenticated.

**Must support:**
- Username and password fields
- Sign In button with loading state
- Error message on failed login
- Hint showing default credentials (`default` / `12345678`)
- Successful login redirects to Profile screen

### 3. Profile Screen
Reached by tapping the profile avatar when authenticated.

**Must display:**
- Username
- Number of pizzas rated
- List of rated pizzas with sentiment (loved / passed) and star count
- Empty state when no ratings exist

**Must support:**
- "Clear Ratings" button (visible only when ratings exist)
- "Sign Out" button — clears session and returns to Home

### 4. About Screen
Accessible from the bottom navigation bar.

**Must display:**
- App description and feature list
- Link to Faro / OTel SDK documentation or repo
- App version number

### 5. Debug screen
Accessible from the bottom navigation bar.

**Must support:**
- Runtime backend and telemetry configuration, applied after restarting the app
- Backend error and latency injection
- Test logs and handled exceptions
- Intentional native crashes for testing crash reporting

Platform-specific diagnostics and controls are listed in the
[observability overview](./docs/MOBILE_OBSERVABILITY_OVERVIEW.md#the-shared-debug-screen).

## Key Workflows

### W1: App Launch
1. App starts clean (no prior data).
2. Home screen is visible with the "Pizza, Please!" button.
3. Quote or tagline is displayed.

> Covered by Arbigent `start_app` scenario.

### W2: Get a Pizza Recommendation
1. User taps "Pizza, Please!" on the Home screen.
2. If not logged in, the login flow may be triggered (see W4).
3. A pizza recommendation card appears showing name, ingredients, and rating buttons.
4. Scrolling down reveals the full card including "Love it!" and "Pass" buttons.

> Covered by Arbigent `request_pizza` scenario.

### W3: Rate a Pizza
*Depends on W2.*

1. Pizza recommendation card is visible.
2. User taps "Love it!" or "Pass".
3. "Rated!" text appears below the rating buttons.

> Covered by Arbigent `rate_pizza` scenario.

### W4: Login
1. User taps profile avatar (unauthenticated).
2. Login screen appears.
3. User enters the default credentials.
4. On success, navigates to Profile screen.
5. Tools list on Home screen becomes available.

### W5: View and Manage Ratings
1. User taps profile avatar (authenticated).
2. Profile screen shows all previously rated pizzas.
3. User taps "Clear Ratings" to delete their ratings (confirmed by empty
   state). The shared `default` account cannot delete ratings; use the seeded
   `studio-user` / `k6studiorocks` account.
4. User can tap "Sign Out" to end session.

### W6: Background / Foreground
1. User presses the Home button — app goes to background.
2. User re-opens app from recents.
3. Home screen is restored correctly (no crash, state preserved).

> Covered by Arbigent `put_app_to_background` and `bring_app_to_foreground` scenarios.

## Current implementation differences

- **Post-login navigation:** the apps dismiss or pop the login screen after a
  successful login. They do not automatically open Profile as specified in
  W4; tap the profile avatar to open it.
- **iOS calorie range:** the native iOS customization slider starts at 300,
  below the shared minimum of 500. Its range is defined in
  [CustomizeSection.swift](ios/QuickPizzaIos/Features/Pizza/Presentation/Components/CustomizeSection.swift).

The E2E basic flow covers launch, recommendation, rating, and
background/foreground; it does not assert all screen contents or rating
deletion.

## API Endpoints Required

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/api/quotes` | GET | No | Home screen quote |
| `/api/tools` | GET | Yes | Populate exclude-tools list |
| `/api/pizza` | POST | Yes | Get recommendation |
| `/api/ratings` | POST | Yes | Submit rating |
| `/api/ratings` | GET | Yes | Load ratings on Profile |
| `/api/ratings` | DELETE | Yes | Clear all ratings |
| `/api/users/token/login` | POST | No | Authenticate |

## Observability Requirements

All four apps must cover, at minimum:

| Signal | Examples |
|---|---|
| Business spans / events | `pizza.get_recommendation`, `pizza.rate`, `auth.login` (manual) |
| Auto HTTP signals | one span / `faro.tracing.fetch` event per outgoing request |
| Logs | Structured app logs at `debug` / `info` / `warn` / `error` |
| Exceptions | Both handled (`logger.exception(...)` / `o11yErrors.reportError`) and unhandled (global error handler / native crash reporter) paths |
| Sessions | Session ID stamped on all telemetry, 15-minute inactivity timeout |

The native iOS and Android apps also identify themselves with these OTel
resource attributes:

- `service.name = quickpizza-ios` / `quickpizza-android`
- `service.namespace = quickpizza`
- `service.version = <bundleVersion / versionName>`

The full per-platform inventory is in
[MOBILE_OBSERVABILITY_OVERVIEW.md](./docs/MOBILE_OBSERVABILITY_OVERVIEW.md).
