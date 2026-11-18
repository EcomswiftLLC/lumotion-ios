# Lumotion: AdMob ids

Created 2026-11-18 in the Ecom Swift AdMob account (publisher `pub-8621573128492952`), through the owner's logged-in Chrome. No payment or tax data was entered.

| Item | Name in AdMob | Id |
|---|---|---|
| iOS app (not yet in the App Store, answered "No" to published) | Photo Animator & Cinemagraph: Lumotion | `ca-app-pub-8621573128492952~9505075957` |
| Banner ad unit | Lumotion Home Banner | `ca-app-pub-8621573128492952/7461045749` |
| Rewarded ad unit (reward: 1 Export) | Lumotion Export Rewarded | `ca-app-pub-8621573128492952/9971659014` |

- `Config/Release.xcconfig` holds these three ids (`ADMOB_APP_ID`, `ADMOB_BANNER_UNIT_ID`, `ADMOB_REWARDED_UNIT_ID`). `Config/Debug.xcconfig` keeps Google's public test ids. `.github/workflows/release.yml` refuses test ids in a release.
- Status in AdMob: "Requires review" until the App Store listing is linked. New units may take up to an hour to serve ads. After the app is live: AdMob > Apps > Lumotion > Add store listing.
- `app-ads.txt` already lists this publisher id at https://ecomswiftllc.github.io/app-ads.txt (shared by every app of the account). Set the developer website of the App Store listing so Apple and AdMob can match it.
- Recommended in AdMob: maximum ad content rating General or Parental Guidance and block sensitive categories, to match the 4+ age rating.
- Policy reminders (HARD): the banner appears on Home only, never over editing controls; the rewarded ad is opt-in with a clear prompt, and an export is free when no ad is ready; no ad during onboarding's first session.
