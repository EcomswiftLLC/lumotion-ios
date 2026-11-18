# Owner decisions for Lumotion (read before changing monetisation, design or store copy)

**2026-11-18, from the owner's brief: Lumotion stays FREE. No in-app purchases, no subscription, no StoreKit, no watermark.**
Each export (Save video, Save GIF, Share, Save still) is paid for with one opt-in AdMob rewarded ad ("Watch a short ad to export"; 2 minutes of grace after a reward).
**If no ad is ready, or consent is pending, the export is simply free.** Implemented in `Sources/Ads/RewardedGate.swift`. A banner appears on Home only.
Do not add purchases, export packs or Premium. If you believe this is wrong, ask the owner; do not add it silently.

Other standing owner orders that apply here:

- All apps must work on iPhone and iPad (universal build, iPad layouts, 13 inch screenshots).
- Design: clean, premium, luxury, professional SaaS. Dark "projection room" look (ink navy `#0A0C13`, champagne-apricot glow `#F2C48D`, restrained violet-blue secondary, serif display). No placeholder images, no clip art, no login-required design services.
- Real photos and professional icons only, in the store listing and in the app (sample media: Pexels, credits in `docs/store/photo-credits.md`).
- Store name: search keywords first, brand last, one colon. Name "Photo Animator & Cinemagraph", subtitle ends with ": Lumotion". Home-screen name "Lumotion".
- No false claims: no "AI" wording unless a real model does it, no review or star claims, no competitor names, nothing the CI cannot prove.
- Never violate Google Play / AdMob / Apple policy. NSPrivacyTracking stays false in the manifest (ITMS-91064); the tracking answer lives in the App Store Connect privacy label.
- Pace App Store submissions: finish the Aperta and Folia reviews first, do not submit several new apps on the same day.

Open items that only the owner can do:

1. After the app exists in App Store Connect: link the App Store listing in AdMob (status "Requires review" until then).
2. App Store Connect forms that need the owner's personal data (review contact phone, trader status) and the App Privacy answers in `docs/store/app-privacy.md`.
3. Lawyer review of the draft privacy policy and terms (`docs/legal`), then remove the draft notice markers if you want them gone from the Markdown (the website build already strips them).
4. Re-run the store shot tools when the CI `screenshots` and `screenshots-ipad` artifacts of the final build exist, and publish the new `website/lumotion/assets/shots` if wanted.
